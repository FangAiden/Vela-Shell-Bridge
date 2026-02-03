-- app/domain/settings.lua
-- Global daemon settings with normalization.

local config = require("su_config")
local store  = require("util.store")
local num    = require("util.num")
local ctx    = require("core.context")

local M = {}

local function normalize_list(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, it in ipairs(list) do
        if type(it) == "string" then
            local s = it:gsub("^%s+", ""):gsub("%s+$", "")
            if s ~= "" and #s <= 80 then
                out[#out + 1] = s
            end
        end
    end
    return out
end

local function default_data()
    return {
        v = 1,
        save_history = true,
        daemon_poll_interval_ms = config.DAEMON_PERIOD_DEFAULT_MS,
        cmd_blacklist = {},
    }
end

local function normalize(obj)
    local d = default_data()
    if type(obj) ~= "table" then return d end

    if type(obj.save_history) == "boolean" then
        d.save_history = obj.save_history
    end

    local ms = obj.daemon_poll_interval_ms or obj.daemon_poll_ms
    if ms ~= nil then
        d.daemon_poll_interval_ms = num.clamp_int(ms,
            config.DAEMON_PERIOD_MIN_MS, config.DAEMON_PERIOD_MAX_MS,
            d.daemon_poll_interval_ms)
    end

    d.cmd_blacklist = normalize_list(obj.cmd_blacklist or obj.blacklist)
    return d
end

local s = store.new(config.DATA_DIR .. "/settings.json", {
    default = default_data,
    normalize = normalize,
})

local function apply_context()
    ctx.update_from_settings(s.data)
end

function M.load()
    s.load()
    s.dirty = false
    apply_context()
end

function M.save_if_dirty()  s.save_if_dirty() end
function M.get()            return s.data or default_data() end

function M.update(patch)
    local current = M.get()
    local merged = {
        v = current.v or 1,
        save_history = current.save_history,
        daemon_poll_interval_ms = current.daemon_poll_interval_ms,
        cmd_blacklist = current.cmd_blacklist,
    }

    if type(patch) == "table" then
        if patch.save_history ~= nil then
            merged.save_history = (patch.save_history == true)
        end
        local ms = patch.daemon_poll_interval_ms or patch.daemon_poll_ms
        if ms ~= nil then
            merged.daemon_poll_interval_ms = num.clamp_int(ms,
                config.DAEMON_PERIOD_MIN_MS, config.DAEMON_PERIOD_MAX_MS,
                merged.daemon_poll_interval_ms)
        end
        if patch.cmd_blacklist ~= nil or patch.blacklist ~= nil then
            merged.cmd_blacklist = normalize_list(patch.cmd_blacklist or patch.blacklist)
        end
    end

    s.data = normalize(merged)
    s.mark_dirty()
    apply_context()
    return true, s.data
end

return M
