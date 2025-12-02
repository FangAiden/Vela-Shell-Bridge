-- app/domain/exec.lua
-- 异步 Job 引擎（适配你的 nsh：只用 >、;、&、sh -c）

local config  = require("app.config")
local fs      = require("app.util.fs_util")

local M       = {}

-- 所有 job 文件位置：<TMP_DIR>/su_jobs/
local JOB_DIR = config.TMP_DIR .. "/su_jobs"

local function log(msg)
    if _G.SU_LOG then
        _G.SU_LOG("[exec] " .. msg)
    else
        print("[exec]", msg)
    end
end

-- Shell 安全：把任意字符串安全塞进单引号
local function shell_quote_single(s)
    s = tostring(s or "")
    -- 'foo' => 'foo'，中间的 ' 被替换成 '\'' 这种安全形式
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
        out    = base .. ".out",
        status = base .. ".status",
    }
end

----------------------------------------------------------------------
-- 启动后台 Job：直接用一条 sh -c 'cmd > out; echo $? > status' &
----------------------------------------------------------------------

function M.start_job(shell_cmd)
    if not shell_cmd or shell_cmd == "" then
        return {
            ok      = false,
            error   = { code = "BAD_REQUEST", message = "empty shell command" },
            message = "empty shell command"
        }
    end

    local job_id = gen_job_id()
    local paths  = job_paths(job_id)

    log("start_job: id=" .. job_id .. " cmd=" .. shell_cmd)

    -- 确保 JOB_DIR 存在（双保险）
    pcall(function()
        os.execute("mkdir -p " .. JOB_DIR)
    end)

    -- 注意：你的 shell 只支持 >，不支持 2>&1，我们只抓 stdout。
    -- inner_cmd 形如：  "ping 8.8.8.8 -c 3 > /data/tmp/su_jobs/job_xxx.out; echo $? > /data/tmp/su_jobs/job_xxx.status"
    local inner_cmd    = string.format(
        "set +e; %s > %s; echo $? > %s",
        shell_cmd,
        paths.out,
        paths.status
    )

    -- 整句放进 sh -c '....' 里执行，再在外层加 & 做后台：
    --   sh -c '<inner_cmd>' &
    local quoted_inner = shell_quote_single(inner_cmd)
    local full_cmd     = string.format("sh -c %s &", quoted_inner)

    log("start_job: os.execute: " .. full_cmd)
    local success, status, code = os.execute(full_cmd)
    log("start_job: os.execute success=" ..
    tostring(success) .. " status=" .. tostring(status) .. " code=" .. tostring(code))

    if not success then
        log("start_job: os.execute failed status=" .. tostring(status) .. " code=" .. tostring(code))
        return {
            ok      = false,
            error   = { code = "EXEC_START_FAILED", message = "failed to start background job" },
            message = "failed to start background job"
        }
    end

    -- 这里只负责“起任务”，不等结束
    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "running"
    }
end

----------------------------------------------------------------------
-- 轮询 Job 状态：status 文件不存在 → running；存在 → done
----------------------------------------------------------------------

function M.poll_job(job_id)
    if not job_id or job_id == "" then
        return {
            ok      = false,
            error   = { code = "BAD_REQUEST", message = "job_id required" },
            message = "job_id required"
        }
    end

    local paths = job_paths(job_id)

    local status_content = fs.read_file(paths.status)
    if not status_content or status_content == "" then
        -- 还没完成
        return {
            ok     = true,
            async  = true,
            job_id = job_id,
            state  = "running"
        }
    end

    -- 任务已完成，解析 exit_code
    local exit_code = tonumber((status_content or ""):match("(%-?%d+)")) or -1
    local output    = fs.read_file(paths.out) or ""

    -- 清理文件（错误忽略）
    pcall(function() fs.remove_file(paths.status) end)
    pcall(function() fs.remove_file(paths.out) end)

    local success = (exit_code == 0)
    local result = {
        exit_code = exit_code,
        status    = "exit",
        success   = success,
        output    = output
    }

    return {
        ok     = true,
        async  = true,
        job_id = job_id,
        state  = "done",
        result = result
    }
end

return M
