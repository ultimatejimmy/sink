-- Localization Manager for Sink Plugin
local logger = require("logger")
local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok or type(lfs) ~= "table" then
    ok, lfs = pcall(require, "lfs")
end

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
if plugin_path ~= "" then
    local path_to_dir = plugin_path:gsub("%.", "/")
    if not package.path:find(path_to_dir) then
        package.path = package.path .. ";" .. path_to_dir .. "?.lua"
    end
end

local Localization = {
    current_language = "en",
    translations = {},
    available_languages = {},
}

-- Simple .po parser
function Localization:parsePO(filepath)
    local translations = {}
    local file = io.open(filepath, "r")
    if not file then return nil end

    local msgid = nil
    local msgstr = nil
    local in_msgid = false
    local in_msgstr = false

    for line in file:lines() do
        if not (line:match("^#") or line:match("^%s*$")) then
            if line:match('^msgid%s+"') then
                if msgid and msgstr then
                    translations[msgid] = msgstr
                end
                msgid = line:match('^msgid%s+"(.-)"')
                msgstr = nil
                in_msgid = true
                in_msgstr = false
            elseif line:match('^msgstr%s+"') then
                msgstr = line:match('^msgstr%s+"(.-)"')
                in_msgid = false
                in_msgstr = true
            elseif line:match('^"') then
                local continuation = line:match('^"(.-)"')
                if in_msgid and msgid then
                    msgid = msgid .. continuation
                elseif in_msgstr and msgstr then
                    msgstr = msgstr .. continuation
                end
            end
        end
    end

    if msgid and msgstr then
        translations[msgid] = msgstr
    end
    file:close()

    for key, value in pairs(translations) do
        value = value:gsub("\\n", "\n")
        value = value:gsub("\\t", "\t")
        value = value:gsub('\\"', '"')
        value = value:gsub("\\\\", "\\")
        translations[key] = value
    end

    return translations
end

function Localization:init(path)
    self.path = path or (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+$") or "plugins/sink.koplugin"
    self.path = self.path:gsub("\\", "/")
    self:discoverLanguages()
    self:loadLanguage()
    self:loadTranslations()
end

function Localization:discoverLanguages()
    local lang_dir = self.path .. "/languages"
    self.available_languages = {}
    if not lfs then return end
    local attr = lfs.attributes(lang_dir)
    if not attr or attr.mode ~= "directory" then return end

    for file in lfs.dir(lang_dir) do
        if file:match("%.po$") then
            local lang_code = file:match("^(.+)%.po$")
            if lang_code then
                table.insert(self.available_languages, lang_code)
            end
        end
    end
    table.sort(self.available_languages)
end

function Localization:loadLanguage()
    if _G.G_reader_settings then
        local lang = G_reader_settings:readSetting("language")
        if lang and lang ~= "" then
            -- Handle formats like de_DE, es_ES, pt_BR, zh_CN
            local simplified = lang:gsub("-", "_")
            if self:hasLanguage(simplified) then
                self.current_language = simplified
                return
            end
            local prefix = lang:match("^(%a+)")
            if prefix and self:hasLanguage(prefix) then
                self.current_language = prefix
                return
            end
        end
    end
    self.current_language = "en"
end

function Localization:hasLanguage(lang)
    for _, l in ipairs(self.available_languages) do
        if l == lang then return true end
    end
    return false
end

function Localization:loadTranslations()
    local po_file = self.path .. "/languages/" .. self.current_language .. ".po"
    local translations = self:parsePO(po_file)
    if translations then
        self.translations = translations
    elseif self.current_language ~= "en" then
        po_file = self.path .. "/languages/en.po"
        self.translations = self:parsePO(po_file) or {}
    else
        self.translations = {}
    end
end

function Localization:t(key, ...)
    local text = self.translations[key]
    if not text or text == "" then
        text = key
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
    end
    return text
end

return Localization
