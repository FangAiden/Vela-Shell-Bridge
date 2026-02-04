-- core/ipc_router.lua
-- 统一请求路由：合并 exec 和 management 命令处理

local responses = require("core.ipc_responses")
local policy    = require("domain.policy")
local logmod    = require("domain.log")
local execmod   = require("domain.exec")
local allowlist = require("domain.allowlist")
local appscan   = require("domain.app_scan")
local settings  = require("domain.settings")
local ctx       = require("core.context")
local str       = require("util.str")
local b64       = require("util.base64_util")
local fs        = require("util.fs_util")

local M = {}

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------

local function should_save_history()
    return ctx.save_history ~= false
end

local function parse_cd_cmd(shell_cmd)
    local s = str.trim(shell_cmd)
    if s == "cd" then return true, "" end
    local rest = s:match("^cd%s+(.+)$")
    if rest then return true, str.strip_quotes(rest) end
    return false, nil
end

--- Extract the base command name from a possibly path-qualified command.
--- e.g., "/system/bin/rm" -> "rm", "rm" -> "rm"
local function get_base_cmd_name(cmd_token)
    if not cmd_token or cmd_token == "" then return "" end
    -- Extract basename (after last /)
    local base = cmd_token:match("([^/]+)$")
    return base or cmd_token
end

local function is_cmd_blacklisted(shell_cmd)
    if type(shell_cmd) ~= "string" or shell_cmd == "" then return false end
    local token = str.first_token(shell_cmd)
    if token == "" then return false end

    -- Get the base name to prevent path-based bypass (e.g., /system/bin/rm)
    local base_name = get_base_cmd_name(token)

    local list = ctx.cmd_blacklist
    if not list or type(list) ~= "table" then return false end

    for _, it in ipairs(list) do
        local p = str.trim(it)
        if p ~= "" then
            if p:find("%s") then
                -- Pattern contains space: check as substring in full command
                if shell_cmd:find(p, 1, true) then return true, p end
            else
                -- Single word pattern: match against both full path and basename
                if token == p or base_name == p then return true, p end
            end
        end
    end
    return false
end

local function check_job_owner(app_id, job_id, admin_id)
    if app_id == admin_id then return true end
    if not job_id or job_id == "" then return false, "job_id required" end
    local owner = execmod.get_job_owner and execmod.get_job_owner(job_id) or nil
    if not owner or owner == "" then return false, "owner unknown" end
    if owner ~= app_id then return false, "not owner" end
    return true
end

local function record_denied(app_id, cmd, resp)
    if should_save_history() and logmod.record_exec_denied then
        pcall(logmod.record_exec_denied, app_id, cmd, resp)
    end
end

local function ensure_parent_dir(path)
    if type(path) ~= "string" then return end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    os.execute("mkdir -p " .. str.sh_quote(dir))
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local sz = f:seek("end")
    f:close()
    return type(sz) == "number" and sz or nil
end

local function read_file_chunk(path, offset, length)
    local f, err = io.open(path, "rb")
    if not f then return nil, "open failed: " .. tostring(err) end
    local sz = f:seek("end")
    if type(sz) == "number" then
        offset = math.max(0, math.min(offset or 0, sz))
        f:seek("set", offset)
    else
        sz = nil
        if type(offset) == "number" and offset > 0 then
            pcall(function() f:seek("set", offset) end)
        end
    end
    local data = f:read(length) or ""
    f:close()
    local next_offset = (offset or 0) + #data
    local eof = sz and next_offset >= sz or #data < length
    return {
        size = sz or -1,
        offset = offset or 0,
        next_offset = next_offset,
        eof = eof,
        raw_len = #data,
        data = data,
    }
end

local function write_file_bytes(path, bytes, mode)
    ensure_parent_dir(path)
    local f, err = io.open(path, mode == "truncate" and "wb" or "ab")
    if not f then return false, "open failed: " .. tostring(err) end
    f:write(bytes)
    f:close()
    return true, #bytes
end

local function list_allowlist()
    local m = allowlist.get_all() or {}
    local list = {}
    for id, enabled in pairs(m) do
        if enabled and type(id) == "string" and id ~= "" then
            list[#list + 1] = id
        end
    end
    table.sort(list)
    return list
end

local function scan_apps(ipc_ctx, admin_id)
    local apps, meta = {}, {}
    if appscan.scan_installed_apps then
        apps, meta = appscan.scan_installed_apps()
    else
        apps = appscan.scan_all_apps(ipc_ctx.QUICKAPP_BASE)
    end
    if type(apps) == "table" and #apps > 0 then
        local filtered, meta2 = {}, {}
        for _, id in ipairs(apps) do
            if id ~= admin_id then
                filtered[#filtered + 1] = id
                if meta and meta[id] then meta2[id] = meta[id] end
            end
        end
        apps, meta = filtered, meta2
    end
    return apps, meta
end

----------------------------------------------------------------------
-- Exec 命令处理
----------------------------------------------------------------------

local function handle_exec_kill(app_id, req, ipc_ctx)
    local args = req.args or {}
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

local function handle_exec_poll(app_id, req, ipc_ctx, job_id)
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

local function handle_exec_start(app_id, req, ipc_ctx, shell_cmd, is_sync)
    -- 黑名单检查
    local blocked, why = is_cmd_blacklisted(shell_cmd)
    if blocked then
        local resp = responses.error(req.id, "CMD_BLACKLISTED", "Command is blacklisted: " .. tostring(why or ""))
        record_denied(app_id, shell_cmd, resp)
        return resp
    end

    if should_save_history() then
        logmod.record_request(app_id)
    end

    -- 权限检查（非 admin）
    if app_id ~= ipc_ctx.ADMIN_APP_ID then
        local allowed, reason = policy.check_exec_allowed(app_id)
        if not allowed then
            local code = reason == "DENY" and "NO_PERMISSION" or "NEED_PERMISSION"
            local resp = responses.error(req.id, code, "App not allowed (reason: " .. tostring(reason) .. ")")
            record_denied(app_id, shell_cmd, resp)
            return resp
        end
    end

    -- cd 特殊处理
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
            ok = true, async = false, job_id = "", state = "done",
            result = { exit_code = 0, status = "exit", success = true, output = "", cwd = cwd_or_err }
        }
        r.id = req.id
        if should_save_history() and logmod.record_exec_start then
            pcall(logmod.record_exec_start, app_id, shell_cmd, r)
        end
        return r
    end

    -- 正常执行
    local r = execmod.start_job(shell_cmd, is_sync, app_id)
    r.id = req.id
    if should_save_history() and logmod.record_exec_start then
        pcall(logmod.record_exec_start, app_id, shell_cmd, r)
    end
    return r
end

local function handle_exec(app_id, req, ipc_ctx)
    local args = req.args or {}
    local cmd = req.cmd

    if cmd == "kill" then
        return handle_exec_kill(app_id, req, ipc_ctx)
    end

    local job_id = args.job_id
    if job_id and job_id ~= "" then
        return handle_exec_poll(app_id, req, ipc_ctx, job_id)
    end

    local shell_cmd = args.shell
    if not shell_cmd or shell_cmd == "" then
        return responses.error(req.id, "BAD_REQUEST", "args.shell required")
    end

    return handle_exec_start(app_id, req, ipc_ctx, shell_cmd, args.sync == true)
end

----------------------------------------------------------------------
-- Management 命令注册
----------------------------------------------------------------------

local mgmt_commands = {}

local function reg(name, handler)
    mgmt_commands[name] = handler
end

reg("get_policies", function(args, ipc_ctx, req)
    return responses.ok(req.id, policy.get_all_policies())
end)

reg("get_settings", function(args, ipc_ctx, req)
    return responses.ok(req.id, settings.get and settings.get() or {})
end)

reg("get_env", function(args, ipc_ctx, req)
    return responses.ok(req.id, {
        quickapp_base = ipc_ctx.QUICKAPP_BASE,
        admin_app_id = ipc_ctx.ADMIN_APP_ID,
        apps_json = ipc_ctx.APPS_JSON,
        app_install_base = ipc_ctx.APP_INSTALL_BASE,
    })
end)

reg("shell_get_cwd", function(args, ipc_ctx, req, app_id)
    return responses.ok(req.id, { cwd = execmod.get_cwd(app_id) })
end)

reg("shell_set_cwd", function(args, ipc_ctx, req, app_id)
    local cwd = str.trim(args.cwd or "")
    local ok, cwd_or_err = execmod.cd(app_id, cwd)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(cwd_or_err or "invalid cwd"))
    end
    return responses.ok(req.id, { cwd = cwd_or_err })
end)

reg("fs_stat", function(args, ipc_ctx, req)
    local path = str.trim(args.path or "")
    if path == "" then return responses.error(req.id, "BAD_REQUEST", "path required") end
    local is_dir = fs.is_dir and fs.is_dir(path) or false
    local exists = is_dir or (fs.file_exists and fs.file_exists(path)) or false
    local sz = (exists and not is_dir) and (file_size(path) or -1) or -1
    return responses.ok(req.id, { path = path, exists = exists, is_dir = is_dir, size = sz })
end)

reg("fs_read", function(args, ipc_ctx, req)
    local path = str.trim(args.path or "")
    if path == "" then return responses.error(req.id, "BAD_REQUEST", "path required") end
    local offset = tonumber(args.offset) or 0
    local length = math.max(1, math.min(tonumber(args.length) or 2048, 32768))
    local encoding = str.trim(args.encoding or "")
    if encoding == "" then encoding = "base64" end
    if encoding ~= "base64" then
        return responses.error(req.id, "BAD_REQUEST", "encoding must be base64")
    end
    local chunk, err = read_file_chunk(path, offset, length)
    if not chunk then
        return responses.error(req.id, "BAD_REQUEST", tostring(err or "read failed"))
    end
    return responses.ok(req.id, {
        path = path, encoding = "base64",
        offset = chunk.offset, next_offset = chunk.next_offset,
        eof = chunk.eof, size = chunk.size,
        data = b64.encode(chunk.data or ""),
    })
end)

reg("fs_write", function(args, ipc_ctx, req)
    local path = str.trim(args.path or "")
    if path == "" then return responses.error(req.id, "BAD_REQUEST", "path required") end
    local data_b64 = args.data
    if type(data_b64) ~= "string" or data_b64 == "" then
        return responses.error(req.id, "BAD_REQUEST", "data required")
    end
    local mode = str.trim(args.mode or "")
    if mode ~= "truncate" and mode ~= "append" then mode = "append" end
    local encoding = str.trim(args.encoding or "")
    if encoding == "" then encoding = "base64" end
    if encoding ~= "base64" then
        return responses.error(req.id, "BAD_REQUEST", "encoding must be base64")
    end
    local bytes = b64.decode(data_b64)
    local ok, n_or_err = write_file_bytes(path, bytes, mode)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(n_or_err or "write failed"))
    end
    return responses.ok(req.id, { path = path, bytes = n_or_err, mode = mode })
end)

reg("set_settings", function(args, ipc_ctx, req)
    if not settings.update then
        return responses.error(req.id, "BAD_REQUEST", "settings module missing")
    end
    local ok, data_or_err = settings.update(args or {})
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(data_or_err or "invalid settings"))
    end
    return responses.ok(req.id, data_or_err or {})
end)

reg("get_allowlist", function(args, ipc_ctx, req)
    return responses.ok(req.id, { allowlist = list_allowlist() })
end)

reg("scan_apps", function(args, ipc_ctx, req)
    local apps, meta = scan_apps(ipc_ctx, ipc_ctx.ADMIN_APP_ID)
    return responses.ok(req.id, { apps = apps, meta = meta })
end)

reg("set_policy", function(args, ipc_ctx, req)
    local ok, err = policy.set_policy(args.app_id, args.policy)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", err or "invalid policy")
    end
    return responses.ok(req.id, { ok = true })
end)

reg("get_logs", function(args, ipc_ctx, req)
    local stats = logmod.get_logs()
    local exec_logs = logmod.get_exec_logs and logmod.get_exec_logs() or {}
    return responses.ok(req.id, { stats = stats, exec = exec_logs })
end)

reg("clear_logs", function(args, ipc_ctx, req)
    logmod.clear_logs()
    if logmod.clear_exec_logs then logmod.clear_exec_logs() end
    return responses.ok(req.id, { ok = true })
end)

reg("set_allowlist", function(args, ipc_ctx, req)
    local list = args.allowlist
    if type(list) ~= "table" then
        return responses.error(req.id, "BAD_REQUEST", "allowlist must be a table")
    end
    allowlist.set_list(list)
    return responses.ok(req.id, { ok = true })
end)

local function handle_management(app_id, req, ipc_ctx)
    if app_id ~= ipc_ctx.ADMIN_APP_ID then
        return responses.error(req.id, "NO_PERMISSION", "Only admin can send management commands")
    end
    local handler = mgmt_commands[req.cmd]
    if not handler then
        return responses.error(req.id, "BAD_REQUEST", "Unknown management cmd: " .. tostring(req.cmd))
    end
    return handler(req.args or {}, ipc_ctx, req, app_id)
end

----------------------------------------------------------------------
-- 路由入口
----------------------------------------------------------------------

function M.route_request(ipc_ctx, app_id, req)
    if req.type == "exec" then
        return handle_exec(app_id, req, ipc_ctx)
    elseif req.type == "management" then
        return handle_management(app_id, req, ipc_ctx)
    end
    return responses.error(req.id, "BAD_REQUEST", "Unknown request type: " .. tostring(req.type))
end

return M
