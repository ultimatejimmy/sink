-- Regression and verification test for Sink localization (issue #7)

print("--> Running Sink localization verification test...")

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local base_dir = script_dir .. "../"
package.path = base_dir .. "?.lua;" .. base_dir .. "lib/?.lua;" .. package.path

-- 1. Mock minimal environment
local mock_settings = {
    language = "fr",
}

_G.G_reader_settings = {
    readSetting = function(self, key)
        return mock_settings[key]
    end,
    saveSetting = function(self, key, val)
        mock_settings[key] = val
    end
}

local mock_widget_container = {
    extend = function(self, tbl)
        tbl = tbl or {}
        setmetatable(tbl, { __index = self })
        return tbl
    end
}

package.loaded["ui/widget/container/widgetcontainer"] = mock_widget_container
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    nextTick = function(self, fn) end,
}
package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(self, o) return o end }
package.loaded["ui/widget/buttondialog"] = { new = function(self, o) return o end }
package.loaded["ui/widget/textboxwidget"] = { new = function(self, o) return o end }
package.loaded["ui/widget/textwidget"] = { new = function(self, o) return o end }
package.loaded["ui/widget/verticalspan"] = { new = function(self, o) return o end }
package.loaded["ui/widget/verticalgroup"] = mock_widget_container
package.loaded["ui/widget/container/centercontainer"] = mock_widget_container
package.loaded["ui/widget/container/framecontainer"] = mock_widget_container
package.loaded["device"] = { model = "TestModel", id = "test_id", screen = { scaleBySize = function(self, s) return s end } }
local logged_warnings = {}
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function(...)
        table.insert(logged_warnings, {...})
    end
}
package.loaded["gettext"] = function(s) return s end
package.loaded["json"] = { encode = function() return "{}" end, decode = function() return {} end }
package.loaded["socket"] = {}
package.loaded["socket.http"] = { request = function() return 1, 200, {}, "OK" end }
package.loaded["ssl.https"] = { request = function() return 1, 200, {}, "OK" end }
package.loaded["ltn12"] = {
    sink = { table = function() return function() end end },
    source = { string = function() return function() end end },
}
package.loaded["ui/network/manager"] = { isOnline = function() return true end }
package.loaded["ui/size"] = { padding = { default = 6, small = 4 } }
package.loaded["ui/font"] = { getFace = function() return "font" end }

-- Test Suite 1: PO Parser Unit Tests
local Loc = require("localization_sink")
Loc:init(base_dir)

assert(Loc.current_language == "fr", "Language should be detected as 'fr', got: " .. tostring(Loc.current_language))

local fr_po_path = base_dir .. "languages/fr.po"
local translations = Loc:parsePO(fr_po_path)
assert(translations ~= nil, "fr.po should parse successfully")

-- Test single line translation
local single = translations["Sync Progress Now"]
assert(single ~= nil and single ~= "Sync Progress Now", "Single line 'Sync Progress Now' should be translated")

-- Test multi-line translation with newline in key (Defect #2)
local multiline_key = "Failed to fetch remote progress:\n"
local multiline_trans = translations[multiline_key]
assert(multiline_trans ~= nil, "Multi-line key with newline must be unescaped and matched in PO parser")

local auth_key = "Authentication failed (401 Unauthorized).\nTap 'Pair Device' to re-link your e-reader."
local auth_trans = translations[auth_key]
assert(auth_trans ~= nil, "Multi-line auth key must be matched in PO parser")

-- Verify no parsed keys have literal backslash-n escape sequences left
for k, _ in pairs(translations) do
    if k:find("\\n", 1, true) then
        error("Found unescaped '\\n' in translation key: " .. k)
    end
end

-- Test Suite 2: Main plugin localization integration (Defect #1)
local main_chunk, err = loadfile(base_dir .. "main.lua")
assert(main_chunk, "Failed to load main.lua: " .. tostring(err))

local Sink = main_chunk()
local dummy_ui = {
    menu = {
        registerToMainMenu = function() end,
    },
    document = nil,
}
local inst = setmetatable({ ui = dummy_ui }, { __index = Sink })
inst:init()

local menu = inst:getMenuTable()
assert(menu ~= nil and #menu > 0, "Menu table should exist and not be empty")
local sync_now_item = menu[1]
assert(sync_now_item ~= nil, "Sync now menu item should exist")
assert(sync_now_item.text ~= "Sync Progress Now",
    "main.lua menu string must be translated to French, but got English: '" .. tostring(sync_now_item.text) .. "'")
assert(sync_now_item.text == "Synchroniser la progression maintenant",
    "Expected 'Synchroniser la progression maintenant', got: '" .. tostring(sync_now_item.text) .. "'")

-- Test Suite 3: Pairing module localization (Defect #3)
local pairing = require("sink_pairing")
assert(pairing.loc ~= nil, "SinkPairing.loc should be initialized by main.lua")
local cancel_text = nil
local dlg = pairing:_buildPairingDialog("https://example.com", "123456")
-- Look for localized "Cancel" button in dlg (or check localized pairing strings)
-- In French fr.po, "Cancel" -> "Annuler"
assert(pairing.loc:t("Cancel") == "Annuler", "pairing.loc should translate Cancel to Annuler")
-- Let's check a pairing string translation
local phone_str = pairing.loc:t("Scan with your phone to pair instantly:")
assert(phone_str ~= "Scan with your phone to pair instantly:",
    "Pairing string should be translated in French")

-- Test Suite 4: Sweep all PO files in languages directory
local lang_dir = base_dir .. "languages/"
local po_files = {
    "ar.po", "de.po", "en.po", "es.po", "fr.po", "hu.po", "id.po", "it.po",
    "ja.po", "nl.po", "pl.po", "pt_br.po", "ru.po", "sr.po", "tr.po", "uk.po", "zh_CN.po"
}
for _, po_file in ipairs(po_files) do
    local t = Loc:parsePO(lang_dir .. po_file)
    assert(t ~= nil, "Failed to parse PO file: " .. po_file)
    for k, _ in pairs(t) do
        if k:find("\\n", 1, true) or k:find('\\"', 1, true) then
            error("Found unescaped sequence in key for " .. po_file .. ": " .. k)
        end
    end
end

-- Test Suite 5: Dialect and case-insensitive language resolution (e.g., pt_BR -> pt_br.po, zh-CN -> zh_CN.po)
mock_settings.language = "pt_BR"
Loc:init(base_dir)
assert(Loc.current_language == "pt_br", "pt_BR setting should match pt_br.po file on disk")
assert(Loc:t("Cancel") == "Cancelar", "pt_BR should translate Cancel to Cancelar")

mock_settings.language = "zh-CN"
Loc:init(base_dir)
assert(Loc.current_language == "zh_CN", "zh-CN setting should match zh_CN.po file on disk")
assert(Loc:t("Cancel") == "取消", "zh-CN should translate Cancel to 取消")

print("--> All localization tests passed successfully!")
