-- sink_updater.lua — Sink Plugin OTA Updater & Backend Compatibility Checker
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")
local json = require("json")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")

local GITHUB_OWNER = "ultimatejimmy"
local GITHUB_REPO = "sink"
local ASSET_NAME = "sink.koplugin.zip"

local M = {}
M.loc = nil

local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+$")
    or "plugins/sink.koplugin"

local function _(text, ...)
    if M.loc and M.loc.t then
        return M.loc:t(text, ...)
    end
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, text, ...)
        if ok then return s end
    end
    return text
end

local function _currentVersion()
    local meta_path = _plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "1.0.0"
end

local function _versionLessThan(a, b)
    local function parts(v)
        local t = {}
        if not v then return t end
        for n in v:gmatch("(%d+)") do
            t[#t + 1] = tonumber(n)
        end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local va = pa[i] or 0
        local vb = pb[i] or 0
        if va < vb then return true end
        if va > vb then return false end
    end
    return false
end

local function _httpRequest(url, headers)
    local chunks = {}
    local is_https = url:match("^https://") ~= nil
    local request_fn = is_https and https.request or http.request

    local req_headers = headers or {}
    req_headers["User-Agent"] = "KOReader-Sink-Updater/1.0"
    req_headers["Accept"] = "application/vnd.github.v3+json"

    local ok_res, code, resp_headers, status_line
    local pcall_ok, pcall_err = pcall(function()
        ok_res, code, resp_headers, status_line = request_fn{
            url = url,
            method = "GET",
            headers = req_headers,
            sink = ltn12.sink.table(chunks),
            timeout = 10,
        }
    end)

    if not pcall_ok then return false, nil, tostring(pcall_err) end
    local status_num = tonumber(code) or (type(ok_res) == "number" and ok_res) or 0
    return true, status_num, table.concat(chunks)
end

function M:checkPluginUpdate(callback)
    local url = string.format("https://api.github.com/repos/%s/%s/releases/latest", GITHUB_OWNER, GITHUB_REPO)
    local ok, code, body = _httpRequest(url)
    if not ok or code ~= 200 or not body then
        if callback then callback(nil, _("Could not reach GitHub Releases (HTTP %s).", tostring(code or "Error"))) end
        return
    end

    local release = nil
    pcall(function() release = json.decode(body) end)
    if not release or not release.tag_name then
        if callback then callback(nil, _("Invalid release response from GitHub.")) end
        return
    end

    local remote_ver = release.tag_name:gsub("^v", "")
    local local_ver = _currentVersion()
    local has_update = _versionLessThan(local_ver, remote_ver)

    local download_url = nil
    if release.assets and type(release.assets) == "table" then
        for _, asset in ipairs(release.assets) do
            if asset.name == ASSET_NAME or asset.name:match("%.zip$") then
                download_url = asset.browser_download_url
                break
            end
        end
    end

    if callback then
        callback({
            local_version = local_ver,
            remote_version = remote_ver,
            has_update = has_update,
            body = release.body or "",
            download_url = download_url,
            release_url = release.html_url or "",
        })
    end
end

function M:showUpdateDialog(sink_instance)
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = _("Checking for updates...") })

    -- Defer the blocking network call so the notification renders and the
    -- menu closes before we hit the socket. Without this the synchronous
    -- HTTPS request blocks the UI thread mid-callback and crashes KOReader.
    UIManager:scheduleIn(0.5, function()
        local ok, schedule_err = pcall(function()
            self:checkPluginUpdate(function(info, check_err)
                if check_err or not info then
                    UIManager:show(InfoMessage:new{
                        text = _("Update check failed:\n") .. tostring(check_err or "Unknown error"),
                    })
                    return
                end

                -- GitHub check done. Now try a live health check for backend version.
                -- Safe to block here — the menu is already closed and the notification
                -- is rendered. Use pcall so a slow/unreachable backend doesn't crash.
                pcall(function()
                    local health_res = sink_instance:_makeRequest("GET", "/health")
                    if health_res and health_res.body and health_res.body.version then
                        sink_instance.backend_version = health_res.body.version
                    elseif health_res and health_res.headers then
                        local v = health_res.headers["x-sink-backend-version"]
                            or health_res.headers["X-Sink-Backend-Version"]
                        if v then sink_instance.backend_version = v end
                    end
                end)

                local backend_ver = sink_instance.backend_version or "Unknown"
                local expected_backend = "1.1.0"
                local backend_status = (backend_ver == "Unknown") and _("Not reachable")
                    or (_versionLessThan(backend_ver, expected_backend)
                        and string.format(_("%s (Update recommended: %s)"), backend_ver, expected_backend)
                        or string.format(_("%s (Up to date)"), backend_ver))

                local msg = string.format(
                    _("Sink Plugin: %s\nLatest Available: %s\n\nCloudflare Backend: %s\nTarget Backend: %s\n"),
                    info.local_version,
                    info.remote_version,
                    backend_status,
                    expected_backend
                )

                local ButtonDialog = require("ui/widget/buttondialog")
                local TextBoxWidget = require("ui/widget/textboxwidget")
                local Font = require("ui/font")

                local plugin_needs_update = info.has_update and info.download_url ~= nil
                local backend_needs_update = backend_ver ~= "Unknown"
                    and _versionLessThan(backend_ver, expected_backend)

                -- Status lines
                if info.has_update then
                    msg = msg .. "\n" .. _("⬆ Plugin update available!")
                else
                    msg = msg .. "\n" .. _("✓ Plugin is up to date.")
                end

                local added_widgets = {
                    TextBoxWidget:new{
                        text = msg,
                        face = Font:getFace("infofont"),
                        alignment = "left",
                    }
                }

                -- Build button row dynamically — only show action buttons when needed
                local update_dlg
                local btn_row = {}

                if plugin_needs_update then
                    table.insert(btn_row, {
                        text = _("Update Plugin"),
                        callback = function()
                            UIManager:close(update_dlg)
                            self:downloadAndInstall(info.download_url, info.remote_version)
                        end,
                    })
                end

                if backend_needs_update then
                    table.insert(btn_row, {
                        text = _("Update Backend"),
                        callback = function()
                            UIManager:close(update_dlg)
                            self:triggerBackendUpgrade(sink_instance)
                        end,
                    })
                end

                table.insert(btn_row, {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(update_dlg)
                    end,
                })

                update_dlg = ButtonDialog:new{
                    title = _("Sink Updates & Version"),
                    title_align = "center",
                    use_info_style = false,
                    _added_widgets = added_widgets,
                    buttons = { btn_row },
                }
                UIManager:show(update_dlg)
            end)
        end)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Update check error:\n") .. tostring(schedule_err),
            })
        end
    end)
end

function M:triggerBackendUpgrade(sink_instance)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = _("Triggering Cloudflare backend update...") })

    local res, err = sink_instance:_makeRequest("POST", "/syncs/upgrade", {})
    if err or not res then
        UIManager:show(InfoMessage:new{
            text = _("Backend update trigger failed:\n") .. tostring(err or "Network error"),
        })
        return
    end

    if res.status == 200 and res.body and res.body.success then
        UIManager:show(InfoMessage:new{
            text = _("✓ Backend update triggered!\n\nCloudflare is rebuilding your Worker in the background (~30-45 seconds)."),
        })
    else
        local reason = (res.body and (res.body.error or res.body.guide)) or res.raw or "Unknown error"
        UIManager:show(InfoMessage:new{
            text = _("Could not trigger automated rebuild:\n\n") .. tostring(reason) .. "\n\n" .. _("Your GitHub fork also auto-syncs daily via GitHub Actions."),
        })
    end
end

function M:downloadAndInstall(url, new_ver)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = string.format(_("Downloading Sink %s..."), new_ver) })

    UIManager:scheduleIn(0.2, function()
        local ok, err = pcall(function()
            local tmp_zip = "/tmp/sink_update.zip"
            local current_url = url
            local downloaded = false

            for _ = 1, 5 do
                local file, open_err = io.open(tmp_zip, "wb")
                if not file then
                    error(_("Cannot write temporary update file: ") .. tostring(open_err))
                end

                local is_https = current_url:match("^https://") ~= nil
                local request_fn = is_https and https.request or http.request

                local ok_res, code, resp_headers, _ = request_fn{
                    url = current_url,
                    method = "GET",
                    headers = {
                        ["User-Agent"] = "KOReader-Sink-Updater/1.0",
                    },
                    sink = ltn12.sink.file(file),
                    timeout = 30,
                }

                -- Safely close file if ltn12 didn't close it already
                pcall(function() file:close() end)

                local status_num = tonumber(code) or (type(ok_res) == "number" and ok_res) or 0

                if status_num >= 301 and status_num <= 308 and resp_headers then
                    os.remove(tmp_zip)
                    local location = resp_headers.location or resp_headers.Location
                    if not location then
                        error(_("Redirect response missing Location header."))
                    end
                    current_url = location
                elseif status_num == 200 then
                    downloaded = true
                    break
                else
                    os.remove(tmp_zip)
                    error(string.format(_("Download failed (HTTP %s)."), tostring(status_num or "Error")))
                end
            end

            if not downloaded then
                error(_("Too many redirects while downloading update."))
            end

            -- Verify the zip file is non-empty and starts with PK header
            local test_file = io.open(tmp_zip, "rb")
            if not test_file then
                error(_("Downloaded archive could not be opened."))
            end
            local magic = test_file:read(4)
            test_file:close()
            if magic ~= "PK\3\4" then
                os.remove(tmp_zip)
                error(_("Downloaded file is not a valid zip archive."))
            end

            -- Unzip using system unzip
            local target_parent = _plugin_dir:match("(.+)/[^/]+$") or "plugins"
            local cmd = string.format('unzip -o "%s" -d "%s"', tmp_zip, target_parent)
            local ret = os.execute(cmd)
            os.remove(tmp_zip)

            if ret == 0 or ret == true then
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("✓ Sink %s installed successfully!\n\nRestart KOReader now to apply the update?"), new_ver),
                    ok_text = _("Restart"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        if UIManager.restartKOReader then
                            UIManager:restartKOReader()
                        else
                            local Device = require("device")
                            if Device and Device.restartKOReader then
                                Device:restartKOReader()
                            else
                                UIManager:show(InfoMessage:new{ text = _("Please restart KOReader from the top menu.") })
                            end
                        end
                    end,
                })
            else
                error(_("Extraction failed. Please unzip manually."))
            end
        end)

        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(err) })
        end
    end)
end

return M
