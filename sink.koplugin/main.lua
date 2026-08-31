local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local logger = require("logger")
local json = require("json")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local _ = require("gettext")

local Event = nil
pcall(function() Event = require("ui/event") end)
local util = nil
pcall(function() util = require("util") end)

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local SinkPairing = nil
pcall(function()
    SinkPairing = require(plugin_path .. "sink_pairing")
end)

local DataStorage = nil
local LuaSettings = nil
pcall(function()
    DataStorage = require("datastorage")
    LuaSettings = require("luasettings")
end)

local Sink = WidgetContainer:extend{
    name = "sink",
    is_doc_only = false,
}

-- Default Configuration
local DEFAULT_SETTINGS = {
    server_url = "https://sink.your-subdomain.workers.dev",
    username = "",
    userkey = "",
    auto_sync = true,
    last_sync_time = 0,
    last_sync_doc = "",
}

function Sink:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
end

function Sink:getSettingsPath()
    local dir = (DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
    return dir .. "/sink_settings.lua"
end

function Sink:loadSettings()
    local loaded = nil
    if LuaSettings then
        local ok, storage = pcall(function() return LuaSettings:open(self:getSettingsPath()) end)
        if ok and storage then
            self.settings_storage = storage
            loaded = storage:readSetting("sink_sync")
        end
    end
    if not loaded and _G.G_reader_settings then
        loaded = G_reader_settings:readSetting("sink_sync")
    end
    self.settings = loaded or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if self.settings[k] == nil then
            self.settings[k] = v
        end
    end
end

function Sink:saveSettings()
    if not self.settings_storage and LuaSettings then
        pcall(function()
            self.settings_storage = LuaSettings:open(self:getSettingsPath())
        end)
    end
    if self.settings_storage then
        self.settings_storage:saveSetting("sink_sync", self.settings)
        pcall(function() self.settings_storage:flush() end)
    end
    if _G.G_reader_settings then
        G_reader_settings:saveSetting("sink_sync", self.settings)
        if G_reader_settings.flush then
            pcall(function() G_reader_settings:flush() end)
        end
    end
end

--------------------------------------------------------------------------------
-- HTTP & API Client Helper
--------------------------------------------------------------------------------

local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

local function cleanUrl(url)
    url = trim(url)
    if url:sub(-1) == "/" then
        url = url:sub(1, -2)
    end
    return url
end

function Sink:_makeRequest(method, endpoint, body_table)
    local server_url = cleanUrl(self.settings.server_url)
    if not server_url or server_url == "" then
        return nil, "Server URL is not configured."
    end

    local url = server_url .. endpoint
    local req_body = nil
    local headers = {
        ["Accept"] = "application/vnd.koreader.v1+json, application/json",
        ["x-auth-user"] = self.settings.username or "",
        ["x-auth-key"] = self.settings.userkey or "",
    }

    if body_table then
        req_body = json.encode(body_table)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#req_body)
    end

    local response_body = {}
    local protocol = url:match("^(https?)://")
    local request_fn = (protocol == "https") and https.request or http.request

    local ok, code, resp_headers, status_line
    local pcall_ok, pcall_err = pcall(function()
        ok, code, resp_headers, status_line = request_fn{
            url = url,
            method = method,
            headers = headers,
            source = req_body and ltn12.source.string(req_body) or nil,
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        }
    end)

    if not pcall_ok then
        return nil, "Network error: " .. tostring(pcall_err)
    end

    local raw_res = table.concat(response_body)
    local decoded = nil
    if raw_res and #raw_res > 0 then
        pcall(function() decoded = json.decode(raw_res) end)
    end

    return {
        status = tonumber(code) or code or 0,
        headers = resp_headers or {},
        body = decoded or {},
        raw = raw_res,
    }, nil
end

--------------------------------------------------------------------------------
-- Document & Progress Utilities
--------------------------------------------------------------------------------

function Sink:_getDocumentMD5()
    if not self.ui then return nil end

    -- 1. Read partial_md5_checksum from document settings (standard KOReader key)
    if self.ui.doc_settings then
        local checksum = self.ui.doc_settings:readSetting("partial_md5_checksum")
        if checksum and checksum ~= "" then
            return checksum
        end
        -- Fallback check for any legacy key
        local legacy = self.ui.doc_settings:readSetting("doc_md5") or self.ui.doc_settings:readSetting("md5")
        if legacy and legacy ~= "" then
            return legacy
        end
    end

    -- 2. Fallback using document object or file path
    if self.ui.document then
        if self.ui.document.fastDigest then
            local ok, digest = pcall(function() return self.ui.document:fastDigest() end)
            if ok and digest and digest ~= "" then
                return digest
            end
        end
        if self.ui.document.file then
            if util and util.partialMD5 then
                local ok, md5_val = pcall(function() return util.partialMD5(self.ui.document.file) end)
                if ok and md5_val and md5_val ~= "" then
                    return md5_val
                end
            end
            local ok, sha2 = pcall(require, "ffi/sha2")
            if ok and sha2 and sha2.md5 then
                local md5_val = sha2.md5(self.ui.document.file)
                if md5_val and md5_val ~= "" then
                    return md5_val
                end
            end
        end
    end

    return nil
end

function Sink:_getLocalProgress()
    if not self.ui or not self.ui.document then return nil, nil end
    local progress = nil
    local percentage = nil

    local has_pages = self.ui.document.info and self.ui.document.info.has_pages

    if has_pages then
        -- Paginated document (PDF, DJVU, CBZ, etc.)
        if self.ui.paging then
            if self.ui.paging.getLastProgress then
                local ok, p = pcall(function() return self.ui.paging:getLastProgress() end)
                if ok and p then progress = tostring(p) end
            end
            if not progress and self.ui.paging.current_page then
                progress = tostring(self.ui.paging.current_page)
            end

            if self.ui.paging.getLastPercent then
                local ok, pct = pcall(function() return self.ui.paging:getLastPercent() end)
                if ok and pct then percentage = tonumber(pct) end
            end
        end

        if not progress and self.ui.getCurrentPage then
            local ok, p = pcall(function() return self.ui:getCurrentPage() end)
            if ok and p then progress = tostring(p) end
        end

        if not percentage and self.ui.document.totalPages and self.ui.document.totalPages > 0 and tonumber(progress) then
            percentage = tonumber(progress) / self.ui.document.totalPages
        end
    else
        -- Reflowable document (EPUB, MOBI, FB2, TXT, etc.)
        if self.ui.rolling then
            if self.ui.rolling.getLastProgress then
                local ok, p = pcall(function() return self.ui.rolling:getLastProgress() end)
                if ok and p then progress = tostring(p) end
            end
            if self.ui.rolling.getLastPercent then
                local ok, pct = pcall(function() return self.ui.rolling:getLastPercent() end)
                if ok and pct then percentage = tonumber(pct) end
            end
        end

        if not progress and self.ui.doc_settings then
            progress = self.ui.doc_settings:readSetting("last_xpointer")
        end
        if not progress and self.ui.bookmark and self.ui.bookmark.getProgress then
            local ok, p = pcall(function() return self.ui.bookmark:getProgress() end)
            if ok and p then progress = tostring(p) end
        end
        if not progress and self.ui.document and self.ui.document.getXPointer then
            local ok, p = pcall(function() return self.ui.document:getXPointer() end)
            if ok and p then progress = tostring(p) end
        end
        if not progress and self.ui.paging and self.ui.paging.current_page then
            progress = tostring(self.ui.paging.current_page)
        end
    end

    -- Extract percentage from doc_settings if not yet populated
    if not percentage and self.ui.doc_settings then
        percentage = tonumber(self.ui.doc_settings:readSetting("percent_finished"))
    end

    if not percentage and progress then
        percentage = 0.0
    end

    return percentage, progress
end

function Sink:_applyRemoteProgress(remote_progress, remote_percentage)
    if not self.ui or not remote_progress then return end

    local has_pages = self.ui.document and self.ui.document.info and self.ui.document.info.has_pages

    if Event and self.ui.handleEvent then
        if has_pages then
            local page = tonumber(remote_progress)
            if page then
                self.ui:handleEvent(Event:new("GotoPage", page))
                return
            end
        else
            self.ui:handleEvent(Event:new("GotoXPointer", tostring(remote_progress)))
            return
        end
    end

    -- Fallback navigation handlers
    if self.ui.bookmark and self.ui.bookmark.restoreProgress then
        pcall(function() self.ui.bookmark:restoreProgress(remote_progress) end)
    elseif self.ui.gotoXPointer then
        pcall(function() self.ui:gotoXPointer(tostring(remote_progress)) end)
    elseif self.ui.gotoPage and tonumber(remote_progress) then
        pcall(function() self.ui:gotoPage(tonumber(remote_progress)) end)
    end
end

function Sink:_getDeviceInfo()
    local model = "Kindle"
    local device_id = "kindle_device"

    if Device then
        if Device.getModel then
            pcall(function() model = Device:getModel() end)
        elseif Device.model then
            model = tostring(Device.model)
        end

        if Device.getDeviceId then
            pcall(function() device_id = Device:getDeviceId() end)
        elseif Device.id then
            device_id = tostring(Device.id)
        end
    end

    return model, device_id
end

--------------------------------------------------------------------------------
-- Core Sync Actions
--------------------------------------------------------------------------------

-- Perform sync for the current document
-- is_manual: boolean flag. If true, show user-facing notifications/alerts.
function Sink:_syncDocument(is_manual)
    if not self.settings.username or self.settings.username == "" then
        if is_manual then
            UIManager:show(InfoMessage:new{
                text = _("Please pair your device or configure credentials in settings."),
            })
        end
        return false
    end

    local doc_md5 = self:_getDocumentMD5()
    if not doc_md5 then
        if is_manual then
            UIManager:show(InfoMessage:new{
                text = _("No active document found to sync."),
            })
        end
        return false
    end

    local local_pct, local_prog = self:_getLocalProgress()
    if not local_pct or not local_prog then
        logger.dbg("Sink: unable to extract local progress for document " .. tostring(doc_md5))
        return false
    end

    -- 1. Fetch remote progress
    local res, err = self:_makeRequest("GET", "/syncs/progress/" .. doc_md5)
    if err or not res or (res.status ~= 200 and res.status ~= 201) then
        logger.dbg("Sink: error fetching remote progress: " .. tostring(err or res and res.status))
        if is_manual then
            UIManager:show(InfoMessage:new{
                text = _("Failed to sync progress:\n") .. tostring(err or (res and res.raw) or "Unknown error"),
            })
        end
        return false
    end

    local remote = res.body or {}
    local remote_pct = tonumber(remote.percentage)
    local remote_prog = remote.progress
    local remote_ts = tonumber(remote.timestamp) or 0

    local dev_model, dev_id = self:_getDeviceInfo()

    -- 2. Compare: If remote progress exists and is further than local progress, apply remote
    if remote_pct and remote_prog and remote_pct > (local_pct + 0.0001) then
        self:_applyRemoteProgress(remote_prog, remote_pct)
        self.settings.last_sync_time = remote_ts > 0 and remote_ts or os.time()
        self.settings.last_sync_doc = doc_md5
        self:saveSettings()

        if is_manual then
            UIManager:show(Notification:new{
                text = string.format(_("Synced from cloud: %.1f%% (%s)"), remote_pct * 100, remote.device or "Remote"),
            })
        end
        return true
    else
        -- 3. Local progress is equal or further: push local progress to cloud
        local push_res, push_err = self:_makeRequest("PUT", "/syncs/progress", {
            document = doc_md5,
            percentage = local_pct,
            progress = local_prog,
            device = dev_model,
            device_id = dev_id,
        })

        if push_err or not push_res or push_res.status ~= 200 then
            logger.dbg("Sink: error pushing progress: " .. tostring(push_err or push_res and push_res.status))
            if is_manual then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to upload progress:\n") .. tostring(push_err or (push_res and push_res.raw) or "Unknown error"),
                })
            end
            return false
        end

        local ts = (push_res.body and push_res.body.timestamp) or os.time()
        self.settings.last_sync_time = ts
        self.settings.last_sync_doc = doc_md5
        self:saveSettings()

        if is_manual then
            UIManager:show(Notification:new{
                text = string.format(_("Synced to cloud: %.1f%%"), local_pct * 100),
            })
        end
        return true
    end
end

--------------------------------------------------------------------------------
-- Non-Intrusive Lifecycle Hooks
-- Crucial: Must NEVER trigger Wi-Fi popups in background.
-- Uses NetworkMgr:isOnline() and completely suppresses errors.
--------------------------------------------------------------------------------

function Sink:_silentBackgroundSync(trigger_name)
    if not self.settings.auto_sync then
        return
    end

    -- Non-intrusive check: is the device currently connected to Wi-Fi?
    if not NetworkMgr:isOnline() then
        logger.dbg("Sink [" .. trigger_name .. "]: Device is offline. Silently skipping sync.")
        return
    end

    logger.dbg("Sink [" .. trigger_name .. "]: Device online. Performing silent sync.")
    local ok, err = pcall(function()
        self:_syncDocument(false)
    end)
    if not ok then
        -- Suppress all background errors
        logger.dbg("Sink [" .. trigger_name .. "] silent sync error: " .. tostring(err))
    end
end

function Sink:onReaderReady()
    self:_silentBackgroundSync("onReaderReady")
end

function Sink:onCloseDocument()
    self:_silentBackgroundSync("onCloseDocument")
end

function Sink:onSuspend()
    self:_silentBackgroundSync("onSuspend")
end

function Sink:onNetworkConnected()
    self:_silentBackgroundSync("onNetworkConnected")
end

--------------------------------------------------------------------------------
-- User Interface & Configuration Menu
--------------------------------------------------------------------------------

local Dispatcher = nil
pcall(function() Dispatcher = require("dispatcher") end)

function Sink:onDispatcherRegisterActions()
    if Dispatcher then
        Dispatcher:registerAction("sink_sync_now", {
            category = "none",
            event = "SinkSyncNow",
            title = _("Sink: Sync Now"),
            general = true,
        })
        Dispatcher:registerAction("sink_pair", {
            category = "none",
            event = "SinkPair",
            title = _("Sink: Pair Device"),
            general = true,
        })
    end
end

function Sink:onSinkSyncNow()
    self:_syncDocument(true)
end

function Sink:onSinkPair()
    if SinkPairing then
        SinkPairing:startPairing(self, function()
            self:_syncDocument(false)
        end)
    end
end

local function injectSinkIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function isItemInOrder(tbl, target_id)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == target_id then
                return true
            elseif type(val) == "table" then
                if isItemInOrder(val, target_id) then
                    return true
                end
            end
        end
        return false
    end

    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not isItemInOrder(order, "sink_sync") then
                local insert_idx = math.min(4, #order.tools + 1)
                table.insert(order.tools, insert_idx, "sink_sync")
            end
        end
    end
end

function Sink:addToMainMenu(menu_items)
    injectSinkIntoToolsMenu()
    menu_items.sink_sync = {
        sorting_hint = "tools",
        text = _("Sink"),
        sub_item_table = self:getMenuTable(),
    }
end

function Sink:getMenuTable()
    return {
        {
            text = _("Pair Device (Phone / PC)"),
            keep_menu_open = false,
            callback = function()
                if SinkPairing then
                    SinkPairing:startPairing(self, function()
                        self:_syncDocument(false)
                    end)
                else
                    UIManager:show(InfoMessage:new{ text = _("Pairing module not available.") })
                end
            end,
        },
        {
            text = _("Sync Now"),
            keep_menu_open = false,
            callback = function()
                -- Explicit user action: OK to connect to Wi-Fi if offline
                NetworkMgr:runWhenOnline(function()
                    UIManager:show(Notification:new{ text = _("Syncing with Sink server...") })
                    self:_syncDocument(true)
                end)
            end,
        },
        {
            text = _("Auto-Sync on Read/Close/Sleep"),
            checked_func = function()
                return self.settings.auto_sync
            end,
            callback = function()
                self.settings.auto_sync = not self.settings.auto_sync
                self:saveSettings()
            end,
        },
        {
            text = _("Server URL"),
            keep_menu_open = true,
            subtext_func = function()
                return self.settings.server_url
            end,
            callback = function(touch_menu_instance)
                self:showInputDialog(_("Server URL"), self.settings.server_url, function(val)
                    self.settings.server_url = cleanUrl(val)
                    self:saveSettings()
                    if touch_menu_instance and touch_menu_instance.updateItems then
                        pcall(function() touch_menu_instance:updateItems() end)
                    end
                end)
            end,
        },
        {
            text = _("Device Account Status"),
            subtext_func = function()
                return (self.settings.username ~= "" and ("Paired (" .. self.settings.username .. ")")) or _("Not paired")
            end,
            callback = function()
                if self.settings.username ~= "" then
                    NetworkMgr:runWhenOnline(function()
                        self:testConnection()
                    end)
                else
                    if SinkPairing then
                        SinkPairing:startPairing(self)
                    end
                end
            end,
        },
    }
end

function Sink:showInputDialog(title, initial_value, on_confirm)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial_value or "",
        save_callback = function(val)
            if on_confirm then on_confirm(val) end
        end,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Sink:testConnection()
    UIManager:show(Notification:new{ text = _("Checking connection to Sink server...") })
    local res, err = self:_makeRequest("GET", "/users/auth")
    if err or not res then
        UIManager:show(InfoMessage:new{
            text = _("Connection failed:\n") .. tostring(err or "Unknown error"),
        })
        return
    end

    if res.status == 200 then
        UIManager:show(InfoMessage:new{
            text = _("✓ Connected & Synced!\nAccount: ") .. tostring(self.settings.username),
        })
    elseif res.status == 401 then
        UIManager:show(InfoMessage:new{
            text = _("Authentication failed (401 Unauthorized).\nTap 'Pair Device' to re-link your e-reader."),
        })
    else
        UIManager:show(InfoMessage:new{
            text = string.format(_("Server returned HTTP %d:\n%s"), res.status, tostring(res.raw or "")),
        })
    end
end

return Sink
