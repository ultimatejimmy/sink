-- Test suite for Sink main.lua plugin logic

print("--> Running Sink main.lua module verification test...")

-- Mock environment for KOReader dependencies
local mock_widget_container = {
    extend = function(self, tbl)
        tbl = tbl or {}
        setmetatable(tbl, { __index = self })
        return tbl
    end
}

local mock_settings = {}
_G.G_reader_settings = {
    readSetting = function(self, key)
        return mock_settings[key]
    end,
    saveSetting = function(self, key, val)
        mock_settings[key] = val
    end
}

-- Mock UI & Hardware modules
package.loaded["ui/widget/container/widgetcontainer"] = mock_widget_container
package.loaded["ui/uimanager"] = { show = function() end, close = function() end, scheduleIn = function() end, unschedule = function() end }
package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(self, o) return o end }
package.loaded["ui/widget/buttondialog"] = { new = function(self, o) return o end }
package.loaded["device"] = { model = "TestModel", id = "test_id_123" }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["gettext"] = function(s) return s end
package.loaded["ui/event"] = {
    new = function(self, name, arg) return { name = name, arg = arg } end
}

-- Mock JSON & Network dependencies for unit test isolation
if not package.loaded["json"] then
    package.loaded["json"] = {
        encode = function(t) return "{}" end,
        decode = function(s) return {} end,
    }
end
package.loaded["socket"] = {}
package.loaded["socket.http"] = { request = function() return 1, 200, {}, "OK" end }
package.loaded["ssl.https"] = { request = function() return 1, 200, {}, "OK" end }
package.loaded["ltn12"] = {
    sink = { table = function() return function() end end },
    source = { string = function() return function() end end },
}

local is_online_val = false
local run_when_online_called = false
package.loaded["ui/network/manager"] = {
    isOnline = function(self) return is_online_val end,
    runWhenOnline = function(self, cb)
        run_when_online_called = true
        if cb then cb() end
    end
}

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local main_path = script_dir .. "../main.lua"

local main_chunk, err = loadfile(main_path)
if not main_chunk then
    error("Failed to load main.lua: " .. tostring(err))
end

local Sink = main_chunk()
assert(type(Sink) == "table", "main.lua must return a Sink class table")
assert(Sink.name == "sink", "Plugin name must be 'sink'")

-- Verify required lifecycle and UI methods exist
local required_methods = {
    "init",
    "loadSettings",
    "saveSettings",
    "addToMainMenu",
    "getMenuTable",
    "onReaderReady",
    "onCloseDocument",
    "onSuspend",
    "onNetworkConnected",
    "_silentBackgroundSync",
    "_syncDocument",
    "testConnection",
}

for _, method_name in ipairs(required_methods) do
    assert(type(Sink[method_name]) == "function", "Missing required method: " .. method_name)
end

-- Test instance creation & settings loading
local dummy_ui = {
    menu = {
        registerToMainMenu = function() end
    }
}
local instance = setmetatable({ ui = dummy_ui }, { __index = Sink })
instance:init()

assert(type(instance.settings) == "table", "instance.settings should be initialized")
assert(instance.settings.auto_sync == true, "auto_sync should default to true")

-- Test non-intrusive offline behavior
is_online_val = false
run_when_online_called = false

-- Calling background hooks when offline must NOT call runWhenOnline
instance:onReaderReady()
instance:onCloseDocument()
instance:onSuspend()
instance:onNetworkConnected()
assert(run_when_online_called == false, "Background hooks must NEVER invoke runWhenOnline when offline")

-- Test manual menu table items
local menu = instance:getMenuTable()
assert(type(menu) == "table" and #menu >= 4, "Menu table must have at least 4 items")

-- Test 1: _getDocumentMD5 with partial_md5_checksum
local mock_doc_settings = {
    settings = { partial_md5_checksum = "abc123md5hash" },
    readSetting = function(self, k) return self.settings[k] end
}
local test_ui = {
    doc_settings = mock_doc_settings,
    document = {
        file = "/path/to/book.epub",
        info = { has_pages = false }
    }
}
local test_inst = setmetatable({ ui = test_ui, settings = { username = "testuser", userkey = "testkey" } }, { __index = Sink })
assert(test_inst:_getDocumentMD5() == "abc123md5hash", "Should extract partial_md5_checksum from doc_settings")

-- Test 2: _getDocumentMD5 fallback to fastDigest
test_ui.doc_settings.settings.partial_md5_checksum = nil
test_ui.document.fastDigest = function(self) return "fastdigest_hash_456" end
assert(test_inst:_getDocumentMD5() == "fastdigest_hash_456", "Should fall back to document:fastDigest()")

-- Test 3: _getLocalProgress for reflowable documents
test_ui.rolling = {
    getLastProgress = function(self) return "/body/div[2]/p[5]" end,
    getLastPercent = function(self) return 0.42 end,
}
local pct, prog = test_inst:_getLocalProgress()
assert(pct == 0.42, "Should extract percentage from rolling:getLastPercent()")
assert(prog == "/body/div[2]/p[5]", "Should extract progress from rolling:getLastProgress()")

-- Test 4: _getLocalProgress for paged documents
local paged_ui = {
    document = {
        info = { has_pages = true },
        totalPages = 200,
    },
    paging = {
        getLastProgress = function(self) return "50" end,
        getLastPercent = function(self) return 0.25 end,
        current_page = 50,
    }
}
local paged_inst = setmetatable({ ui = paged_ui, settings = {} }, { __index = Sink })
local paged_pct, paged_prog = paged_inst:_getLocalProgress()
assert(paged_pct == 0.25, "Paged percentage should match")
assert(paged_prog == "50", "Paged progress should match")

-- Test 5: _applyRemoteProgress
local handled_event = nil
paged_ui.handleEvent = function(self, evt)
    handled_event = evt
end
paged_inst:_applyRemoteProgress("75", 0.375)
assert(handled_event and handled_event.name == "GotoPage" and handled_event.arg == 75, "Should dispatch GotoPage event for paged documents")

test_ui.handleEvent = function(self, evt)
    handled_event = evt
end
test_inst:_applyRemoteProgress("/body/div[3]", 0.5)
assert(handled_event and handled_event.name == "GotoXPointer" and handled_event.arg == "/body/div[3]", "Should dispatch GotoXPointer event for reflowable documents")

print("✓ Sink main.lua module tests PASSED!")
