-- app/core/json.lua
-- Shared JSON loader.

local ok, mod = pcall(require, "app.util.json_util")
if ok and mod then
    return mod
end

if _G.JSON then
    return _G.JSON
end

error("JSON module not found: app.util.json_util.lua is required")
