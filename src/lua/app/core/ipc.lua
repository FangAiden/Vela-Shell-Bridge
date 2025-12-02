-- app/core/ipc.lua
-- 文件 IPC 守护进程：扫描 QUICKAPP_BASE 下各 App 目录，处理 exec / management 请求

local config    = require("app.config")
local fs        = require("app.util.fs_util")
local policy    = require("app.domain.policy")
local logmod    = require("app.domain.log")
local allowlist = require("app.domain.allowlist")
local execmod   = require("app.domain.exec")

local JSON = _G.JSON or require("app.util.json_util")

local M = {}

local QUICKAPP_BASE = config.QUICKAPP_BASE
local ADMIN_APP_ID  = config.ADMIN_APP_ID

-- ipc_request_<id>.json
local REQ_PATTERN = "^ipc_request_([%w_%-]+)%.json$"

local function log(msg)
    if _G.SU_LOG then
        _G.SU_LOG("[ipc] " .. msg)
    else
        print("[ipc]", msg)
    end
end

----------------------------------------------------------------------
-- 基础工具：读写 JSON、响应包装
----------------------------------------------------------------------

local function read_json_file(path)
    local txt = fs.read_file(path)
    if not txt or txt == "" then
        return nil, "empty"
    end
    local ok, obj = pcall(JSON.decode, txt)
    if not ok then
        return nil, obj
    end
    return obj
end

local function write_json_file(path, obj)
    local ok, err = fs.write_file(path, JSON.encode(obj))
    if not ok then
        log("write_json_file failed: " .. tostring(err))
    end
    return ok, err
end

local function ok_response(req_id, data)
    return {
        id   = req_id,
        ok   = true,
        data = data
    }
end

local function error_response(req_id, code, message, extra)
    local resp = {
        id      = req_id,
        ok      = false,
        error   = { code = code, message = message },
        message = message
    }
    if extra then
        for k,v in pairs(extra) do
            resp[k] = v
        end
    end
    return resp
end

----------------------------------------------------------------------
-- Management 命令（仅 ADMIN_APP_ID 可用）
----------------------------------------------------------------------

local function handle_management(app_id, req)
    if app_id ~= ADMIN_APP_ID then
        return error_response(req.id, "NO_PERMISSION", "Only admin app can send management commands")
    end

    local cmd  = req.cmd
    local args = req.args or {}

    if cmd == "get_policies" then
        local data = policy.get_all_policies()
        return ok_response(req.id, data)

    elseif cmd == "set_policy" then
        local app_id2 = args.app_id
        local pol     = args.policy
        local ok, err = policy.set_policy(app_id2, pol)
        if not ok then
            return error_response(req.id, "BAD_REQUEST", err or "invalid policy")
        end
        return ok_response(req.id, { ok = true })

    elseif cmd == "get_logs" then
        local logs = logmod.get_logs()
        return ok_response(req.id, logs)

    elseif cmd == "clear_logs" then
        logmod.clear_logs()
        return ok_response(req.id, { ok = true })

    elseif cmd == "set_allowlist" then
        local list = args.allowlist
        if type(list) ~= "table" then
            return error_response(req.id, "BAD_REQUEST", "allowlist must be a table")
        end
        allowlist.set_list(list)
        return ok_response(req.id, { ok = true })

    else
        return error_response(req.id, "BAD_REQUEST", "Unknown management cmd: " .. tostring(cmd))
    end
end

----------------------------------------------------------------------
-- Exec：异步 Job 模型
-- - 没有 args.job_id → 启动新 job (start_job)
-- - 有 args.job_id   → 轮询状态       (poll_job)
----------------------------------------------------------------------

local function handle_exec(app_id, req)
    local args     = req.args or {}
    local shell_cmd = args.shell
    local job_id    = args.job_id

    -- 查询已有 Job 状态：不计入 request log，也不做策略检查
    if job_id and job_id ~= "" then
        local r = execmod.poll_job(job_id)
        -- r 本身已经是 { ok, async, job_id, state, result? }
        r.id = req.id
        return r
    end

    -- 启动新 Job：需要策略 + 日志
    if not shell_cmd or shell_cmd == "" then
        return error_response(req.id, "BAD_REQUEST", "args.shell required")
    end

    -- 记录一次请求日志（包括 admin）
    logmod.record_request(app_id)

    -- 管理员 App：跳过策略检查，直接允许
    if app_id ~= ADMIN_APP_ID then
        local allowed, reason = policy.check_exec_allowed(app_id)
        if not allowed then
            local code = (reason == "DENY") and "NO_PERMISSION" or "NEED_PERMISSION"
            return error_response(
                req.id,
                code,
                "App " .. app_id .. " is not allowed to execute shell (reason: " .. tostring(reason) .. ")"
            )
        end
    end

    -- 启动后台 Job
    local r = execmod.start_job(shell_cmd)
    r.id = req.id
    return r
end

----------------------------------------------------------------------
-- 路由分发
----------------------------------------------------------------------

local function route_request(app_id, req)
    if req.type == "exec" then
        return handle_exec(app_id, req)
    elseif req.type == "management" then
        return handle_management(app_id, req)
    else
        return error_response(req.id, "BAD_REQUEST", "Unknown request type: " .. tostring(req.type))
    end
end

----------------------------------------------------------------------
-- 处理单个请求文件
----------------------------------------------------------------------

local function process_request_file(app_id, app_dir, file_name)
    local id = file_name:match(REQ_PATTERN)
    if not id then
        return
    end

    local req_path  = app_dir .. "/" .. file_name
    local resp_path = app_dir .. "/ipc_response_" .. id .. ".json"

    local req, err = read_json_file(req_path)
    if not req then
        log("process_request_file: invalid json: " .. tostring(err))
        local resp = error_response(id, "BAD_REQUEST", "invalid json: " .. tostring(err))
        write_json_file(resp_path, resp)
        fs.remove_file(req_path)
        return
    end

    req.id = req.id or id

    local ok, resp = pcall(route_request, app_id, req)
    if not ok then
        log("route_request error: " .. tostring(resp))
        resp = error_response(req.id, "INTERNAL_ERROR", tostring(resp))
    end

    if resp then
        -- resp.id 已经在 handle_exec / handle_management 里设置好了
        write_json_file(resp_path, resp)
    end

    fs.remove_file(req_path)
end

----------------------------------------------------------------------
-- 扫描某个 App 目录
----------------------------------------------------------------------

local function scan_app(app_id)
    local app_dir = QUICKAPP_BASE .. "/" .. app_id
    local files = fs.list_files(app_dir)
    if not files then return end

    for _, name in ipairs(files) do
        if name:match(REQ_PATTERN) then
            process_request_file(app_id, app_dir, name)
        end
    end
end

----------------------------------------------------------------------
-- 每轮运行一次：由 app.app 里的 Timer 周期调用
----------------------------------------------------------------------

function M.run_once()
    -- 1) 管理员 App
    scan_app(ADMIN_APP_ID)

    -- 2) allowlist 中的其他 App
    local list = allowlist.get_all()
    if list then
        for app_id, enabled in pairs(list) do
            if enabled and app_id ~= ADMIN_APP_ID then
                scan_app(app_id)
            end
        end
    end

    -- 3) 持久化策略/日志/allowlist
    policy.save_if_dirty()
    logmod.save_if_dirty()
    allowlist.save_if_dirty()
end

return M
