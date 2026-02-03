-- app/domain/exec.lua
-- Shell 执行与 Job 管理（针对目标设备 NuttX `sh` 的能力约束做了适配）
--
-- 已在 `adb -s emulator-5554 shell` 验证：
-- - 支持：换行/`;` 分隔、stdout 重定向 `>`/`>>`、后台 `&`（命令行尾）、`$!`、`if/then/else/fi`
-- - 不支持：`|`/`||`/`&&`、fd 重定向 `2>`、常见变量 `$?` `$$` `$1`...
-- - 重要：脚本中命令失败会中断后续执行（除非放进 `if <cmd>` 结构）
--
-- 设计：异步任务用「后台 wrapper 进程」来运行命令本身（避免再套一层后台进程 + wait），
--       并且用 `if sh <script> > <out>` 确保无论成功/失败都会写出 status 文件。

local config = require("su_config")
local fs     = require("util.fs_util")
local str    = require("util.str")
local ulog   = require("util.log")

local M = {}

local JOB_DIR = config.TMP_DIR .. "/su_jobs"

-- Per-app "shell context": persist working directory between exec calls.
local CWD_MAP = {}

local log = ulog.create("exec")

local function ensure_job_dir()
    os.execute("mkdir -p " .. JOB_DIR)
end

local function normalize_abs_path(p)
    local path = tostring(p or "")
    if path == "" then
        return "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    local out = {}
    for seg in path:gmatch("[^/]+") do
        if seg == "." or seg == "" then
            -- skip
        elseif seg == ".." then
            if #out > 0 then
                table.remove(out)
            end
        else
            out[#out + 1] = seg
        end
    end

    return "/" .. table.concat(out, "/")
end

local function resolve_cwd(current, input)
    local rel = str.trim(input)
    if rel == "" then
        return "/"
    end
    if rel:sub(1, 1) == "/" then
        return normalize_abs_path(rel)
    end

    local base = str.trim(current)
    if base == "" then
        base = "/"
    end
    if base:sub(1, 1) ~= "/" then
        base = "/" .. base
    end
    if base:sub(-1) ~= "/" then
        base = base .. "/"
    end

    return normalize_abs_path(base .. rel)
end

function M.get_cwd(app_id)
    local id = tostring(app_id or "")
    local cwd = CWD_MAP[id]
    if type(cwd) ~= "string" or cwd == "" then
        return "/"
    end
    return cwd
end

function M.set_cwd(app_id, cwd)
    local id = tostring(app_id or "")
    if id == "" then
        return false, "app_id required"
    end
    local next = normalize_abs_path(str.trim(cwd))
    CWD_MAP[id] = next
    return true, next
end

function M.cd(app_id, raw_path)
    local current = M.get_cwd(app_id)
    local target = resolve_cwd(current, raw_path)
    if fs.is_dir and not fs.is_dir(target) then
        return false, "NO_SUCH_DIR: " .. tostring(target)
    end
    return M.set_cwd(app_id, target)
end

local function gen_job_id()
    return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

local function job_paths(job_id)
    local base = JOB_DIR .. "/job_" .. job_id
    return {
        base    = base,
        out     = base .. ".out",
        status  = base .. ".status",
        pid     = base .. ".pid",
        wrapper_pid = base .. ".wrapper.pid",
        killed  = base .. ".killed",
        script  = base .. ".sh",
        wrapper = base .. "_wrapper.sh",
        owner   = base .. ".owner",
    }
end

function M.get_job_owner(job_id)
    if not job_id or job_id == "" then
        return nil
    end

    local paths = job_paths(job_id)
    local owner = str.trim(fs.read_file(paths.owner) or "")
    if owner == "" then
        return nil
    end

    return owner
end

local function normalize_exit_code(ok, why, code)
    -- Lua 5.2+ : os.execute() -> (true|nil, "exit"|"signal", code)
    -- NuttX 上 code 通常是 wait() 风格（exit_code << 8）。
    if ok == true then
        return 0
    end

    local n = nil
    if type(ok) == "number" then
        n = ok
    elseif type(code) == "number" then
        n = code
    end

    if n ~= nil then
        if n > 255 then
            return math.floor(n / 256)
        end
        return n
    end

    return 1
end

local function read_number_file(path)
    local s = fs.read_file(path)
    if not s or s == "" then return nil end
    return tonumber(s:match("(%-?%d+)"))
end

local function read_pid(paths)
    return read_number_file(paths.pid)
end

local function pid_alive(pid)
    if not pid then return false end
    local status = fs.read_file("/proc/" .. tostring(pid) .. "/status")
    return (status ~= nil and status ~= "")
end

local function cleanup(paths)
    pcall(function()
        fs.remove_file(paths.status)
        fs.remove_file(paths.out)
        fs.remove_file(paths.pid)
        fs.remove_file(paths.wrapper_pid)
        fs.remove_file(paths.killed)
        fs.remove_file(paths.script)
        fs.remove_file(paths.wrapper)
        fs.remove_file(paths.owner)
    end)
end

----------------------------------------------------------------------
-- 启动 Job
----------------------------------------------------------------------

function M.start_job(shell_cmd, is_sync, app_id)
    if not shell_cmd or shell_cmd == "" then
        return { ok = false, message = "empty shell command" }
    end

    ensure_job_dir()

    local job_id = gen_job_id()
    local paths  = job_paths(job_id)

    log("start_job: id=" .. job_id .. " mode=" .. (is_sync and "SYNC" or "ASYNC"))

    if app_id and app_id ~= "" then
        if not fs.write_file(paths.owner, tostring(app_id) .. "\n") then
            return { ok = false, message = "failed to write owner file" }
        end
    end

    -- 1) 落盘命令文本（便于排查；注意：该设备 `sh <file>` 返回码不可靠，因此不直接执行脚本文件）
    if not fs.write_file(paths.script, shell_cmd .. "\n") then
        pcall(function()
            fs.remove_file(paths.owner)
        end)
        return { ok = false, message = "failed to write script file" }
    end

    -- A) 同步：前台执行并直接返回结果
    if is_sync then
        local cwd = M.get_cwd(app_id)
        local flat_cmd = tostring(shell_cmd or "")
        flat_cmd = flat_cmd:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "; ")
        local full_cmd = "cd " .. str.sh_quote(cwd) .. "; " .. flat_cmd .. " > " .. paths.out
        local ok, why, code = os.execute(full_cmd)
        local exit_code = normalize_exit_code(ok, why, code)
        local output = fs.read_file(paths.out) or ""

        -- 同步任务不需要后续 poll：清理文件避免堆积
        pcall(function()
            fs.remove_file(paths.out)
            fs.remove_file(paths.script)
            fs.remove_file(paths.owner)
        end)

        return {
            ok     = true,
            async  = false,
            job_id = job_id,
            state  = "done",
            result = {
                exit_code = exit_code,
                status    = "exit",
                success   = (exit_code == 0),
                output    = output,
                cwd       = cwd,
            }
        }
    end

    -- B) 异步：执行脚本本身放到后台进程里跑，daemon 轮询 out/status。
    local cwd = M.get_cwd(app_id)
    local wrapper_content = table.concat({
        "if [ -f " .. paths.killed .. " ]",
        "then",
        "  echo 137 > " .. paths.status,
        "  rm " .. paths.killed,
        "  exit",
        "fi",
        "",
        "cd " .. str.sh_quote(cwd),
        "",
        "sh " .. paths.script .. " > " .. paths.out .. " &",
        "echo $! > " .. paths.pid,
        "wait `cat " .. paths.pid .. "`",
        "",
        "if [ -f " .. paths.killed .. " ]",
        "then",
        "  echo 137 > " .. paths.status,
        "  rm " .. paths.killed,
        "else",
        "  echo -1 > " .. paths.status,
        "fi",
        "",
    }, "\n")

    if not fs.write_file(paths.wrapper, wrapper_content) then
        return { ok = false, message = "failed to write wrapper file" }
    end

    local spawn_cmd = string.format("sh %s &; echo $! > %s", paths.wrapper, paths.wrapper_pid)
    local ok_spawn, why_spawn, code_spawn = os.execute(spawn_cmd)
    local spawn_ec = normalize_exit_code(ok_spawn, why_spawn, code_spawn)
    if spawn_ec ~= 0 then
        return { ok = false, message = "failed to spawn background process", exit_code = spawn_ec }
    end

    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "running",
        result = {
            cwd = cwd,
        }
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

    local status_content = fs.read_file(paths.status)
    if status_content and status_content ~= "" then
        return { ok = true, message = "already done" }
    end

    fs.write_file(paths.killed, "1")

    local pid = read_pid(paths)
    if pid and pid_alive(pid) then
        log("kill_job: killing pid " .. tostring(pid))
        os.execute("kill -9 " .. tostring(pid))
        return { ok = true, message = "killed", pid = pid }
    end

    return { ok = true, message = "kill requested (pid not ready yet)" }
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
    local current_pid = read_pid(paths)
    local wrapper_pid = read_number_file(paths.wrapper_pid)
    local status_content = fs.read_file(paths.status)

    -- 1) 运行中
    if not status_content or status_content == "" then
        if wrapper_pid and pid_alive(wrapper_pid) then
            return {
                ok     = true,
                async  = true,
                job_id = job_id,
                state  = "running",
                result = {
                    output = current_output,
                    pid    = current_pid,
                    cwd    = M.get_cwd(app_id),
                }
            }
        end

        if current_pid and pid_alive(current_pid) then
            return {
                ok     = true,
                async  = true,
                job_id = job_id,
                state  = "running",
                result = {
                    output = current_output,
                    pid    = current_pid,
                    cwd    = M.get_cwd(app_id),
                }
            }
        end

        fs.write_file(paths.status, "-1")
        status_content = "-1"
    end

    -- 2) 已结束
    local exit_code = tonumber((status_content or ""):match("(%-?%d+)")) or -1
    cleanup(paths)

    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "done",
        result = {
            exit_code = exit_code,
            status    = "exit",
            success   = (exit_code == 0),
            output    = current_output,
            pid       = current_pid,
            cwd       = M.get_cwd(app_id),
        }
    }
end

return M
