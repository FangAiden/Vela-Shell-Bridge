-- app/domain/exec.lua
-- Shell 执行与 Job 管理（针对目标设备 NuttX `sh` 的能力约束做了适配）
--
-- NuttX sh 能力：
-- - 支持：换行/`;` 分隔、stdout 重定向 `>`/`>>`、后台 `&`、`if/then/else/fi`
-- - 不支持：`|`/`||`/`&&`、fd 重定向 `2>`、`$?` `$$` `$1` `$!`
-- - 注意：`if sh script.sh` 不能正确捕获退出码，需内联命令到 if 条件
--
-- Job 文件（5个）：_wrapper.sh .out .status .pid .owner

local config = require("su_config")
local fs     = require("util.fs_util")
local str    = require("util.str")
local ulog   = require("util.log")

local M = {}

local JOB_DIR = config.TMP_DIR .. "/su_jobs"
local CWD_MAP = {}  -- Per-app working directory
local JOB_REGISTRY = {}  -- Track active jobs for GC: { [job_id] = { created_at, app_id } }
local JOB_MAX_AGE_SEC = 3600  -- GC jobs older than 1 hour
local LAST_GC_TIME = 0
local GC_INTERVAL_SEC = 300  -- Run GC every 5 minutes

local log = ulog.create("exec")

local function ensure_job_dir()
    os.execute("mkdir -p " .. JOB_DIR)
end

----------------------------------------------------------------------
-- Path utilities
----------------------------------------------------------------------

local function normalize_abs_path(p)
    local path = tostring(p or "")
    if path == "" then return "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end

    local out = {}
    for seg in path:gmatch("[^/]+") do
        if seg == "." or seg == "" then
            -- skip
        elseif seg == ".." then
            if #out > 0 then table.remove(out) end
        else
            out[#out + 1] = seg
        end
    end
    return "/" .. table.concat(out, "/")
end

local function resolve_cwd(current, input)
    local rel = str.trim(input)
    if rel == "" then return "/" end
    if rel:sub(1, 1) == "/" then return normalize_abs_path(rel) end

    local base = str.trim(current)
    if base == "" then base = "/" end
    if base:sub(1, 1) ~= "/" then base = "/" .. base end
    if base:sub(-1) ~= "/" then base = base .. "/" end
    return normalize_abs_path(base .. rel)
end

function M.get_cwd(app_id)
    local id = tostring(app_id or "")
    local cwd = CWD_MAP[id]
    return (type(cwd) == "string" and cwd ~= "") and cwd or "/"
end

function M.set_cwd(app_id, cwd)
    local id = tostring(app_id or "")
    if id == "" then return false, "app_id required" end
    local next_cwd = normalize_abs_path(str.trim(cwd))
    CWD_MAP[id] = next_cwd
    return true, next_cwd
end

function M.cd(app_id, raw_path)
    local current = M.get_cwd(app_id)
    local target = resolve_cwd(current, raw_path)
    if fs.is_dir and not fs.is_dir(target) then
        return false, "NO_SUCH_DIR: " .. tostring(target)
    end
    return M.set_cwd(app_id, target)
end

----------------------------------------------------------------------
-- Job file management
----------------------------------------------------------------------

local function gen_job_id()
    return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

local function job_paths(job_id)
    local base = JOB_DIR .. "/job_" .. job_id
    return {
        wrapper = base .. "_wrapper.sh",
        out     = base .. ".out",
        status  = base .. ".status",
        pid     = base .. ".pid",
        owner   = base .. ".owner",
    }
end

function M.get_job_owner(job_id)
    if not job_id or job_id == "" then return nil end
    local paths = job_paths(job_id)
    local owner = str.trim(fs.read_file(paths.owner) or "")
    return owner ~= "" and owner or nil
end

local function normalize_exit_code(ok, why, code)
    -- Lua 5.2+: os.execute() -> (true|nil, "exit"|"signal", code)
    -- NuttX: code is wait() style (exit_code << 8)
    if ok == true then return 0 end

    local n = type(ok) == "number" and ok or (type(code) == "number" and code or nil)
    if n then
        return n > 255 and math.floor(n / 256) or n
    end
    return 1
end

-- Parse PID from /proc/self/status format (Group: xxx)
local function read_pid_file(path)
    local s = fs.read_file(path)
    if not s or s == "" then return nil end
    -- Try parsing "Group: xxx" format first (from /proc/self/status)
    local group = s:match("Group:%s*(%d+)")
    if group then return tonumber(group) end
    -- Fallback to plain number
    return tonumber(s:match("(%d+)"))
end

local function pid_alive(pid)
    if not pid then return false end
    local status = fs.read_file("/proc/" .. tostring(pid) .. "/status")
    return status ~= nil and status ~= ""
end

local function cleanup(paths)
    pcall(function()
        fs.remove_file(paths.wrapper)
        fs.remove_file(paths.out)
        fs.remove_file(paths.status)
        fs.remove_file(paths.pid)
        fs.remove_file(paths.owner)
    end)
end

----------------------------------------------------------------------
-- Job GC: Clean up stale jobs that were never polled to completion
----------------------------------------------------------------------

local function gc_stale_jobs()
    local now = os.time()
    if now - LAST_GC_TIME < GC_INTERVAL_SEC then return end
    LAST_GC_TIME = now

    -- Clean up old entries from JOB_REGISTRY
    local stale_ids = {}
    for job_id, info in pairs(JOB_REGISTRY) do
        if now - (info.created_at or 0) > JOB_MAX_AGE_SEC then
            stale_ids[#stale_ids + 1] = job_id
        end
    end

    for _, job_id in ipairs(stale_ids) do
        local paths = job_paths(job_id)
        log("GC: cleaning stale job " .. job_id)
        cleanup(paths)
        JOB_REGISTRY[job_id] = nil
    end
end

-- Clean up CWD_MAP for apps no longer in allowlist
function M.gc_cwd_map(valid_app_ids)
    if type(valid_app_ids) ~= "table" then return end
    local valid_set = {}
    for _, id in ipairs(valid_app_ids) do
        valid_set[id] = true
    end
    for app_id, _ in pairs(CWD_MAP) do
        if not valid_set[app_id] then
            CWD_MAP[app_id] = nil
        end
    end
end

----------------------------------------------------------------------
-- Start Job
----------------------------------------------------------------------

function M.start_job(shell_cmd, is_sync, app_id)
    if not shell_cmd or shell_cmd == "" then
        return { ok = false, message = "empty shell command" }
    end

    ensure_job_dir()
    gc_stale_jobs()  -- Periodic cleanup of stale jobs

    local job_id = gen_job_id()
    local paths = job_paths(job_id)
    local cwd = M.get_cwd(app_id)

    log("start_job: id=" .. job_id .. " mode=" .. (is_sync and "SYNC" or "ASYNC"))

    -- Register job for GC tracking
    JOB_REGISTRY[job_id] = { created_at = os.time(), app_id = app_id }

    -- Write owner file
    if app_id and app_id ~= "" then
        if not fs.write_file(paths.owner, tostring(app_id) .. "\n") then
            return { ok = false, message = "failed to write owner file" }
        end
    end

    -- A) Sync: execute in foreground, return immediately
    if is_sync then
        local flat_cmd = tostring(shell_cmd):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "; ")
        local full_cmd = "cd " .. str.sh_quote(cwd) .. "; " .. flat_cmd .. " > " .. paths.out
        local ok, why, code = os.execute(full_cmd)
        local exit_code = normalize_exit_code(ok, why, code)
        local output = fs.read_file(paths.out) or ""

        -- Cleanup immediately for sync jobs
        pcall(function()
            fs.remove_file(paths.out)
            fs.remove_file(paths.owner)
        end)

        return {
            ok = true, async = false, job_id = job_id, state = "done",
            result = {
                exit_code = exit_code, status = "exit",
                success = (exit_code == 0), output = output, cwd = cwd,
            }
        }
    end

    -- B) Async: spawn background wrapper script
    -- Use sh -c "cmd" for both streaming output and correct exit code capture
    -- Use /proc/self/status to get real PID (Group field) for kill support
    -- Note: The PID captured is the wrapper shell's PID, which is needed for kill
    -- We also capture the child sh -c PID for more accurate process tracking

    -- Escape single quotes in command for sh -c '...'
    local escaped_cmd = shell_cmd:gsub("'", "'\\''")

    -- Wrapper script captures both its own PID and the child process PID
    local wrapper_content = table.concat({
        "cat /proc/self/status > " .. paths.pid,
        "cd " .. str.sh_quote(cwd),
        "if sh -c '" .. escaped_cmd .. "' >> " .. paths.out,
        "then",
        "  echo 0 > " .. paths.status,
        "else",
        "  echo 1 > " .. paths.status,
        "fi",
    }, "\n")

    if not fs.write_file(paths.wrapper, wrapper_content .. "\n") then
        cleanup(paths)
        JOB_REGISTRY[job_id] = nil
        return { ok = false, message = "failed to write wrapper file" }
    end

    -- Run wrapper in background
    local spawn_cmd = "sh " .. paths.wrapper .. " &"
    local ok_spawn, why_spawn, code_spawn = os.execute(spawn_cmd)
    local spawn_ec = normalize_exit_code(ok_spawn, why_spawn, code_spawn)
    if spawn_ec ~= 0 then
        cleanup(paths)
        JOB_REGISTRY[job_id] = nil
        return { ok = false, message = "failed to spawn background process", exit_code = spawn_ec }
    end

    return {
        ok = true, async = true, job_id = job_id, state = "running",
        result = { cwd = cwd }
    }
end

----------------------------------------------------------------------
-- Kill Job
----------------------------------------------------------------------

function M.kill_job(job_id)
    if not job_id or job_id == "" then
        return { ok = false, message = "job_id required" }
    end

    local paths = job_paths(job_id)

    -- Already done?
    local status_content = fs.read_file(paths.status)
    if status_content and status_content ~= "" then
        return { ok = true, message = "already done" }
    end

    -- Kill the process and write status
    local pid = read_pid_file(paths.pid)
    if pid and pid_alive(pid) then
        log("kill_job: killing pid " .. tostring(pid))
        os.execute("kill -9 " .. tostring(pid))
        fs.write_file(paths.status, "137\n")  -- 128 + 9 (SIGKILL)
        return { ok = true, message = "killed", pid = pid }
    end

    -- Process not started yet or already exited
    fs.write_file(paths.status, "137\n")
    return { ok = true, message = "kill requested" }
end

----------------------------------------------------------------------
-- Poll Job
----------------------------------------------------------------------

function M.poll_job(job_id, app_id)
    if not job_id or job_id == "" then
        return { ok = false, message = "job_id required" }
    end

    local paths = job_paths(job_id)
    local current_output = fs.read_file(paths.out) or ""
    local current_pid = read_pid_file(paths.pid)
    local status_content = fs.read_file(paths.status)

    -- 1) Still running?
    if not status_content or status_content == "" then
        if current_pid and pid_alive(current_pid) then
            return {
                ok = true, async = true, job_id = job_id, state = "running",
                result = { output = current_output, pid = current_pid, cwd = M.get_cwd(app_id) }
            }
        end
        -- Process died without writing status
        fs.write_file(paths.status, "-1\n")
        status_content = "-1"
    end

    -- 2) Done
    local exit_code = tonumber((status_content or ""):match("(%-?%d+)")) or -1
    cleanup(paths)
    JOB_REGISTRY[job_id] = nil  -- Remove from GC registry

    return {
        ok = true, async = true, job_id = job_id, state = "done",
        result = {
            exit_code = exit_code, status = "exit",
            success = (exit_code == 0), output = current_output,
            pid = current_pid, cwd = M.get_cwd(app_id),
        }
    }
end

return M
