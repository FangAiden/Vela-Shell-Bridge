local fs     = require("app.util.fs_util")
local config = require("app.config")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/requests_log.json"

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

local function now_ts()
    return os.time()
end

function M.load()
    load_from_disk()
end

function M.save_if_dirty()
    if not M.dirty then return end
    save_to_disk()
end

function M.record_request(app_id)
    if type(app_id) ~= "string" or app_id == "" then
        return
    end

    local info = M.data[app_id]
    if not info or type(info) ~= "table" then
        info = { count = 0, last_ts = 0 }
        M.data[app_id] = info
    end

    info.count   = (info.count or 0) + 1
    info.last_ts = now_ts()
    M.dirty      = true
end

function M.get_logs()
    return M.data
end

function M.clear_logs()
    M.data  = {}
    M.dirty = true
end

return M
