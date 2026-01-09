-- app/app.lua
-- Bridge layer for emulator hot-reload: delegates to the real-device Lua project
-- under `app/VelaShellBridge/app/lua/app/vela_shell_bridge.lua` while keeping the same external
-- interface (`M.build()` returns `root`, and the module returns `M`).

local function get_this_dir()
    local src = ""
    if debug and debug.getinfo then
        local info = debug.getinfo(1, "S")
        src = (info and info.source) or ""
    end

    if type(src) ~= "string" then
        src = ""
    end

    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end

    src = src:gsub("\\", "/")
    return src:match("^(.*)/[^/]+$") or "."
end

local function ensure_vsb_lua_path()
    if not package or type(package.path) ~= "string" then
        return nil
    end

    local dir = get_this_dir()
    local vsb = dir .. "/VelaShellBridge/app/lua"
    local p1 = vsb .. "/?.lua"
    local p2 = vsb .. "/?/init.lua"

    if not package.path:find(p1, 1, true) then
        package.path = p1 .. ";" .. p2 .. ";" .. package.path
    end

    return vsb
end

-------------------------------------------------
-- Entry: build(api)
-------------------------------------------------
local M = {}

function M.build(api)
    ensure_vsb_lua_path()

    -- Ensure each build runs fresh under hot-reload.
    package.loaded["app.vela_shell_bridge"] = nil

    local ok, app_or_err = pcall(require, "app.vela_shell_bridge")

    if not ok then
        error("VelaShellBridge app.vela_shell_bridge failed: " .. tostring(app_or_err))
    end

    local root = (type(app_or_err) == "table" and app_or_err.root) or nil
    local time_label = (type(app_or_err) == "table" and app_or_err.time_label) or nil

    if api and api.on_tick and time_label and time_label.set then
        api.on_tick(function(epoch)
            local t = os.date("%H:%M:%S", epoch)
            time_label:set { text = t }
        end)
    end

    return root
end

return M
