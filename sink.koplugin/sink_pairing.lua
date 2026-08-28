local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local json = require("json")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local _ = require("gettext")
local logger = require("logger")

local SinkPairing = {
    dialog = nil,
    session_id = nil,
    poll_timer = nil,
    is_pairing = false,
}

local function cleanUrl(url)
    if not url then return "" end
    url = url:match("^%s*(.-)%s*$")
    if url:sub(-1) == "/" then
        url = url:sub(1, -2)
    end
    return url
end

local function httpRequest(url, method, headers, request_body, timeout)
    timeout = timeout or 10
    local is_https = url:match("^https://") ~= nil
    local request_fn = is_https and https.request or http.request

    local response_body = {}
    local req_headers = headers or {}
    if request_body and #request_body > 0 then
        req_headers["Content-Length"] = tostring(#request_body)
    end

    local ok, code, resp_headers = pcall(function()
        return request_fn{
            url = url,
            method = method or "GET",
            headers = req_headers,
            source = request_body and ltn12.source.string(request_body) or nil,
            sink = ltn12.sink.table(response_body),
            timeout = timeout,
        }
    end)

    if not ok then
        return false, nil, tostring(code)
    end

    return true, tonumber(code) or code, table.concat(response_body)
end

function SinkPairing:stop()
    self.is_pairing = false
    if self.poll_timer then
        UIManager:unschedule(self.poll_timer)
        self.poll_timer = nil
    end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

function SinkPairing:startPairing(sink_plugin, on_complete)
    self:stop()

    NetworkMgr:runWhenOnline(function()
        local server_url = cleanUrl(sink_plugin.settings.server_url)
        if not server_url or server_url == "" then
            UIManager:show(InfoMessage:new{
                text = _("Please configure your Server URL in settings first."),
            })
            return
        end

        UIManager:show(Notification:new{ text = _("Connecting to Sink server...") })

        -- 1. Request new pairing session from Worker
        local create_url = server_url .. "/api/session/create"
        local ok, code, resp_text = httpRequest(create_url, "POST", { ["Content-Type"] = "application/json" }, "{}", 8)

        if not ok or code ~= 200 or not resp_text then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Could not reach Sink server (%s).\nPlease verify Server URL and Wi-Fi connection."), tostring(code or "Network error")),
            })
            return
        end

        local sess_data = nil
        pcall(function() sess_data = json.decode(resp_text) end)
        if not sess_data or not sess_data.session_id then
            UIManager:show(InfoMessage:new{
                text = _("Invalid response from Sink server."),
            })
            return
        end

        self.session_id = sess_data.session_id
        self.is_pairing = true

        -- Format code with spaces for crystal clarity on e-ink (e.g. "K 9 X   2 P 4")
        local raw_code = self.session_id
        local formatted_code = string.format("%s %s %s   %s %s %s",
            raw_code:sub(1,1), raw_code:sub(2,2), raw_code:sub(3,3),
            raw_code:sub(4,4), raw_code:sub(5,5), raw_code:sub(6,6)
        )

        local web_url = server_url .. "/?s=" .. raw_code

        -- 2. Show Pairing Dialog on E-Reader Screen
        local dialog_text = string.format(
            _("PAIR YOUR DEVICE\n\n1. On your Phone or PC, open:\n%s\n\n2. Enter Code:\n%s\n\n(Waiting for confirmation...)"),
            server_url,
            formatted_code
        )

        self.dialog = ButtonDialog:new{
            title = _("Sink Device Pairing"),
            text = dialog_text,
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "cancel",
                        callback = function()
                            self:stop()
                        end,
                    },
                },
            },
        }
        UIManager:show(self.dialog)

        -- 3. Poll for pairing confirmation
        local poll_fn
        local poll_count = 0
        local max_polls = 150 -- 5 minutes max

        poll_fn = function()
            if not self.is_pairing then return end
            poll_count = poll_count + 1

            if poll_count > max_polls then
                self:stop()
                UIManager:show(InfoMessage:new{
                    text = _("Pairing session timed out. Please try again."),
                })
                return
            end

            local poll_url = server_url .. "/api/session/" .. raw_code .. "/poll"
            local poll_ok, poll_code, poll_resp = httpRequest(poll_url, "GET", {}, nil, 5)

            if poll_ok and poll_code == 200 and poll_resp and #poll_resp > 0 then
                local data = nil
                pcall(function() data = json.decode(poll_resp) end)

                if data and data.status == "ready" and data.username and data.userkey then
                    -- Success! Apply credentials
                    self:stop()
                    sink_plugin.settings.username = data.username
                    sink_plugin.settings.userkey = data.userkey
                    sink_plugin:saveSettings()

                    UIManager:show(InfoMessage:new{
                        text = string.format(_("✓ E-Reader Paired Successfully!\n\nConnected as: %s\nReading progress will now sync automatically."), data.username),
                        timeout = 6,
                    })

                    if on_complete then
                        pcall(on_complete)
                    end
                    return
                end
            end

            -- Schedule next poll in 2 seconds
            if self.is_pairing then
                self.poll_timer = function() poll_fn() end
                UIManager:scheduleIn(2, self.poll_timer)
            end
        end

        -- Start initial poll after 2 seconds
        self.poll_timer = function() poll_fn() end
        UIManager:scheduleIn(2, self.poll_timer)
    end)
end

return SinkPairing
