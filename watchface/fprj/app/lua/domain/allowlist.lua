-- app/domain/allowlist.lua
-- Persist and manage allowlisted apps.

local config = require("su_config")
local store  = require("util.store")

local M = {}

local s = store.new(config.DATA_DIR .. "/allowlist.json")

function M.load()           s.load() end
function M.save_if_dirty()  s.save_if_dirty() end
function M.get_all()        return s.data end

function M.is_allowed(app_id)
    return s.data[app_id] == true
end

function M.add(app_id)
    if type(app_id) ~= "string" or app_id == "" then return end
    if not s.data[app_id] then
        s.data[app_id] = true
        s.mark_dirty()
    end
end

function M.remove(app_id)
    if s.data[app_id] then
        s.data[app_id] = nil
        s.mark_dirty()
    end
end

function M.set_list(list)
    s.data = {}
    if type(list) == "table" then
        for _, app_id in ipairs(list) do
            if type(app_id) == "string" and app_id ~= "" then
                s.data[app_id] = true
            end
        end
    end
    s.mark_dirty()
end

return M
