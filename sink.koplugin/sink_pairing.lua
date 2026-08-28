local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")
local Font = require("ui/font")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
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
    poll_count = 0,
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
    timeout = timeout or 8
    local is_https = url:match("^https://") ~= nil
    local request_fn = is_https and https.request or http.request

    local response_body = {}
    local req_headers = headers or {}
    if request_body and #request_body > 0 then
        req_headers["Content-Length"] = tostring(#request_body)
    end
    if not req_headers["User-Agent"] then
        req_headers["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-Sink/1.0)"
    end

    local req_table = {
        url = url,
        method = method or "GET",
        headers = req_headers,
        source = request_body and ltn12.source.string(request_body) or nil,
        sink = ltn12.sink.table(response_body),
        timeout = timeout,
    }

    local ok, code, resp_headers, status
    local pcall_ok, pcall_err = pcall(function()
        ok, code, resp_headers, status = request_fn(req_table)
    end)

    if not pcall_ok then
        return false, nil, tostring(pcall_err)
    end

    local resp_text = table.concat(response_body)
    return ok ~= nil, tonumber(code) or code, resp_text
end

function SinkPairing:stop()
    self.is_pairing = false
    self.session_id = nil
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

        local session_id = sess_data.session_id
        self.session_id = session_id
        self.is_pairing = true
        self.poll_count = 0

        -- Format code with spaces for crystal clarity on e-ink (e.g. "K 9 X   2 P 4")
        local raw_code = session_id
        local formatted_code = string.format("%s %s %s   %s %s %s",
            raw_code:sub(1,1), raw_code:sub(2,2), raw_code:sub(3,3),
            raw_code:sub(4,4), raw_code:sub(5,5), raw_code:sub(6,6)
        )

        -- 2. Build Clean E-Ink UI Card using ButtonDialog + VerticalGroup
        local dialog_width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
        local base_fs = 20
        pcall(function()
            if Size and Size.font and Size.font.default then base_fs = Size.font.default end
        end)

        local vg_components = {
            VerticalSpan:new{ width = Size.span.horizontal_large or 15 },
            CenterContainer:new{
                dimen = { w = dialog_width, h = 30 },
                TextWidget:new{
                    text = _("PAIR YOUR DEVICE"),
                    face = Font:getFace("cfont", math.floor(base_fs * 1.1)),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = Size.span.horizontal_medium or 10 },
            TextWidget:new{
                text = _("1. On Phone or PC, open:"),
                face = Font:getFace("cfont", base_fs),
                padding = 5,
            },
            TextWidget:new{
                text = server_url,
                face = Font:getFace("cfont", math.floor(base_fs * 0.95)),
                bold = true,
                padding = 5,
            },
            VerticalSpan:new{ width = Size.span.horizontal_medium or 10 },
            TextWidget:new{
                text = _("2. Enter Code:"),
                face = Font:getFace("cfont", base_fs),
                padding = 5,
            },
            CenterContainer:new{
                dimen = { w = dialog_width, h = 45 },
                TextWidget:new{
                    text = "[ " .. formatted_code .. " ]",
                    face = Font:getFace("cfont", math.floor(base_fs * 1.4)),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = Size.span.horizontal_medium or 10 },
            CenterContainer:new{
                dimen = { w = dialog_width, h = 25 },
                TextWidget:new{
                    text = _("(Waiting for confirmation...)"),
                    face = Font:getFace("cfont", math.floor(base_fs * 0.85)),
                },
            },
            VerticalSpan:new{ width = Size.span.horizontal_large or 15 },
        }

        local vg = VerticalGroup:new(vg_components)

        self.dialog = ButtonDialog:new{
            _added_widgets = { vg },
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        is_enter_default = true,
                        callback = function()
                            self:stop()
                        end,
                    },
                },
            },
        }
        UIManager:show(self.dialog)

        -- 3. Start Polling Loop
        self:pollSession(server_url, session_id, sink_plugin, on_complete)
    end)
end

function SinkPairing:pollSession(server_url, session_id, sink_plugin, on_complete)
    if not self.is_pairing or self.session_id ~= session_id then return end

    self.poll_count = (self.poll_count or 0) + 1
    if self.poll_count > 150 then -- 5 minutes max
        self:stop()
        UIManager:show(InfoMessage:new{
            text = _("Pairing session timed out. Please try again."),
        })
        return
    end

    local poll_url = server_url .. "/api/session/" .. session_id .. "/poll"
    local poll_ok, poll_code, poll_resp = httpRequest(poll_url, "GET", {}, nil, 4)

    if not self.is_pairing or self.session_id ~= session_id then return end

    if poll_ok and poll_code == 200 and poll_resp and #poll_resp > 0 then
        local data = nil
        pcall(function() data = json.decode(poll_resp) end)

        if data and data.status == "ready" and data.username and data.userkey then
            -- Success! Apply credentials immediately
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

    -- Reschedule next poll asynchronously after 1.5 seconds
    if self.is_pairing and self.session_id == session_id then
        self.poll_timer = function()
            self:pollSession(server_url, session_id, sink_plugin, on_complete)
        end
        UIManager:scheduleIn(1.5, self.poll_timer)
    end
end

return SinkPairing
