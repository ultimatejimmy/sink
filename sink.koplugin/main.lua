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
local Loc = nil
pcall(function()
    Loc = require(plugin_path .. "localization_sink")
    if Loc and Loc.init then
        Loc:init()
        _ = function(text, ...)
            return Loc:t(text, ...)
        end
    end
end)

local Event = nil
pcall(function() Event = require("ui/event") end)
local util = nil
pcall(function() util = require("util") end)

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local SinkPairing = nil
pcall(function()
    SinkPairing = require(plugin_path .. "sink_pairing")
end)
local SinkUpdater = nil
pcall(function()
    SinkUpdater = require(plugin_path .. "sink_updater")
    if SinkUpdater and Loc then SinkUpdater.loc = Loc end
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
    sync_xray = true,
    welcome_shown = false,
    checksum_method = "filename",
    last_sync_time = 0,
    last_sync_doc = "",
}

function Sink:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
    self.last_page_turn_time = 0
    self.backend_version = "Unknown"

    if not self.settings.welcome_shown and self:isDefaultServerUrl() then
        if UIManager and UIManager.nextTick then
            UIManager:nextTick(function()
                self:showWelcomeDialog()
            end)
        end
    end
end

function Sink:isDefaultServerUrl()
    local url = self.settings.server_url or ""
    return url == "" or url == DEFAULT_SETTINGS.server_url or url:find("your%-subdomain") ~= nil
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

    if resp_headers and (resp_headers["x-sink-backend-version"] or resp_headers["X-Sink-Backend-Version"]) then
        self.backend_version = resp_headers["x-sink-backend-version"] or resp_headers["X-Sink-Backend-Version"]
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

function Sink:_urlEncode(str)
    if not str then return "" end
    return str:gsub("\n", "\r\n"):gsub("([^%w%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function Sink:_getBinaryMD5()
    if not self.ui or not self.ui.document then return nil end

    if self.ui.doc_settings then
        local checksum = self.ui.doc_settings:readSetting("partial_md5_checksum")
        if checksum and checksum ~= "" then
            return checksum
        end
        local legacy = self.ui.doc_settings:readSetting("doc_md5") or self.ui.doc_settings:readSetting("md5")
        if legacy and legacy ~= "" then
            return legacy
        end
    end

    if self.ui.document.file and util and util.partialMD5 then
        local ok, md5_val = pcall(function() return util.partialMD5(self.ui.document.file) end)
        if ok and md5_val and md5_val ~= "" then
            if self.ui.doc_settings then
                pcall(function() self.ui.doc_settings:saveSetting("partial_md5_checksum", md5_val) end)
            end
            return md5_val
        end
    end

    return nil
end

function Sink:_getFilenameMD5()
    if not self.ui or not self.ui.document or not self.ui.document.file then return nil, nil end

    local file_name = nil
    if util and util.splitFilePathName then
        local _, fn = util.splitFilePathName(self.ui.document.file)
        file_name = fn
    else
        file_name = self.ui.document.file:match("[^/]+$") or self.ui.document.file:match("[^\\]+$")
    end

    if file_name and file_name ~= "" then
        local ok, sha2 = pcall(require, "ffi/sha2")
        if ok and sha2 and sha2.md5 then
            return sha2.md5(file_name), file_name
        end
    end

    return nil, file_name
end

function Sink:_getBookMetadata()
    if not self.ui then return nil, nil, nil end

    local props = self.ui.doc_props or (self.ui.document and self.ui.document.getProps and self.ui.document:getProps()) or {}
    local title = props.title or props.display_title
    local authors = props.authors

    local _, file_name = self:_getFilenameMD5()
    if (not title or title == "") and file_name then
        title = file_name:match("([^/\\]+)%.%w+$") or file_name
    end

    if not title or title == "" then
        return nil, nil, nil
    end

    -- Normalize title: remove parenthesized series/subtitles, lowercase, strip punctuation
    local clean_title = title:lower()
    clean_title = clean_title:gsub("%b()", ""):gsub("%b[]", "")
    clean_title = clean_title:gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    clean_title = clean_title:gsub(",%s*the$", ""):gsub(",%s*a$", ""):gsub(",%s*an$", "")
    clean_title = clean_title:gsub("[^%w%s]", " ")
    clean_title = clean_title:match("^%s*(.-)%s*$"):gsub("%s+", " ")

    local clean_authors = ""
    if authors and authors ~= "" then
        clean_authors = authors:lower():gsub("[^%w%s]", " ")
        clean_authors = clean_authors:match("^%s*(.-)%s*$"):gsub("%s+", " ")
    end

    local book_key = clean_authors ~= "" and (clean_title .. "::" .. clean_authors) or clean_title
    return title, authors, book_key
end

function Sink:_getDocumentMD5()
    if not self.ui or not self.ui.document then return nil end

    if self.settings.checksum_method == "filename" then
        return (self:_getFilenameMD5()) or self:_getBinaryMD5()
    else
        return self:_getBinaryMD5() or (self:_getFilenameMD5())
    end
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

    if not Event then
        pcall(function() Event = require("ui/event") end)
    end

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
    local model = "KOReader"
    if Device then
        if Device.model then
            model = tostring(Device.model)
        elseif Device.getModel then
            pcall(function() model = tostring(Device:getModel()) end)
        end
    end

    if not self.settings.device_id or self.settings.device_id == "" or self.settings.device_id == "kindle_device" then
        local clean_model = model:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
        if clean_model == "" then clean_model = "reader" end
        local rand_suffix = string.format("%04x", math.random(0, 0xffff))
        self.settings.device_id = clean_model .. "_" .. rand_suffix
        self:saveSettings()
    end

    return model, self.settings.device_id
end

--------------------------------------------------------------------------------
-- Core Sync Actions
--------------------------------------------------------------------------------

function Sink:_pullDocument(is_manual)
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
        logger.warn("Sink: unable to extract local progress for document " .. tostring(doc_md5))
        return false
    end

    local title, authors, book_key = self:_getBookMetadata()
    local bin_hash = self:_getBinaryMD5()
    local fn_hash = self:_getFilenameMD5()

    local endpoint = "/syncs/progress/" .. doc_md5
    local params = {}
    if book_key and book_key ~= "" then
        table.insert(params, "book_key=" .. self:_urlEncode(book_key))
    end
    if title and title ~= "" then
        table.insert(params, "title=" .. self:_urlEncode(title))
    end
    if authors and authors ~= "" then
        table.insert(params, "authors=" .. self:_urlEncode(authors))
    end
    local alt_list = {}
    if bin_hash and bin_hash ~= doc_md5 then table.insert(alt_list, bin_hash) end
    if fn_hash and fn_hash ~= doc_md5 then table.insert(alt_list, fn_hash) end
    if #alt_list > 0 then
        table.insert(params, "alt_hashes=" .. table.concat(alt_list, ","))
    end
    if #params > 0 then
        endpoint = endpoint .. "?" .. table.concat(params, "&")
    end

    local res, err = self:_makeRequest("GET", endpoint)
    if err or not res or (res.status ~= 200 and res.status ~= 201) then
        logger.warn("Sink: error fetching remote progress: " .. tostring(err or res and res.status))
        if is_manual then
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch remote progress:\n") .. tostring(err or (res and res.raw) or "Unknown error"),
            })
        end
        return false
    end

    local remote = res.body or {}
    local remote_pct = tonumber(remote.percentage)
    local remote_prog = remote.progress
    local remote_ts = tonumber(remote.timestamp) or 0

    if not remote_prog or not remote_pct then
        logger.info("Sink: no remote progress recorded yet for document " .. tostring(doc_md5))
        if is_manual then
            UIManager:show(Notification:new{
                text = _("No remote progress found for this book."),
            })
        end
        return true
    end

    -- If already identical progress, no update needed
    if remote_prog == local_prog then
        logger.info("Sink: document already at current progress (" .. tostring(remote_prog) .. ")")
        if is_manual then
            UIManager:show(Notification:new{
                text = _("Already synchronized with cloud."),
            })
        end
        return true
    end

    -- Determine if remote should be applied:
    -- 1. If remote is further ahead by >0.1% (e.g. read on phone/kindle), pull!
    -- 2. If user just opened document (last_page_turn_time == 0) and remote has progress, pull!
    -- 3. If remote timestamp is newer than when the user actually turned a page locally, pull!
    local should_pull = false
    if remote_pct > (local_pct + 0.001) then
        should_pull = true
    elseif (self.last_page_turn_time or 0) == 0 and remote_ts > 0 then
        should_pull = true
    elseif remote_ts > 0 and (self.last_page_turn_time or 0) > 0 then
        should_pull = (remote_ts > self.last_page_turn_time)
    end

    if should_pull then
        logger.info(string.format("Sink: pulling remote progress: %.1f%% (%s)", remote_pct * 100, remote.device or "Remote"))
        self:_applyRemoteProgress(remote_prog, remote_pct)
        self.settings.last_sync_time = remote_ts > 0 and remote_ts or os.time()
        self.settings.last_sync_doc = doc_md5
        self:saveSettings()

        if self.settings.sync_xray then
            self:_pullXrayCache(doc_md5, book_key)
        end

        if is_manual then
            UIManager:show(Notification:new{
                text = string.format(_("Synced from cloud: %.1f%% (%s)"), remote_pct * 100, remote.device or "Remote"),
            })
        end
        return true
    else
        logger.info(string.format("Sink: local progress is current (local: %.1f%%, remote: %.1f%%). Skipping pull.", (local_pct or 0) * 100, remote_pct * 100))
        if self.settings.sync_xray then
            self:_pullXrayCache(doc_md5, book_key)
        end
        if is_manual then
            UIManager:show(Notification:new{
                text = string.format(_("Local position is current (%.1f%%)."), (local_pct or 0) * 100),
            })
        end
        return true
    end
end

function Sink:_getXrayCachePath(file_path)
    file_path = file_path or (self.ui and self.ui.document and self.ui.document.file)
    if not file_path then return nil end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.getSidecarDir then
        local sidecar = DocSettings:getSidecarDir(file_path)
        if sidecar then return sidecar .. "/xray_cache.lua" end
    end
    local base = file_path:match("^(.-)%.[^%.]+$") or file_path
    return base .. ".sdr/xray_cache.lua"
end

function Sink:_pushXrayCache(doc_md5, book_key)
    if not self.settings.sync_xray then return end
    local cache_file = self:_getXrayCachePath()
    if not cache_file then return end

    local f = io.open(cache_file, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then return end
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok or type(lfs) ~= "table" then pcall(function() lfs = require("lfs") end) end
    local mtime = os.time()
    if lfs and lfs.attributes then
        local attr = lfs.attributes(cache_file)
        if attr and attr.modification then mtime = attr.modification end
    end

    logger.info("Sink: pushing X-Ray cache to cloud for book: " .. tostring(book_key or doc_md5))
    self:_makeRequest("PUT", "/syncs/xray", {
        document = doc_md5,
        book_key = book_key,
        cache_data = content,
        timestamp = mtime,
    })
end

function Sink:_pullXrayCache(doc_md5, book_key)
    if not self.settings.sync_xray then return end
    local cache_file = self:_getXrayCachePath()
    if not cache_file then return end

    local endpoint = "/syncs/xray/" .. doc_md5
    if book_key and book_key ~= "" then
        endpoint = endpoint .. "?book_key=" .. self:_urlEncode(book_key)
    end

    local res, err = self:_makeRequest("GET", endpoint)
    if err or not res or res.status ~= 200 or not res.body or not res.body.cache_data then
        return
    end

    local remote_ts = tonumber(res.body.timestamp) or 0
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok or type(lfs) ~= "table" then pcall(function() lfs = require("lfs") end) end
    local local_ts = 0
    if lfs and lfs.attributes then
        local attr = lfs.attributes(cache_file)
        if attr and attr.modification then local_ts = attr.modification end
    end

    -- Only overwrite if remote is newer or local does not exist
    if remote_ts > local_ts or local_ts == 0 then
        -- Ensure directory exists
        local dir = cache_file:match("(.+)/[^/]+$")
        if dir and lfs and lfs.mkdir then
            pcall(function() lfs.mkdir(dir) end)
        end
        local f = io.open(cache_file, "w")
        if f then
            f:write(res.body.cache_data)
            f:close()
            logger.info("Sink: updated local X-Ray cache from cloud for " .. tostring(book_key or doc_md5))
        end
    end
end

function Sink:_pushDocument(is_manual)
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
        logger.warn("Sink: unable to extract local progress for document " .. tostring(doc_md5))
        return false
    end

    local title, authors, book_key = self:_getBookMetadata()
    local bin_hash = self:_getBinaryMD5()
    local fn_hash = self:_getFilenameMD5()
    local alt_list = {}
    if bin_hash and bin_hash ~= doc_md5 then table.insert(alt_list, bin_hash) end
    if fn_hash and fn_hash ~= doc_md5 then table.insert(alt_list, fn_hash) end

    local dev_model, dev_id = self:_getDeviceInfo()
    logger.info(string.format("Sink: pushing local progress: %.1f%% to cloud", (local_pct or 0) * 100))

    local push_payload = {
        document = doc_md5,
        percentage = local_pct,
        progress = local_prog,
        device = dev_model,
        device_id = dev_id,
        title = title,
        authors = authors,
        book_key = book_key,
        alt_hashes = #alt_list > 0 and alt_list or nil,
    }

    local push_res, push_err = self:_makeRequest("PUT", "/syncs/progress", push_payload)

    if push_err or not push_res or push_res.status ~= 200 then
        logger.warn("Sink: error pushing progress: " .. tostring(push_err or push_res and push_res.status))
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

    if self.settings.sync_xray then
        self:_pushXrayCache(doc_md5, book_key)
    end

    if is_manual then
        UIManager:show(Notification:new{
            text = string.format(_("Synced to cloud: %.1f%%"), (local_pct or 0) * 100),
        })
    end
    return true
end

function Sink:_syncDocument(is_manual_or_mode, is_manual_arg)
    local mode = "full"
    local is_manual = false
    if type(is_manual_or_mode) == "string" then
        mode = is_manual_or_mode
        is_manual = is_manual_arg or false
    elseif type(is_manual_or_mode) == "boolean" then
        is_manual = is_manual_or_mode
    end

    if mode == "pull" then
        return self:_pullDocument(is_manual)
    elseif mode == "push" then
        return self:_pushDocument(is_manual)
    else
        -- Full bidirectional sync (manual button / network reconnect)
        local doc_md5 = self:_getDocumentMD5()
        if not doc_md5 then
            if is_manual then
                UIManager:show(InfoMessage:new{ text = _("No active document found to sync.") })
            end
            return false
        end

        local local_pct, local_prog = self:_getLocalProgress()
        if not local_pct or not local_prog then return false end

        local title, authors, book_key = self:_getBookMetadata()
        local bin_hash = self:_getBinaryMD5()
        local fn_hash = self:_getFilenameMD5()

        local endpoint = "/syncs/progress/" .. doc_md5
        local params = {}
        if book_key and book_key ~= "" then table.insert(params, "book_key=" .. self:_urlEncode(book_key)) end
        if title and title ~= "" then table.insert(params, "title=" .. self:_urlEncode(title)) end
        if authors and authors ~= "" then table.insert(params, "authors=" .. self:_urlEncode(authors)) end
        local alt_list = {}
        if bin_hash and bin_hash ~= doc_md5 then table.insert(alt_list, bin_hash) end
        if fn_hash and fn_hash ~= doc_md5 then table.insert(alt_list, fn_hash) end
        if #alt_list > 0 then table.insert(params, "alt_hashes=" .. table.concat(alt_list, ",")) end
        if #params > 0 then endpoint = endpoint .. "?" .. table.concat(params, "&") end

        local res, err = self:_makeRequest("GET", endpoint)
        if err or not res or (res.status ~= 200 and res.status ~= 201) then
            return self:_pushDocument(is_manual)
        end

        local remote = res.body or {}
        local remote_pct = tonumber(remote.percentage)
        local remote_prog = remote.progress
        local remote_ts = tonumber(remote.timestamp) or 0

        if not remote_prog or not remote_pct then
            return self:_pushDocument(is_manual)
        end

        if remote_prog == local_prog then
            if self.settings.sync_xray then
                self:_pullXrayCache(doc_md5, book_key)
            end
            if is_manual then
                UIManager:show(Notification:new{ text = _("Already synchronized with cloud.") })
            end
            return true
        end

        if remote_pct > (local_pct + 0.001) then
            return self:_pullDocument(is_manual)
        elseif (self.last_page_turn_time or 0) == 0 and remote_ts > 0 then
            return self:_pullDocument(is_manual)
        elseif remote_ts > 0 and (self.last_page_turn_time or 0) > 0 and remote_ts > self.last_page_turn_time then
            return self:_pullDocument(is_manual)
        else
            return self:_pushDocument(is_manual)
        end
    end
end

--------------------------------------------------------------------------------
-- Non-Intrusive Lifecycle Hooks
-- Crucial: Must NEVER trigger Wi-Fi popups in background.
-- Uses NetworkMgr:isOnline() and completely suppresses errors.
--------------------------------------------------------------------------------

function Sink:_silentBackgroundSync(trigger_name, mode)
    if not self.settings.auto_sync then
        return
    end

    -- Non-intrusive check: is the device currently connected to Wi-Fi?
    if not NetworkMgr:isOnline() then
        logger.info("Sink [" .. trigger_name .. "]: Device is offline. Silently skipping sync.")
        return
    end

    logger.info("Sink [" .. trigger_name .. "]: Device online. Performing silent sync (" .. tostring(mode or "full") .. ").")
    local ok, err = pcall(function()
        self:_syncDocument(mode or "full", false)
    end)
    if not ok then
        -- Suppress all background errors
        logger.warn("Sink [" .. trigger_name .. "] silent sync error: " .. tostring(err))
    end
end

function Sink:onPageUpdate(page)
    self.last_page_turn_time = os.time()
end

function Sink:onReaderReady()
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            self:_silentBackgroundSync("onReaderReady", "pull")
        end)
    else
        self:_silentBackgroundSync("onReaderReady", "pull")
    end
end

function Sink:onCloseDocument()
    self.last_page_turn_time = os.time()
    self:_silentBackgroundSync("onCloseDocument", "push")
end

function Sink:onSuspend()
    self.last_page_turn_time = os.time()
    self:_silentBackgroundSync("onSuspend", "push")
end

function Sink:onResume()
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            self:_silentBackgroundSync("onResume", "pull")
        end)
    else
        self:_silentBackgroundSync("onResume", "pull")
    end
end

function Sink:onNetworkConnected()
    self:_silentBackgroundSync("onNetworkConnected", "full")
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
    self:checkServerUrlAndPair()
end

function Sink:checkServerUrlAndPair(touch_menu_instance)
    if self:isDefaultServerUrl() then
        self:showInputDialog(
            _("Server URL Required"),
            self.settings.server_url,
            function(val)
                local clean = cleanUrl(val)
                if clean ~= "" and clean ~= DEFAULT_SETTINGS.server_url and clean:find("your%-subdomain") == nil then
                    self.settings.server_url = clean
                    self.settings.welcome_shown = true
                    self:saveSettings()
                    if touch_menu_instance and touch_menu_instance.updateItems then
                        pcall(function() touch_menu_instance:updateItems() end)
                    end
                    if SinkPairing then
                        SinkPairing:startPairing(self, function()
                            self:_syncDocument(false)
                            if touch_menu_instance and touch_menu_instance.updateItems then
                                pcall(function() touch_menu_instance:updateItems() end)
                            end
                        end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Please enter a valid Cloudflare Worker URL before pairing."),
                    })
                end
            end
        )
        return
    end

    if SinkPairing then
        SinkPairing:startPairing(self, function()
            self:_syncDocument(false)
            if touch_menu_instance and touch_menu_instance.updateItems then
                pcall(function() touch_menu_instance:updateItems() end)
            end
        end)
    else
        UIManager:show(InfoMessage:new{ text = _("Pairing module not available.") })
    end
end

local function injectSinkIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function removeItem(tbl, target_id)
        if type(tbl) ~= "table" then return end
        for k, v in pairs(tbl) do
            if v == target_id then
                table.remove(tbl, k)
                return
            elseif type(v) == "table" then
                removeItem(v, target_id)
            end
        end
    end

    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            removeItem(order, "sink_sync")
            table.insert(order.tools, 1, "sink_sync")
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
    local is_paired = self.settings.username and self.settings.username ~= ""

    return {
        -- 1. Primary Action: Instant Sync
        {
            text = _("Sync Progress Now"),
            enabled_func = function()
                return self.settings.username ~= ""
            end,
            keep_menu_open = false,
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    UIManager:show(Notification:new{ text = _("Syncing with Sink server...") })
                    self:_syncDocument(true)
                end)
            end,
        },

        -- 2. Daily Reading Toggle: Auto-Sync
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

        -- 3. X-Ray Cache Sync Toggle
        {
            text = _("Sync X-Ray Cache"),
            checked_func = function()
                return self.settings.sync_xray
            end,
            callback = function()
                self.settings.sync_xray = not self.settings.sync_xray
                self:saveSettings()
            end,
            separator = true,
        },

        -- 4. Live Account & Connection Status
        {
            text_func = function()
                if self.settings.username and self.settings.username ~= "" then
                    return string.format(_("Account: Paired (%s)"), self.settings.username)
                else
                    return _("Account: Not Paired (Tap to pair)")
                end
            end,
            keep_menu_open = true,
            callback = function(touch_menu_instance)
                if self.settings.username ~= "" then
                    NetworkMgr:runWhenOnline(function()
                        self:testConnection()
                    end)
                else
                    self:checkServerUrlAndPair(touch_menu_instance)
                end
            end,
        },

        -- 5. Device Setup / Pairing Action
        {
            text_func = function()
                if self.settings.username and self.settings.username ~= "" then
                    return _("Re-Pair Device (Phone/PC)")
                else
                    return _("Pair Device (Phone/PC)")
                end
            end,
            keep_menu_open = false,
            callback = function(touch_menu_instance)
                self:checkServerUrlAndPair(touch_menu_instance)
            end,
        },

        -- 6. Paired Devices List
        {
            text = _("Paired Devices"),
            enabled_func = function()
                return self.settings.username ~= ""
            end,
            keep_menu_open = true,
            callback = function()
                self:showPairedDevicesDialog()
            end,
        },

        -- 7. Synced Books (Cloud Library)
        {
            text = _("Synced Books (Cloud Library)"),
            enabled_func = function()
                return self.settings.username ~= ""
            end,
            keep_menu_open = true,
            callback = function()
                self:showCloudLibraryDialog()
            end,
            separator = true,
        },

        -- 8. Document Matching Method
        {
            text_func = function()
                local method = self.settings.checksum_method or "filename"
                local label = method == "filename" and _("Filename (Cross-Device)") or _("Binary (Exact File)")
                return string.format(_("Matching Method: %s"), label)
            end,
            sub_item_table = {
                {
                    text = _("Filename (Recommended for Phone/Calibre)"),
                    checked_func = function()
                        return (self.settings.checksum_method or "filename") == "filename"
                    end,
                    callback = function(touch_menu_instance)
                        self.settings.checksum_method = "filename"
                        self:saveSettings()
                        if touch_menu_instance and touch_menu_instance.updateItems then
                            pcall(function() touch_menu_instance:updateItems() end)
                        end
                    end,
                },
                {
                    text = _("Binary (Strict byte-for-byte checksum)"),
                    checked_func = function()
                        return self.settings.checksum_method == "binary"
                    end,
                    callback = function(touch_menu_instance)
                        self.settings.checksum_method = "binary"
                        self:saveSettings()
                        if touch_menu_instance and touch_menu_instance.updateItems then
                            pcall(function() touch_menu_instance:updateItems() end)
                        end
                    end,
                },
            },
        },

        -- 9. Server URL Configuration
        {
            text_func = function()
                local url = self.settings.server_url or ""
                local display = url:gsub("^https?://", "")
                if #display > 28 then
                    display = display:sub(1, 25) .. "..."
                end
                return string.format(_("Server: %s"), display)
            end,
            keep_menu_open = true,
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

        -- 10. Check for Updates (Plugin & Backend)
        {
            text = _("Check for Updates"),
            keep_menu_open = true,
            callback = function()
                if SinkUpdater then
                    SinkUpdater:showUpdateDialog(self)
                else
                    UIManager:show(InfoMessage:new{ text = _("Updater module not available.") })
                end
            end,
        },

        -- 11. Welcome & Setup Guide
        {
            text = _("Welcome & Setup Guide"),
            keep_menu_open = true,
            callback = function()
                self:showWelcomeDialog()
            end,
        },

        -- 12. Unlink / Reset Option
        {
            text = _("Unlink Device/Clear Account"),
            enabled_func = function()
                return self.settings.username ~= ""
            end,
            keep_menu_open = true,
            callback = function(touch_menu_instance)
                self.settings.username = ""
                self.settings.userkey = ""
                self:saveSettings()
                if touch_menu_instance and touch_menu_instance.updateItems then
                    pcall(function() touch_menu_instance:updateItems() end)
                end
                UIManager:show(Notification:new{ text = _("Device unlinked.") })
            end,
        },
    }
end

function Sink:showPairedDevicesDialog()
    UIManager:show(Notification:new{ text = _("Fetching paired devices...") })
    local res, err = self:_makeRequest("GET", "/syncs/devices")
    if err or not res or res.status ~= 200 then
        UIManager:show(InfoMessage:new{
            text = _("Could not fetch paired devices:\n") .. tostring(err or (res and res.raw) or "Error"),
        })
        return
    end

    local devices = (res.body and res.body.devices) or {}
    if #devices == 0 then
        UIManager:show(InfoMessage:new{ text = _("No paired devices found on server.") })
        return
    end

    local Menu = require("ui/widget/menu")
    local menu_items = {}
    for idx, dev in ipairs(devices) do
        local ts = tonumber(dev.last_sync_at)
        local last_sync = _("Unknown")
        if ts and ts > 0 then
            pcall(function() last_sync = os.date("%Y-%m-%d %H:%M", ts) end)
        end
        local model = tostring(dev.device_model or "Reader")
        local id_str = tostring(dev.device_id or "")
        local is_current = (id_str == self.settings.device_id)

        local label = string.format("%s (%s)%s", model, id_str, is_current and _(" [This Device]") or "")
        local subtitle = string.format(_("Last active: %s"), last_sync)

        table.insert(menu_items, {
            text = label .. "\n  " .. subtitle,
            keep_menu_open = true,
            callback = function(touch_menu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Remove device '%s' (%s) from your server?"), model, id_str),
                    ok_text = _("Remove"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local del_res, del_err = self:_makeRequest("DELETE", "/syncs/devices/" .. id_str)
                        if del_res and del_res.status == 200 then
                            UIManager:show(Notification:new{ text = _("Device removed.") })
                            self:showPairedDevicesDialog()
                        else
                            UIManager:show(InfoMessage:new{ text = _("Failed to remove device: ") .. tostring(del_err or (del_res and del_res.raw) or "") })
                        end
                    end,
                })
            end,
        })
    end

    local dev_menu
    dev_menu = Menu:new{
        title = _("Paired Devices"),
        item_table = menu_items,
        is_borderless = false,
        on_close_callback = function() end,
    }
    UIManager:show(dev_menu)
end

function Sink:showCloudLibraryDialog()
    UIManager:show(Notification:new{ text = _("Fetching cloud library...") })
    local res, err = self:_makeRequest("GET", "/syncs/books")
    if err or not res or res.status ~= 200 then
        UIManager:show(InfoMessage:new{
            text = _("Could not fetch synced books:\n") .. tostring(err or (res and res.raw) or "Error"),
        })
        return
    end

    local books = (res.body and res.body.books) or {}
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books currently synced in cloud.") })
        return
    end

    local Menu = require("ui/widget/menu")
    local menu_items = {}
    for idx, b in ipairs(books) do
        local pct = (tonumber(b.percentage) or 0) * 100
        local raw_title = b.title
        if not raw_title or raw_title == "" then
            local h = tostring(b.document_hash or "book")
            raw_title = #h > 12 and (h:sub(1, 12) .. "...") or h
        end
        local author = (b.authors and b.authors ~= "") and tostring(b.authors) or ""
        local date_str = ""
        local ts = tonumber(b.timestamp)
        if ts and ts > 0 then
            pcall(function() date_str = os.date("%Y-%m-%d %H:%M", ts) end)
        end
        local dev_name = tostring(b.device or "Reader")
        local doc_hash = b.document_hash

        local item_text
        if author ~= "" then
            item_text = string.format("%s\n  %s\n  %.1f%%  •  %s  (%s)", raw_title, author, pct, date_str, dev_name)
        else
            item_text = string.format("%s\n  %.1f%%  •  %s  (%s)", raw_title, pct, date_str, dev_name)
        end

        table.insert(menu_items, {
            text = item_text,
            keep_menu_open = true,
            callback = function(touch_menu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                local detail_author = (author ~= "") and ("\nAuthor: " .. author) or ""
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Book: %s%s\nProgress: %.1f%%\nLast Device: %s\nLast Sync: %s\n\nRemove this book's progress from cloud server?"), raw_title, detail_author, pct, dev_name, date_str),
                    ok_text = _("Remove from Cloud"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        if doc_hash then
                            local del_res, del_err = self:_makeRequest("DELETE", "/syncs/books/" .. doc_hash)
                            if del_res and del_res.status == 200 then
                                UIManager:show(Notification:new{ text = _("Book removed from cloud library.") })
                                self:showCloudLibraryDialog()
                            else
                                UIManager:show(InfoMessage:new{ text = _("Failed to delete book: ") .. tostring(del_err or (del_res and del_res.raw) or "") })
                            end
                        end
                    end,
                })
            end,
        })
    end

    local lib_menu
    lib_menu = Menu:new{
        title = _("Synced Books (Cloud Library)"),
        item_table = menu_items,
        is_borderless = false,
        on_close_callback = function() end,
    }
    UIManager:show(lib_menu)
end

function Sink:showWelcomeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Size = require("ui/size")
    local Screen = Device and Device.screen
    local Blitbuffer = nil
    pcall(function() Blitbuffer = require("ffi/blitbuffer") end)
    local FrameContainer = nil
    pcall(function() FrameContainer = require("ui/widget/container/framecontainer") end)
    local QRWidget = nil
    pcall(function() QRWidget = require("ui/widget/qrwidget") end)

    local deploy_url = "https://github.com/ultimatejimmy/sink"
    local added_widgets = {}

    table.insert(added_widgets, TextBoxWidget:new{
        text = _("Welcome to Sink!\n\nSink gives you private, seamless reading progress and X-Ray synchronization across all your KOReader devices.\n\nSetup requires your own free Cloudflare Worker backend (takes 2 minutes, 100% free forever on Cloudflare's free tier, zero credit card required)."),
        face = Font:getFace("infofont"),
        alignment = "left",
    })

    if QRWidget and FrameContainer and Blitbuffer then
        pcall(function()
            local qr_size = Screen and Screen.scaleBySize and Screen:scaleBySize(150) or 150
            local qr = QRWidget:new{
                text = deploy_url,
                width = qr_size,
                height = qr_size,
            }
            local pad = Size and Size.padding and Size.padding.default or 6
            local qr_box = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                padding = pad,
                bordersize = 0,
                qr,
            }
            local VerticalSpan = require("ui/widget/verticalspan")
            table.insert(added_widgets, VerticalSpan:new{ width = 6 })
            table.insert(added_widgets, qr_box)
            table.insert(added_widgets, VerticalSpan:new{ width = 6 })
            table.insert(added_widgets, TextBoxWidget:new{
                text = string.format(_("Scan to deploy free Worker:\n%s"), deploy_url),
                face = Font:getFace("infofont"),
                alignment = "center",
            })
        end)
    end

    local welcome_dlg = nil
    local buttons = {
        {
            {
                text = _("Set Server URL"),
                id = "set_url",
                callback = function()
                    if welcome_dlg then UIManager:close(welcome_dlg) end
                    self.settings.welcome_shown = true
                    self:saveSettings()
                    self:showInputDialog(_("Server URL"), self.settings.server_url, function(val)
                        self.settings.server_url = cleanUrl(val)
                        self:saveSettings()
                    end)
                end,
            },
            {
                text = _("Dismiss"),
                id = "close",
                callback = function()
                    self.settings.welcome_shown = true
                    self:saveSettings()
                    if welcome_dlg then UIManager:close(welcome_dlg) end
                end,
            },
        },
    }

    welcome_dlg = ButtonDialog:new{
        title = _("Welcome to Sink"),
        title_align = "center",
        use_info_style = false,
        _added_widgets = added_widgets,
        buttons = buttons,
    }
    UIManager:show(welcome_dlg)
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
