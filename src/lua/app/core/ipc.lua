-- app/core/ipc.lua
-- 文件 IPC 守护进程
-- 更新：支持 exec 的 sync 模式和 kill 命令

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

local REQ_PATTERN = "^ipc_request_([%w_%-]+)%.json$"

local function log(msg)
    if _G.SU_LOG then
        _G.SU_LOG("[ipc] " .. msg)
    else
        print("[ipc]", msg)
    end
end

----------------------------------------------------------------------
-- 基础工具
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
-- Management 命令
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
-- Exec：执行命令 (Sync/Async) 或 Kill
----------------------------------------------------------------------

local function handle_exec(app_id, req)
    local args = req.args or {}
    local cmd  = req.cmd -- "exec" or "kill"

    -- 1. 处理 Kill 命令 [新增]
    if cmd == "kill" then
        if not args.job_id then
            return error_response(req.id, "BAD_REQUEST", "job_id required for kill")
        end
        -- 调用 exec.lua 的 kill_job
        return execmod.kill_job(args.job_id)
    end

    -- 下面是 exec 逻辑
    local shell_cmd = args.shell
    local job_id    = args.job_id
    local is_sync   = (args.sync == true) -- [新增] 读取同步标志

    -- 2. 轮询已有 Job (poll_job)
    -- 如果传了 job_id，说明是来查状态的
    if job_id and job_id ~= "" then
        local r = execmod.poll_job(job_id)
        r.id = req.id
        return r
    end

    -- 3. 启动新 Job (start_job)
    if not shell_cmd or shell_cmd == "" then
        return error_response(req.id, "BAD_REQUEST", "args.shell required")
    end

    logmod.record_request(app_id)

    -- 权限检查
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

    -- 启动任务 (传入 is_sync 参数)
    local r = execmod.start_job(shell_cmd, is_sync)
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
    if not id then return end

    local req_path  = app_dir .. "/" .. file_name
    local resp_path = app_dir .. "/ipc_response_" .. id .. ".json"

    local req, err = read_json_file(req_path)
    if not req then
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
        write_json_file(resp_path, resp)
    end

    fs.remove_file(req_path)
end

----------------------------------------------------------------------
-- 扫描 app
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
-- 每轮运行
----------------------------------------------------------------------

function M.run_once()
    scan_app(ADMIN_APP_ID)

    local list = allowlist.get_all()
    if list then
        for app_id, enabled in pairs(list) do
            if enabled and app_id ~= ADMIN_APP_ID then
                scan_app(app_id)
            end
        end
    end

    policy.save_if_dirty()
    logmod.save_if_dirty()
    allowlist.save_if_dirty()
end

return M