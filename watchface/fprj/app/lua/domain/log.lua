-- app/domain/log.lua
-- Log execution history (stats + append-only NDJSON exec logs).

local fs     = require("util.fs_util")
local config = require("su_config")
local JSON   = require("core.json")
local store  = require("util.store")
local str    = require("util.str")

local M = {}

local DATA_FILE = config.DATA_DIR .. "/requests_log.json"
local EXEC_NDJSON_FILE = config.DATA_DIR .. "/exec_logs.ndjson"
local EXEC_NDJSON_BAK = EXEC_NDJSON_FILE .. ".bak"

local MAX_EXEC_LOGS = config.MAX_EXEC_LOGS or 80
local MAX_OUTPUT_LEN = config.MAX_OUTPUT_LEN or 2048
local EXEC_LOG_MAX_BYTES = tonumber(config.EXEC_LOG_MAX_BYTES) or (200 * 1024)
local STATS_FLUSH_MIN_INTERVAL_SEC = tonumber(config.STATS_FLUSH_MIN_INTERVAL_SEC) or 2

-- Stats store (requests_log.json)
local stats = store.new(DATA_FILE)
local last_stats_save_ts = 0
local exec_bytes = nil

local function file_size(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local ok, sz = pcall(function()
        local s = f:seek("end")
        return tonumber(s) or 0
    end)
    f:close()
    return ok and sz or 0
end

local function init_exec_bytes()
    -- Always recalculate from actual file size to ensure accuracy after restarts
    exec_bytes = file_size(EXEC_NDJSON_FILE)
end

local function rotate_exec_logs_if_needed(extra_bytes)
    init_exec_bytes()
    extra_bytes = tonumber(extra_bytes) or 0
    if exec_bytes + extra_bytes <= EXEC_LOG_MAX_BYTES then return end

    -- Safer rotation: rename current to .bak (overwrites existing .bak atomically)
    -- This avoids the gap where both files could be lost
    local ok_rename = os.rename(EXEC_NDJSON_FILE, EXEC_NDJSON_BAK)
    if not ok_rename then
        -- If rename fails, try remove first then rename
        pcall(function() fs.remove_file(EXEC_NDJSON_BAK) end)
        pcall(function() os.rename(EXEC_NDJSON_FILE, EXEC_NDJSON_BAK) end)
    end

    -- Create empty new file
    fs.write_file(EXEC_NDJSON_FILE, "")
    exec_bytes = 0
end

local function append_exec_entry(entry)
    if type(entry) ~= "table" then return end
    local ok, line = pcall(function() return JSON.encode(entry) .. "\n" end)
    if not ok or type(line) ~= "string" then return end

    rotate_exec_logs_if_needed(#line)

    if fs.append_file then
        local ok2 = fs.append_file(EXEC_NDJSON_FILE, line)
        if ok2 then exec_bytes = (exec_bytes or 0) + #line end
        return
    end
    local old = fs.read_file(EXEC_NDJSON_FILE) or ""
    fs.write_file(EXEC_NDJSON_FILE, old .. line)
    exec_bytes = file_size(EXEC_NDJSON_FILE)
end

local function merge_exec_entry(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        if v ~= nil then
            if k == "ts" then
                if dst.ts == nil then dst.ts = v end
            elseif k == "cmd" then
                if dst.cmd == nil or dst.cmd == "" then dst.cmd = v end
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
        local ln = str.trim(line)
        if ln ~= "" then
            local ok, obj = pcall(JSON.decode, ln)
            if ok and type(obj) == "table" then
                local id = str.safe_str(obj.id or obj.job_id or "")
                if id ~= "" then
                    obj.id = id
                    if obj.job_id ~= nil then obj.job_id = str.safe_str(obj.job_id) end
                    local cur = merged[id]
                    if cur then merge_exec_entry(cur, obj)
                    else merged[id] = obj end
                end
            end
        end
    end
    f:close()
end

local function now_ts() return os.time() end

function M.load()  stats.load() end

function M.save_if_dirty()
    if not stats.dirty then return end
    local now = now_ts()
    if now - (last_stats_save_ts or 0) < STATS_FLUSH_MIN_INTERVAL_SEC then return end
    stats.save()
    last_stats_save_ts = now
end

function M.record_request(app_id)
    if type(app_id) ~= "string" or app_id == "" then return end
    local info = stats.data[app_id]
    if not info or type(info) ~= "table" then
        info = { count = 0, last_ts = 0 }
        stats.data[app_id] = info
    end
    info.count   = (info.count or 0) + 1
    info.last_ts = now_ts()
    stats.mark_dirty()
end

function M.get_logs()       return stats.data end

function M.clear_logs()
    stats.data = {}
    stats.mark_dirty()
    last_stats_save_ts = 0
    stats.save()
end

function M.record_exec_start(app_id, shell_cmd, resp)
    local job_id = (resp and resp.job_id) and str.safe_str(resp.job_id) or ""
    local entry = {
        id      = (job_id ~= "") and job_id or (tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999))),
        ts      = now_ts(),
        app_id  = str.safe_str(app_id),
        cmd     = str.safe_str(shell_cmd),
        mode    = (resp and resp.async) and "async" or "sync",
        state   = (resp and resp.state) and str.safe_str(resp.state) or ((resp and resp.async) and "running" or "done"),
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
        entry.output    = str.trim_text(str.safe_str(r.output), MAX_OUTPUT_LEN)
    end
    if resp and resp.message then
        entry.message = str.safe_str(resp.message)
    end
    append_exec_entry(entry)
end

function M.record_exec_denied(app_id, shell_cmd, resp)
    local err = resp and resp.error or nil
    append_exec_entry({
        id      = tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999)),
        ts      = now_ts(),
        app_id  = str.safe_str(app_id),
        cmd     = str.safe_str(shell_cmd),
        mode    = "sync",
        state   = "denied",
        ok      = false,
        job_id  = "",
        error   = {
            code    = err and err.code or "NO_PERMISSION",
            message = err and err.message or (resp and resp.message) or "denied",
        },
        message = str.safe_str(resp and resp.message),
    })
end

function M.record_exec_kill(app_id, job_id, resp)
    append_exec_entry({
        id      = tostring(now_ts()) .. "_" .. tostring(math.random(1000, 9999)),
        ts      = now_ts(),
        app_id  = str.safe_str(app_id),
        cmd     = "kill " .. str.safe_str(job_id),
        mode    = "sync",
        state   = "kill",
        ok      = (resp and resp.ok == true) or false,
        job_id  = str.safe_str(job_id),
        message = str.safe_str(resp and resp.message),
    })
end

function M.update_exec_job(job_id, resp)
    if not job_id or job_id == "" then return end
    if not resp or resp.state ~= "done" then return end
    local r = resp.result or {}
    append_exec_entry({
        id        = str.safe_str(job_id),
        job_id    = str.safe_str(job_id),
        ts        = now_ts(),
        state     = "done",
        ok        = (resp.ok == true),
        exit_code = r.exit_code,
        success   = (r.success == true),
        output    = str.trim_text(str.safe_str(r.output), MAX_OUTPUT_LEN),
    })
end

function M.get_exec_logs()
    local merged = {}
    read_ndjson_merge(EXEC_NDJSON_BAK, merged)
    read_ndjson_merge(EXEC_NDJSON_FILE, merged)

    local arr = {}
    for _, it in pairs(merged) do
        if type(it) == "table" then arr[#arr + 1] = it end
    end
    table.sort(arr, function(a, b)
        local ta = tonumber(a.ts) or 0
        local tb = tonumber(b.ts) or 0
        if ta ~= tb then return ta > tb end
        return str.safe_str(a.id) > str.safe_str(b.id)
    end)

    local out = {}
    local n = math.min(#arr, MAX_EXEC_LOGS)
    for i = 1, n do out[i] = arr[i] end
    return out
end

function M.clear_exec_logs()
    pcall(function() fs.remove_file(EXEC_NDJSON_FILE) end)
    pcall(function() fs.remove_file(EXEC_NDJSON_BAK) end)
    exec_bytes = 0
end

return M
