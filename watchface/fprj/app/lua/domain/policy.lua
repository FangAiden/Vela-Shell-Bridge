-- app/domain/policy.lua
-- Permission policy management (allow/deny/ask/allow_once/allow_until_reboot).

local config = require("su_config")
local store  = require("util.store")

local M = {}

local s = store.new(config.DATA_DIR .. "/policies.json")

-- Ephemeral runtime policies (not persisted).
M.session = {}

local function default_policy()
    return "ask"
end

local function normalize_policy(p)
    if p == "allow" or p == "deny" or p == "ask" or p == "allow_once" or p == "allow_until_reboot" then
        return p
    end
    return nil
end

function M.load()           s.load() end
function M.save_if_dirty()  s.save_if_dirty() end

function M.get_policy(app_id)
    if type(app_id) ~= "string" or app_id == "" then
        return default_policy()
    end
    local sp = normalize_policy(M.session[app_id])
    if sp then return sp end
    local info = s.data[app_id]
    if not info or type(info) ~= "table" then
        return default_policy()
    end
    return normalize_policy(info.policy) or default_policy()
end

function M.set_policy(app_id, policy)
    if type(app_id) ~= "string" or app_id == "" then
        return false, "app_id required"
    end
    local p = normalize_policy(policy)
    if not p then return false, "invalid policy" end

    if p == "allow_once" or p == "allow_until_reboot" then
        M.session[app_id] = p
        return true
    end

    local info = s.data[app_id]
    if not info or type(info) ~= "table" then
        info = {}
        s.data[app_id] = info
    end
    info.policy = p
    s.mark_dirty()
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
        M.session[app_id] = "ask"
        return true, "ALLOW_ONCE"
    else
        return false, "ASK"
    end
end

function M.get_all_policies()
    return s.data
end

--- Clean up session entries for apps no longer in the valid set.
--- Call this periodically with the current allowlist to prevent memory leaks.
function M.gc_session(valid_app_ids)
    if type(valid_app_ids) ~= "table" then return end
    local valid_set = {}
    for _, id in ipairs(valid_app_ids) do
        valid_set[id] = true
    end
    for app_id, _ in pairs(M.session) do
        if not valid_set[app_id] then
            M.session[app_id] = nil
        end
    end
end

return M
