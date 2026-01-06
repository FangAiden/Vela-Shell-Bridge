local fs     = require("app.util.fs_util")
local config = require("app.config")
local JSON   = _G.JSON or require("app.util.json_util")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/requests_log.json"
local EXEC_FILE = config.DATA_DIR .. "/exec_logs.json"

local MAX_EXEC_LOGS = 80
local MAX_OUTPUT_LEN = 2048

M.data  = {}
M.dirty = false

M.exec_data  = { v = 1, list = {} }
M.exec_dirty = false
M.job_map    = {}

local function trim_text(s, max_len)
    if type(s) ~= "string" then
        return ""
    end
    if not max_len or max_len <= 0 then
        return s
    end
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len) .. "\n...(truncated)"
end

local function safe_str(v)
    if v == nil then return "" end
    return tostring(v)
end

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

local function load_exec_from_disk()
    local txt = fs.read_file(EXEC_FILE)
    if not txt or txt == "" then
        M.exec_data = { v = 1, list = {} }
        M.job_map = {}
        return
    end

    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then
        M.exec_data = { v = 1, list = {} }
        M.job_map = {}
        return
    end

    local list = nil
    if obj.list and type(obj.list) == "table" then
        list = obj.list
    elseif #obj > 0 then
        -- 兼容旧格式：直接数组
        list = obj
        obj = { v = 1, list = list }
    else
        list = {}
    end

    M.exec_data = { v = tonumber(obj.v) or 1, list = list }
    M.job_map = {}

    for _, it in ipairs(list) do
        if type(it) == "table" and it.state == "running" and it.job_id and it.job_id ~= "" then
            M.job_map[it.job_id] = it
        end
    end
end

local function save_to_disk()
    local txt = JSON.encode(M.data)
    fs.write_file(DATA_FILE, txt)
    M.dirty = false
end

local function save_exec_to_disk()
    local txt = JSON.encode(M.exec_data)
    fs.write_file(EXEC_FILE, txt)
    M.exec_dirty = false
end

local function now_ts()
    return os.time()
end

function M.load()
    load_from_disk()
    load_exec_from_disk()
end

function M.save_if_dirty()
    if not M.dirty then return end
    save_to_disk()
end

function M.save_exec_if_dirty()
    if not M.exec_dirty then return end
    save_exec_to_disk()
end

function M.save_if_any_dirty()
    if M.dirty then
        save_to_disk()
    end
    if M.exec_dirty then
        save_exec_to_disk()
    end
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

local function push_exec_entry(entry)
    if type(entry) ~= "table" then
        return
    end

    local list = M.exec_data.list
    if type(list) ~= "table" then
        list = {}
        M.exec_data.list = list
    end

    table.insert(list, 1, entry)

    while #list > MAX_EXEC_LOGS do
        local removed = table.remove(list)
        if type(removed) == "table" and removed.job_id then
            M.job_map[removed.job_id] = nil
        end
    end

    if entry.job_id and entry.state == "running" then
        M.job_map[entry.job_id] = entry
    end

    M.exec_dirty = true
end

function M.record_exec_start(app_id, shell_cmd, resp)
    local entry = {
        id      = tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999)),
        ts      = now_ts(),
        app_id  = safe_str(app_id),
        cmd     = safe_str(shell_cmd),
        mode    = (resp and resp.async) and "async" or "sync",
        state   = (resp and resp.state) and safe_str(resp.state) or ((resp and resp.async) and "running" or "done"),
        ok      = (resp and resp.ok == true) or false,
        job_id  = (resp and resp.job_id) and safe_str(resp.job_id) or "",
    }

    if not (resp and resp.ok == true) then
        entry.state = (entry.state == "running") and "running" or "error"
    end

    local r = resp and resp.result or nil
    if type(r) == "table" then
        entry.exit_code = r.exit_code
        entry.success   = (r.success == true)
        entry.output    = trim_text(safe_str(r.output), MAX_OUTPUT_LEN)
    end

    if resp and resp.message then
        entry.message = safe_str(resp.message)
    end

    push_exec_entry(entry)
end

function M.record_exec_denied(app_id, shell_cmd, resp)
    local err = resp and resp.error or nil
    local entry = {
        id      = tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999)),
        ts      = now_ts(),
        app_id  = safe_str(app_id),
        cmd     = safe_str(shell_cmd),
        mode    = "sync",
        state   = "denied",
        ok      = false,
        job_id  = "",
        error   = {
            code    = err and err.code or "NO_PERMISSION",
            message = err and err.message or (resp and resp.message) or "denied",
        },
        message = safe_str(resp and resp.message),
    }
    push_exec_entry(entry)
end

function M.record_exec_kill(app_id, job_id, resp)
    local entry = {
        id      = tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999)),
        ts      = now_ts(),
        app_id  = safe_str(app_id),
        cmd     = "kill " .. safe_str(job_id),
        mode    = "sync",
        state   = "kill",
        ok      = (resp and resp.ok == true) or false,
        job_id  = safe_str(job_id),
        message = safe_str(resp and resp.message),
    }
    push_exec_entry(entry)
end

function M.update_exec_job(job_id, resp)
    if not job_id or job_id == "" then
        return
    end

    local entry = M.job_map[job_id]
    if type(entry) ~= "table" then
        return
    end

    if not resp or resp.state ~= "done" then
        return
    end

    entry.state = "done"
    entry.ok = (resp.ok == true)
    local r = resp.result or {}
    entry.exit_code = r.exit_code
    entry.success = (r.success == true)
    entry.output = trim_text(safe_str(r.output), MAX_OUTPUT_LEN)

    M.job_map[job_id] = nil
    M.exec_dirty = true
end

function M.get_exec_logs()
    local list = M.exec_data and M.exec_data.list or {}
    return (type(list) == "table") and list or {}
end

function M.clear_exec_logs()
    M.exec_data = { v = 1, list = {} }
    M.job_map = {}
    M.exec_dirty = true
end

return M
