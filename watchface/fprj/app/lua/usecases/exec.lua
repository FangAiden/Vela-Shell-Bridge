-- app/usecases/exec.lua
-- Exec/kill/poll IPC commands.

local policy    = require("domain.policy")
local logmod    = require("domain.log")
local execmod   = require("domain.exec")
local ctx       = require("core.context")
local str       = require("util.str")
local responses = require("core.ipc_responses")

local M = {}

local function should_save_history()
    return (ctx.save_history ~= false)
end

local function parse_cd_cmd(shell_cmd)
    local s = str.trim(shell_cmd)
    if s == "cd" then
        return true, ""
    end
    local rest = s:match("^cd%s+(.+)$")
    if rest then
        return true, str.strip_quotes(rest)
    end
    return false, nil
end

local function is_cmd_blacklisted(shell_cmd)
    if type(shell_cmd) ~= "string" or shell_cmd == "" then
        return false
    end

    local cmd = shell_cmd
    local token = str.first_token(cmd)
    if token == "" then
        return false
    end

    local list = ctx.cmd_blacklist
    if not list or type(list) ~= "table" then
        return false
    end

    for _, it in ipairs(list) do
        local p = str.trim(it)
        if p ~= "" then
            if p:find("%s") then
                if cmd:find(p, 1, true) then
                    return true, p
                end
            else
                if token == p then
                    return true, p
                end
            end
        end
    end

    return false
end

local function check_job_owner(app_id, job_id, admin_id)
    if app_id == admin_id then
        return true
    end

    if not job_id or job_id == "" then
        return false, "job_id required"
    end

    local owner = nil
    if execmod.get_job_owner then
        owner = execmod.get_job_owner(job_id)
    end

    if not owner or owner == "" then
        return false, "owner unknown"
    end

    if owner ~= app_id then
        return false, "not owner"
    end

    return true
end

local function record_denied(app_id, cmd, resp)
    if should_save_history() and logmod.record_exec_denied then
        pcall(logmod.record_exec_denied, app_id, cmd, resp)
    end
end

function M.handle(app_id, req, ipc_ctx)
    local args = req.args or {}
    local cmd = req.cmd

    -- 1) kill
    if cmd == "kill" then
        if not args.job_id then
            return responses.error(req.id, "BAD_REQUEST", "job_id required for kill")
        end
        local ok_owner = check_job_owner(app_id, args.job_id, ipc_ctx.ADMIN_APP_ID)
        if not ok_owner then
            local resp = responses.error(req.id, "NO_PERMISSION", "Job not owned by app")
            record_denied(app_id, "kill " .. tostring(args.job_id), resp)
            return resp
        end
        local r = execmod.kill_job(args.job_id)
        r.id = req.id
        if should_save_history() and logmod.record_exec_kill then
            pcall(logmod.record_exec_kill, app_id, args.job_id, r)
        end
        return r
    end

    -- 2) exec/poll
    local shell_cmd = args.shell
    local job_id = args.job_id
    local is_sync = (args.sync == true)

    if job_id and job_id ~= "" then
        local ok_owner = check_job_owner(app_id, job_id, ipc_ctx.ADMIN_APP_ID)
        if not ok_owner then
            local resp = responses.error(req.id, "NO_PERMISSION", "Job not owned by app")
            record_denied(app_id, "poll " .. tostring(job_id), resp)
            return resp
        end
        local r = execmod.poll_job(job_id, app_id)
        r.id = req.id
        if should_save_history() and r and r.state == "done" and logmod.update_exec_job then
            pcall(logmod.update_exec_job, job_id, r)
        end
        return r
    end

    if not shell_cmd or shell_cmd == "" then
        return responses.error(req.id, "BAD_REQUEST", "args.shell required")
    end

    local blocked, why = is_cmd_blacklisted(shell_cmd)
    if blocked then
        local resp = responses.error(
            req.id,
            "CMD_BLACKLISTED",
            "Command is blacklisted: " .. tostring(why or "")
        )
        record_denied(app_id, shell_cmd, resp)
        return resp
    end

    if should_save_history() then
        logmod.record_request(app_id)
    end

    if app_id ~= ipc_ctx.ADMIN_APP_ID then
        local allowed, reason = policy.check_exec_allowed(app_id)
        if not allowed then
            local code = (reason == "DENY") and "NO_PERMISSION" or "NEED_PERMISSION"
            local resp = responses.error(
                req.id,
                code,
                "App " .. app_id .. " is not allowed to execute shell (reason: " .. tostring(reason) .. ")"
            )
            record_denied(app_id, shell_cmd, resp)
            return resp
        end
    end

    local is_cd, cd_arg = parse_cd_cmd(shell_cmd)
    if is_cd then
        local ok_cd, cwd_or_err = execmod.cd(app_id, cd_arg)
        if not ok_cd then
            local resp = responses.error(req.id, "BAD_REQUEST", tostring(cwd_or_err or "cd failed"))
            if should_save_history() and logmod.record_exec_start then
                pcall(logmod.record_exec_start, app_id, shell_cmd, resp)
            end
            return resp
        end

        local r = {
            ok     = true,
            async  = false,
            job_id = "",
            state  = "done",
            result = {
                exit_code = 0,
                status    = "exit",
                success   = true,
                output    = "",
                cwd       = cwd_or_err,
            }
        }
        r.id = req.id
        if should_save_history() and logmod.record_exec_start then
            pcall(logmod.record_exec_start, app_id, shell_cmd, r)
        end
        return r
    end

    local r = execmod.start_job(shell_cmd, is_sync, app_id)
    r.id = req.id
    if should_save_history() and logmod.record_exec_start then
        pcall(logmod.record_exec_start, app_id, shell_cmd, r)
    end
    return r
end

return M
