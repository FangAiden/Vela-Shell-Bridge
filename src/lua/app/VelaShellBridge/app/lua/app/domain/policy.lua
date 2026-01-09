local fs     = require("app.util.fs_util")
local config = require("app.config")
local JSON   = require("app.core.json")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/policies.json"

M.data  = {}
M.dirty = false
-- Ephemeral runtime policies (not persisted).
-- Used to avoid I/O amplification for allow_once / allow_until_reboot.
M.session = {}

local function load_from_disk()
    local txt = fs.read_file(DATA_FILE)
    if not txt or txt == "" then
        M.data = {}
        return
    end

    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then
        M.data = {}
        return
    end

    M.data = obj
end

local function save_to_disk()
    local txt = JSON.encode(M.data)
    fs.write_file(DATA_FILE, txt)
    M.dirty = false
end

local function default_policy()
    return "ask"
end

local function normalize_policy(p)
    if p == "allow" or p == "deny" or p == "ask" or p == "allow_once" or p == "allow_until_reboot" then
        return p
    end
    return nil
end

function M.load()
    load_from_disk()
end

function M.save_if_dirty()
    if not M.dirty then return end
    save_to_disk()
end

function M.get_policy(app_id)
    if type(app_id) ~= "string" or app_id == "" then
        return default_policy()
    end

    local sp = normalize_policy(M.session[app_id])
    if sp then
        return sp
    end

    local info = M.data[app_id]
    if not info or type(info) ~= "table" then
        return default_policy()
    end

    local p = normalize_policy(info.policy)
    if not p then
        return default_policy()
    end

    return p
end

function M.set_policy(app_id, policy)
    if type(app_id) ~= "string" or app_id == "" then
        return false, "app_id required"
    end

    local p = normalize_policy(policy)
    if not p then
        return false, "invalid policy"
    end

    -- Session-level policies: do not persist.
    if p == "allow_once" or p == "allow_until_reboot" then
        M.session[app_id] = p
        return true
    end

    local info = M.data[app_id]
    if not info or type(info) ~= "table" then
        info = {}
        M.data[app_id] = info
    end

    info.policy = p
    M.dirty = true
    M.session[app_id] = nil

    return true
end

function M.check_exec_allowed(app_id)
    local p = M.get_policy(app_id)

    if p == "allow" then
        return true, "ALLOW"
    elseif p == "deny" then
        return false, "DENY"
    elseif p == "allow_until_reboot" then
        return true, "ALLOW_SESSION"
    elseif p == "allow_once" then
        -- Consume once without touching disk. If persisted policy is allow_once,
        -- override it in-session to prevent repeated allows.
        M.session[app_id] = "ask"
        return true, "ALLOW_ONCE"
    else
        return false, "ASK"
    end
end

function M.get_all_policies()
    return M.data
end

return M
