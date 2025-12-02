-- app/domain/exec.lua
-- 终极修正版：
-- 1. 修复 PID=$! 语法错误，改为直接 echo $!
-- 2. 支持实时读取 stdout (Running 状态下也返回 output)
-- 3. 保留同步/异步双模式

local config  = require("app.config")
local fs      = require("app.util.fs_util")

local M       = {}

local JOB_DIR = config.TMP_DIR .. "/su_jobs"

local function log(msg)
    if _G.SU_LOG then
        _G.SU_LOG("[exec] " .. msg)
    else
        print("[exec]", msg)
    end
end

-- Shell 安全引用
local function shell_quote_single(s)
    s = tostring(s or "")
    return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local job_counter = 0
local function gen_job_id()
    job_counter = job_counter + 1
    return tostring(os.time()) .. "_" .. tostring(job_counter)
end

local function job_paths(job_id)
    local base = JOB_DIR .. "/job_" .. job_id
    return {
        base    = base,
        out     = base .. ".out",
        status  = base .. ".status",
        pid     = base .. ".pid",
        script  = base .. ".sh",
        wrapper = base .. "_wrapper.sh"
    }
end

----------------------------------------------------------------------
-- 启动 Job
----------------------------------------------------------------------

function M.start_job(shell_cmd, is_sync)
    if not shell_cmd or shell_cmd == "" then
        return { ok = false, message = "empty shell command" }
    end

    local job_id = gen_job_id()
    local paths  = job_paths(job_id)

    log("start_job: id=" .. job_id .. " mode=" .. (is_sync and "SYNC" or "ASYNC"))

    pcall(function() os.execute("mkdir -p " .. JOB_DIR) end)

    -- ==========================================
    -- 路径 A：同步执行 (Blocking, 适合短任务)
    -- ==========================================
    if is_sync then
        local full_cmd = shell_cmd .. " > " .. paths.out
        local success, status, code = os.execute(full_cmd)
        
        local exit_code = 1
        if type(code) == "number" then exit_code = code
        elseif type(success) == "number" then exit_code = success
        elseif success then exit_code = 0 end

        fs.write_file(paths.status, tostring(exit_code))
        local output = fs.read_file(paths.out) or ""

        return {
            ok     = true,
            async  = false,
            job_id = job_id,
            state  = "done",
            result = {
                exit_code = exit_code,
                status    = status or "exit",
                success   = (exit_code == 0),
                output    = output
            }
        }
    end

    -- ==========================================
    -- 路径 B：异步执行 (Wrapper + PID + Realtime Output)
    -- ==========================================
    
    -- [1] 写入用户脚本
    if not fs.write_file(paths.script, shell_cmd) then
        return { ok = false, message = "failed to write script file" }
    end

    -- [2] 写入 Wrapper 脚本
    -- 修正：不使用 PID=$!，而是直接 echo $! > pid文件
    -- 修正：wait $! 等待
    local wrapper_content = string.format(
[[
sh %s > %s &
echo $! > %s
wait $!
if [ $? -eq 0 ]
then
  echo 0 > %s
else
  echo 1 > %s
fi
]], 
        paths.script, 
        paths.out, 
        paths.pid,    -- 直接写入 PID
        paths.status, 
        paths.status
    )

    if not fs.write_file(paths.wrapper, wrapper_content) then
        return { ok = false, message = "failed to write wrapper file" }
    end

    -- [3] 启动 Wrapper
    local full_cmd = string.format("sh %s &", paths.wrapper)
    local success = os.execute(full_cmd)

    if not success then
        log("start_job: os.execute failed")
        return { ok = false, message = "failed to spawn background process" }
    end

    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "running"
    }
end

----------------------------------------------------------------------
-- 杀死任务 (Kill)
----------------------------------------------------------------------

function M.kill_job(job_id)
    local paths = job_paths(job_id)
    
    local pid_str = fs.read_file(paths.pid)
    if not pid_str or pid_str == "" then
        return { ok = false, message = "pid file not found (job not running?)" }
    end
    
    local pid = tonumber(pid_str:match("(%d+)"))
    if not pid then
        return { ok = false, message = "invalid pid content" }
    end
    
    log("kill_job: killing pid " .. tostring(pid))
    
    local cmd = "kill " .. tostring(pid)
    os.execute(cmd)
    
    -- 强制写入状态，让前端轮询结束
    fs.write_file(paths.status, "137") 
    
    return { ok = true, message = "killed" }
end

----------------------------------------------------------------------
-- 轮询 Job 状态
----------------------------------------------------------------------

function M.poll_job(job_id)
    if not job_id or job_id == "" then
        return { ok = false, message = "job_id required" }
    end

    local paths = job_paths(job_id)

    -- [关键修改] 无论是否结束，都尝试读取当前的 output
    -- 这样前端就能看到 ping 的实时输出了
    local current_output = fs.read_file(paths.out) or ""

    -- 检查 status 文件
    local status_content = fs.read_file(paths.status)
    
    -- 1. 任务还在运行
    if not status_content or status_content == "" then
        return { 
            ok     = true, 
            async  = true, 
            job_id = job_id, 
            state  = "running",
            -- Running 状态也返回当前的 output (部分)
            result = {
                output = current_output
            }
        }
    end

    -- 2. 任务已结束
    local exit_code = tonumber(status_content:match("(%-?%d+)")) or -1

    -- 清理文件
    pcall(function()
        fs.remove_file(paths.status)
        fs.remove_file(paths.out)
        fs.remove_file(paths.pid)
        fs.remove_file(paths.script)
        fs.remove_file(paths.wrapper)
    end)

    local success = (exit_code == 0)

    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "done",
        result = {
            exit_code = exit_code,
            status    = "exit",
            success   = success,
            output    = current_output -- 返回完整日志
        }
    }
end

return M