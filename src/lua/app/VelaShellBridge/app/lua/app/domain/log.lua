local fs     = require("app.util.fs_util")
local config = require("app.config")
local JSON   = require("app.core.json")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/requests_log.json"
local EXEC_JSON_FILE = config.DATA_DIR .. "/exec_logs.json" -- legacy (JSON array / {v,list})
local EXEC_NDJSON_FILE = config.DATA_DIR .. "/exec_logs.ndjson"
local EXEC_NDJSON_BAK = EXEC_NDJSON_FILE .. ".bak"

local MAX_EXEC_LOGS = 80
local MAX_OUTPUT_LEN = 2048
local EXEC_LOG_MAX_BYTES = tonumber(config.EXEC_LOG_MAX_BYTES) or (200 * 1024)
local STATS_FLUSH_MIN_INTERVAL_SEC = tonumber(config.STATS_FLUSH_MIN_INTERVAL_SEC) or 2

M.data  = {}
M.dirty = false

local last_stats_save_ts = 0
local exec_bytes = nil

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

local function trim_ws(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function load_exec_legacy_list()
    local txt = fs.read_file(EXEC_JSON_FILE)
    if not txt or txt == "" then
        return {}
    end

    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then
        return {}
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

    return (type(list) == "table") and list or {}
end

local function save_to_disk()
    local txt = JSON.encode(M.data)
    fs.write_file(DATA_FILE, txt)
    M.dirty = false
end

local function file_size(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local ok, sz = pcall(function()
        local s = f:seek("end")
        return tonumber(s) or 0
    end)
    f:close()
    if ok then return sz end
    return 0
end

local function init_exec_bytes()
    if exec_bytes ~= nil then return end
    exec_bytes = file_size(EXEC_NDJSON_FILE)
end

local function rotate_exec_logs_if_needed(extra_bytes)
    init_exec_bytes()
    extra_bytes = tonumber(extra_bytes) or 0
    if exec_bytes + extra_bytes <= EXEC_LOG_MAX_BYTES then
        return
    end

    pcall(function()
        fs.remove_file(EXEC_NDJSON_BAK)
    end)
    pcall(function()
        os.rename(EXEC_NDJSON_FILE, EXEC_NDJSON_BAK)
    end)
    fs.write_file(EXEC_NDJSON_FILE, "")
    exec_bytes = 0
end

local function append_exec_entry(entry)
    if type(entry) ~= "table" then
        return
    end

    local ok, line = pcall(function()
        return JSON.encode(entry) .. "\n"
    end)
    if not ok or type(line) ~= "string" then
        return
    end

    rotate_exec_logs_if_needed(#line)

    if fs.append_file then
        local ok2 = fs.append_file(EXEC_NDJSON_FILE, line)
        if ok2 then
            exec_bytes = (exec_bytes or 0) + #line
        end
        return
    end

    -- Fallback (slow): rewrite whole file if append is unavailable.
    local old = fs.read_file(EXEC_NDJSON_FILE) or ""
    fs.write_file(EXEC_NDJSON_FILE, old .. line)
    exec_bytes = file_size(EXEC_NDJSON_FILE)
end

local function merge_exec_entry(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end

    for k, v in pairs(src) do
        if v ~= nil then
            if k == "ts" then
                if dst.ts == nil then
                    dst.ts = v
                end
            elseif k == "cmd" then
                if dst.cmd == nil or dst.cmd == "" then
                    dst.cmd = v
                end
            else
                dst[k] = v
            end
        end
    end
end

local function read_ndjson_merge(path, merged)
    local f = io.open(path, "r")
    if not f then return end

    for line in f:lines() do
        local ln = trim_ws(line)
        if ln ~= "" then
            local ok, obj = pcall(JSON.decode, ln)
            if ok and type(obj) == "table" then
                local id = obj.id or obj.job_id or ""
                id = safe_str(id)
                if id ~= "" then
                    obj.id = id
                    if obj.job_id ~= nil then
                        obj.job_id = safe_str(obj.job_id)
                    end
                    local cur = merged[id]
                    if cur then
                        merge_exec_entry(cur, obj)
                    else
                        merged[id] = obj
                    end
                end
            end
        end
    end

    f:close()
end

local function now_ts()
    return os.time()
end

function M.load()
    load_from_disk()
end

function M.save_if_dirty()
    if not M.dirty then return end
    local now = now_ts()
    if now - (last_stats_save_ts or 0) < STATS_FLUSH_MIN_INTERVAL_SEC then
        return
    end
    save_to_disk()
    last_stats_save_ts = now
end

function M.save_exec_if_dirty()
    -- exec logs are append-only; no-op kept for backward compatibility
end

function M.save_if_any_dirty()
    M.save_if_dirty()
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
    last_stats_save_ts = 0
    save_to_disk()
end

local function push_exec_entry(entry)
    append_exec_entry(entry)
end

function M.record_exec_start(app_id, shell_cmd, resp)
    local job_id = (resp and resp.job_id) and safe_str(resp.job_id) or ""
    local entry = {
        id      = (job_id ~= "") and job_id or (tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999))),
        ts      = now_ts(),
        app_id  = safe_str(app_id),
        cmd     = safe_str(shell_cmd),
        mode    = (resp and resp.async) and "async" or "sync",
        state   = (resp and resp.state) and safe_str(resp.state) or ((resp and resp.async) and "running" or "done"),
        ok      = (resp and resp.ok == true) or false,
        job_id  = job_id,
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

    if not resp or resp.state ~= "done" then
        return
    end

    local r = resp.result or {}
    local entry = {
        id        = safe_str(job_id),
        job_id    = safe_str(job_id),
        ts        = now_ts(),
        state     = "done",
        ok        = (resp.ok == true),
        exit_code = r.exit_code,
        success   = (r.success == true),
        output    = trim_text(safe_str(r.output), MAX_OUTPUT_LEN),
    }
    append_exec_entry(entry)
end

function M.get_exec_logs()
    if not (fs.file_exists and fs.file_exists(EXEC_NDJSON_FILE)) then
        local legacy = load_exec_legacy_list()
        local out = {}
        for i = 1, math.min(#legacy, MAX_EXEC_LOGS) do
            out[i] = legacy[i]
        end
        return out
    end

    local merged = {}
    read_ndjson_merge(EXEC_NDJSON_BAK, merged)
    read_ndjson_merge(EXEC_NDJSON_FILE, merged)

    local arr = {}
    for _, it in pairs(merged) do
        if type(it) == "table" then
            arr[#arr + 1] = it
        end
    end

    table.sort(arr, function(a, b)
        local ta = tonumber(a.ts) or 0
        local tb = tonumber(b.ts) or 0
        if ta ~= tb then
            return ta > tb
        end
        return safe_str(a.id) > safe_str(b.id)
    end)

    local out = {}
    local n = math.min(#arr, MAX_EXEC_LOGS)
    for i = 1, n do
        out[i] = arr[i]
    end
    return out
end

function M.clear_exec_logs()
    pcall(function()
        fs.remove_file(EXEC_NDJSON_FILE)
    end)
    pcall(function()
        fs.remove_file(EXEC_NDJSON_BAK)
    end)
    pcall(function()
        fs.remove_file(EXEC_JSON_FILE)
    end)
    exec_bytes = 0
end

return M
