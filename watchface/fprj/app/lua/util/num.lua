-- app/util/num.lua
-- Common numeric utilities.

local M = {}

function M.clamp_int(n, minv, maxv, fallback)
    local v = tonumber(n)
    if not v then return fallback end
    v = math.floor(v)
    if v < minv then return minv end
    if v > maxv then return maxv end
    return v
end

return M
