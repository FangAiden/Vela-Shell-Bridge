-- VelaShellBridge/app/lua/main.lua
-- Real-device (compiled) entrypoint.

local lvgl = require("lvgl")

local ok, app_or_err = pcall(function()
    return require("app.vela_shell_bridge")
end)

if not ok then
    print("[VelaShellBridge] require(app.vela_shell_bridge) failed: " .. tostring(app_or_err))
    return nil
end

local root = (type(app_or_err) == "table" and app_or_err.root) or nil
local time_label = (type(app_or_err) == "table" and app_or_err.time_label) or nil

if time_label and time_label.set then
    lvgl.Timer {
        period = 1000,
        paused = false,
        cb = function()
            local t = os.date("%H:%M:%S")
            time_label:set { text = t }
        end
    }
end

return root
