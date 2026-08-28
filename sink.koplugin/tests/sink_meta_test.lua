-- Mock gettext if running in standalone test runner
if not _G._ then
    _G._ = function(s) return s end
end

print("--> Running Sink _meta.lua verification test...")

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local meta_path = script_dir .. "../_meta.lua"

local meta_chunk, err = loadfile(meta_path)
if not meta_chunk then
    error("Failed to load _meta.lua: " .. tostring(err))
end

local meta = meta_chunk()
assert(type(meta) == "table", "_meta.lua must return a table")
assert(meta.name == "sink", "Plugin name must be 'sink', got: " .. tostring(meta.name))
assert(type(meta.fullname) == "string" and #meta.fullname > 0, "Plugin fullname must be non-empty string")
assert(type(meta.description) == "string" and #meta.description > 0, "Plugin description must be non-empty string")

print("✓ Sink _meta.lua test PASSED!")
