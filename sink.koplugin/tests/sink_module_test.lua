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

package.loaded["ui/widget/container/widgetcontainer"] = mock_widget_container
package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(self, o) return o end }
package.loaded["device"] = { model = "TestModel", id = "test_id_123" }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["gettext"] = function(s) return s end

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
    "registerAccount",
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
assert(type(menu) == "table" and #menu >= 5, "Menu table must have at least 5 items")

print("✓ Sink main.lua module tests PASSED!")
