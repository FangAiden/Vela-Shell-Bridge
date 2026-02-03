-- app/util/log.lua
-- Unified logging with context-aware output.

local ctx -- lazy require to avoid circular dependency

local M = {}

function M.create(prefix)
    return function(msg)
        if not ctx then ctx = require("core.context") end
        local fn = ctx.log_fn
        if fn then
            fn("[" .. prefix .. "] " .. tostring(msg))
        else
            print("[" .. prefix .. "]", tostring(msg))
        end
    end
end

return M
