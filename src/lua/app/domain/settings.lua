local fs     = require("app.util.fs_util")
local config = require("app.config")
local JSON   = _G.JSON or require("app.util.json_util")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/settings.json"

M.data  = {}
M.dirty = false

local function clamp_int(n, minv, maxv, fallback)
    local v = tonumber(n)
    if not v then return fallback end
    v = math.floor(v)
    if v < minv then return minv end
    if v > maxv then return maxv end
    return v
end

local function default_data()
    return {
        v = 1,
        save_history = true,
        daemon_poll_interval_ms = 300,
        cmd_blacklist = {},
    }
end

local function normalize_list(list)
    local out = {}
    if type(list) ~= "table" then
        return out
    end
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

local function normalize(obj)
    local d = default_data()
    if type(obj) ~= "table" then
        return d
    end

    if type(obj.save_history) == "boolean" then
        d.save_history = obj.save_history
    end

    local ms = obj.daemon_poll_interval_ms
    if ms == nil then
        ms = obj.daemon_poll_ms
    end
    if ms ~= nil then
        d.daemon_poll_interval_ms = clamp_int(ms, 50, 2000, d.daemon_poll_interval_ms)
    end

    local bl = obj.cmd_blacklist
    if bl == nil then
        bl = obj.blacklist
    end
    d.cmd_blacklist = normalize_list(bl)

    return d
end

local function load_from_disk()
    local txt = fs.read_file(DATA_FILE)
    if not txt or txt == "" then
        M.data = default_data()
        return
    end

    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then
        M.data = default_data()
        return
    end

    M.data = normalize(obj)
end

local function save_to_disk()
    local txt = JSON.encode(M.data)
    fs.write_file(DATA_FILE, txt)
    M.dirty = false
end

function M.apply_globals()
    local d = M.data or default_data()
    _G.SU_SAVE_HISTORY = (d.save_history ~= false)
    _G.SU_CMD_BLACKLIST = d.cmd_blacklist or {}
    _G.SU_DAEMON_PERIOD_MS = d.daemon_poll_interval_ms or 300
end

function M.load()
    load_from_disk()
    M.dirty = false
    M.apply_globals()
end

function M.save_if_dirty()
    if not M.dirty then return end
    save_to_disk()
end

function M.get()
    return M.data or default_data()
end

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

        local ms = patch.daemon_poll_interval_ms
        if ms == nil then
            ms = patch.daemon_poll_ms
        end
        if ms ~= nil then
            merged.daemon_poll_interval_ms = clamp_int(ms, 50, 2000, merged.daemon_poll_interval_ms)
        end

        if patch.cmd_blacklist ~= nil or patch.blacklist ~= nil then
            local bl = patch.cmd_blacklist
            if bl == nil then
                bl = patch.blacklist
            end
            merged.cmd_blacklist = normalize_list(bl)
        end
    end

    M.data = normalize(merged)
    M.dirty = true
    M.apply_globals()
    return true, M.data
end

return M

