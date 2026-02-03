-- app/core/context.lua
-- Global daemon context. Replaces scattered _G.SU_* variables.

local config = require("su_config")

local ctx = {
    enabled = true,
    save_history = true,
    daemon_period_ms = config.DAEMON_PERIOD_DEFAULT_MS or 300,
    cmd_blacklist = {},
    log_fn = nil,
    log_view = nil,
}

function ctx.update_from_settings(data)
    if type(data) ~= "table" then return end
    ctx.save_history = (data.save_history ~= false)
    ctx.cmd_blacklist = data.cmd_blacklist or {}
    ctx.daemon_period_ms = data.daemon_poll_interval_ms or ctx.daemon_period_ms
end

return ctx
