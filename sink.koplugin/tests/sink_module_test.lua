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
local scheduled_tasks = {}
package.loaded["ui/widget/container/widgetcontainer"] = mock_widget_container
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function(self, delay, fn)
        table.insert(scheduled_tasks, { delay = delay, fn = fn })
    end,
    unschedule = function(self, fn)
        for i = #scheduled_tasks, 1, -1 do
            if scheduled_tasks[i].fn == fn then
                table.remove(scheduled_tasks, i)
            end
        end
    end
}
package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(self, o) return o end }
package.loaded["ui/widget/buttondialog"] = { new = function(self, o) return o end }
package.loaded["device"] = { model = "TestModel", id = "test_id_123", screen = { scaleBySize = function(self, s) return s end } }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["gettext"] = function(s) return s end
package.loaded["ui/event"] = {
    new = function(self, name, arg) return { name = name, arg = arg } end
}
package.loaded["ui/font"] = { getFace = function() return "mock_face" end }
package.loaded["ui/size"] = { padding = { default = 6, small = 4 } }
package.loaded["ui/widget/textboxwidget"] = { new = function(self, o) return o end }
package.loaded["ui/widget/textwidget"] = { new = function(self, o) return o end }
package.loaded["ui/widget/verticalspan"] = { new = function(self, o) return o end }
package.loaded["ui/widget/verticalgroup"] = mock_widget_container
package.loaded["ui/widget/container/centercontainer"] = mock_widget_container
package.loaded["ui/widget/container/framecontainer"] = mock_widget_container

-- Mock JSON & Network dependencies for unit test isolation
if not package.loaded["json"] then
    package.loaded["json"] = {
        encode = function(t) return "{}" end,
        decode = function(s) return {} end,
    }
end
package.loaded["socket"] = {}
local last_http_request = nil
local mock_http_handler = function(req)
    last_http_request = req
    return 1, 200, {}, "OK"
end
package.loaded["socket.http"] = { request = mock_http_handler }
package.loaded["ssl.https"] = { request = mock_http_handler }
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

-- Test 1: _getDocumentMD5 with binary checksum
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
local test_inst = setmetatable({ ui = test_ui, settings = { username = "testuser", userkey = "testkey", checksum_method = "binary" } }, { __index = Sink })
assert(test_inst:_getDocumentMD5() == "abc123md5hash", "Should extract partial_md5_checksum from doc_settings in binary mode")

-- Test 2: _getDocumentMD5 with filename matching
test_inst.settings.checksum_method = "filename"
local fn_hash = test_inst:_getDocumentMD5()
assert(fn_hash ~= nil and #fn_hash > 0, "Should generate hash for filename in filename mode")

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

-- Test 6: SinkPairing module loads cleanly and has startPairing/stop methods
local pairing = require("sink_pairing")
assert(type(pairing) == "table", "sink_pairing module should load as table")
-- Test 7: SinkPairing:_buildPairingDialog generates valid dialog with widgets
local dlg = pairing:_buildPairingDialog("https://sink.test", "ABC123")
assert(dlg ~= nil, "_buildPairingDialog should return a dialog instance")
assert(dlg._added_widgets ~= nil and #dlg._added_widgets >= 1, "Dialog should contain added widgets")

-- Test 8: _urlEncode and _getBookMetadata
assert(test_inst:_urlEncode("hello world & more") == "hello%20world%20%26%20more", "Should URL-encode parameters properly")

test_ui.doc_props = {
    title = "Career of Evil (Cormoran Strike)",
    authors = "Robert Galbraith",
}
local title, authors, book_key = test_inst:_getBookMetadata()
assert(title == "Career of Evil (Cormoran Strike)", "Should extract title")
assert(authors == "Robert Galbraith", "Should extract authors")
assert(book_key == "career of evil::galbraith robert", "Should compute normalized book_key correctly")

-- Test 9: Document Session Caching
assert(test_inst.cached_book_key == book_key, "Book key should be cached on instance")
assert(test_inst.cached_title == title, "Title should be cached on instance")
test_inst:_clearDocCache()
assert(test_inst.cached_book_key == nil, "Doc cache should be cleared by _clearDocCache")

-- Test 10: Dirty State Tracking & onPageUpdate
assert(test_inst.doc_is_dirty == false, "doc_is_dirty should start false")
test_inst:onPageUpdate(12)
assert(test_inst.doc_is_dirty == true, "onPageUpdate should set doc_is_dirty to true")
assert(test_inst.last_page_turn_time > 0, "onPageUpdate should update last_page_turn_time")

-- Test 11: onSuspend with clean document does ZERO work
is_online_val = true
test_inst.doc_is_dirty = false
last_http_request = nil
test_inst:onSuspend()
assert(last_http_request == nil, "onSuspend must do ZERO network work when doc is clean (not dirty)")

-- Test 12: onSuspend with dirty document uses strict 2s timeout
test_inst.doc_is_dirty = true
test_inst.settings.auto_sync = true
test_inst.settings.server_url = "https://sink.test"
last_http_request = nil
test_inst:onSuspend()
assert(last_http_request ~= nil, "onSuspend must push when document is dirty and online")
assert(last_http_request.timeout == 2, "onSuspend push must use strict 2-second timeout to prevent Kindle watchdog panics")
assert(test_inst.doc_is_dirty == false, "doc_is_dirty should reset to false after successful push")

-- Test 13: onResume defers sync by 8 seconds (no immediate blocking)
scheduled_tasks = {}
test_inst:onResume()
assert(#scheduled_tasks >= 1, "onResume must schedule a deferred task")
assert(scheduled_tasks[#scheduled_tasks].delay >= 8, "onResume delay must be at least 8 seconds")

-- Test 14: onNetworkConnected debounces by 5 seconds
scheduled_tasks = {}
test_inst:onNetworkConnected()
assert(#scheduled_tasks >= 1, "onNetworkConnected must schedule a debounced task")
assert(scheduled_tasks[#scheduled_tasks].delay == 5, "onNetworkConnected debounce must be 5 seconds")

-- Test 15: Reentrancy guard
test_inst.is_syncing = true
local concurrent_res = test_inst:_syncDocument("pull", false)
assert(concurrent_res == false, "_syncDocument must reject concurrent reentrant calls")
test_inst.is_syncing = false

-- Test 16: Lazy Localization
local Loc = require("localization_sink")
Loc:init()
assert(Loc.current_language == "en", "Default language should be en")
assert(Loc.translations_loaded == true, "English should be marked loaded immediately")
assert(next(Loc.translations) == nil, "English translations table should remain empty (zero heap waste)")
assert(Loc:t("Hello World") == "Hello World", "Untranslated key should return verbatim")

print("✓ Sink main.lua module tests PASSED!")

