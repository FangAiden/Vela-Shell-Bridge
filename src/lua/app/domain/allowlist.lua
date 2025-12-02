local fs     = require("app.util.fs_util")
local config = require("app.config")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/allowlist.json"

M.data  = {}
M.dirty = false

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

function M.load()
    load_from_disk()
end

function M.save_if_dirty()
    if not M.dirty then return end
    save_to_disk()
end

-- list: {"AppB","AppC",...}
function M.set_list(list)
    M.data = {}
    if type(list) == "table" then
        for _, app_id in ipairs(list) do
            if type(app_id) == "string" and app_id ~= "" then
                M.data[app_id] = true
            end
        end
    end
    M.dirty = true
end

function M.get_all()
    return M.data
end

function M.is_allowed(app_id)
    return M.data[app_id] == true
end

function M.add(app_id)
    if type(app_id) ~= "string" or app_id == "" then return end
    if not M.data[app_id] then
        M.data[app_id] = true
        M.dirty = true
    end
end

function M.remove(app_id)
    if M.data[app_id] then
        M.data[app_id] = nil
        M.dirty = true
    end
end

return M
