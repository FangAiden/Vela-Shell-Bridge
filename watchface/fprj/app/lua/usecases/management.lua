-- app/usecases/management.lua
-- Management commands for IPC (command registry pattern).

local policy    = require("domain.policy")
local logmod    = require("domain.log")
local allowlist = require("domain.allowlist")
local appscan   = require("domain.app_scan")
local settings  = require("domain.settings")
local execmod   = require("domain.exec")
local responses = require("core.ipc_responses")
local str       = require("util.str")
local b64       = require("util.base64_util")
local fs        = require("util.fs_util")

local M = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function ensure_parent_dir(path)
    if type(path) ~= "string" then
        return
    end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then
        return
    end
    os.execute("mkdir -p " .. str.sh_quote(dir))
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local sz = f:seek("end")
    f:close()
    if type(sz) ~= "number" then
        return nil
    end
    return sz
end

local function read_file_chunk(path, offset, length)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, "open failed: " .. tostring(err)
    end

    local sz = f:seek("end")
    if type(sz) == "number" then
        if type(offset) ~= "number" or offset < 0 then
            offset = 0
        end
        if offset > sz then
            offset = sz
        end
        f:seek("set", offset)
    else
        sz = nil
        if type(offset) == "number" and offset > 0 then
            pcall(function()
                f:seek("set", offset)
            end)
        end
    end

    local data = f:read(length) or ""
    f:close()

    local next_offset = (type(offset) == "number" and offset or 0) + #data
    local eof = false
    if type(sz) == "number" then
        eof = next_offset >= sz
    else
        eof = (#data < length)
    end

    return {
        size = (type(sz) == "number") and sz or -1,
        offset = (type(offset) == "number") and offset or 0,
        next_offset = next_offset,
        eof = eof,
        raw_len = #data,
        data = data,
    }
end

local function write_file_bytes(path, bytes, mode)
    ensure_parent_dir(path)
    local open_mode = (mode == "truncate") and "wb" or "ab"
    local f, err = io.open(path, open_mode)
    if not f then
        return false, "open failed: " .. tostring(err)
    end
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

local function scan_apps(ctx, admin_id)
    local apps, meta = {}, {}
    if appscan.scan_installed_apps then
        apps, meta = appscan.scan_installed_apps()
    else
        apps = appscan.scan_all_apps(ctx.QUICKAPP_BASE)
        meta = {}
    end

    if type(apps) == "table" and #apps > 0 then
        local filtered = {}
        local meta2 = {}
        for _, id in ipairs(apps) do
            if id ~= admin_id then
                filtered[#filtered + 1] = id
                if meta and meta[id] ~= nil then
                    meta2[id] = meta[id]
                end
            end
        end
        apps = filtered
        meta = meta2
    end

    return apps, meta
end

----------------------------------------------------------------------
-- Command registry
----------------------------------------------------------------------

local commands = {}

local function register(name, handler)
    commands[name] = handler
end

register("get_policies", function(args, ctx, req)
    return responses.ok(req.id, policy.get_all_policies())
end)

register("get_settings", function(args, ctx, req)
    return responses.ok(req.id, settings.get and settings.get() or {})
end)

register("get_env", function(args, ctx, req)
    return responses.ok(req.id, {
        quickapp_root = ctx.QUICKAPP_ROOT,
        admin_files_dir = ctx.ADMIN_FILES_DIR,
        admin_app_id = ctx.ADMIN_APP_ID,
        apps_json = ctx.APPS_JSON,
        app_install_base = ctx.APP_INSTALL_BASE,
    })
end)

register("shell_get_cwd", function(args, ctx, req, app_id)
    return responses.ok(req.id, { cwd = execmod.get_cwd(app_id) })
end)

register("shell_set_cwd", function(args, ctx, req, app_id)
    local cwd = str.trim(args.cwd)
    local ok, cwd_or_err = execmod.cd(app_id, cwd)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(cwd_or_err or "invalid cwd"))
    end
    return responses.ok(req.id, { cwd = cwd_or_err })
end)

register("fs_stat", function(args, ctx, req)
    local path = str.trim(args.path)
    if path == "" then
        return responses.error(req.id, "BAD_REQUEST", "path required")
    end
    local is_dir = (fs.is_dir and fs.is_dir(path)) or false
    local exists = is_dir or (fs.file_exists and fs.file_exists(path)) or false
    local sz = -1
    if exists and not is_dir then
        sz = file_size(path) or -1
    end
    return responses.ok(req.id, {
        path = path,
        exists = exists,
        is_dir = is_dir,
        size = sz,
    })
end)

register("fs_read", function(args, ctx, req)
    local path = str.trim(args.path)
    if path == "" then
        return responses.error(req.id, "BAD_REQUEST", "path required")
    end
    local offset = tonumber(args.offset) or 0
    local length = tonumber(args.length) or 2048
    if length < 1 then length = 1 end
    if length > 32768 then length = 32768 end
    local encoding = str.trim(args.encoding)
    if encoding == "" then
        encoding = "base64"
    end
    if encoding ~= "base64" then
        return responses.error(req.id, "BAD_REQUEST", "encoding must be base64")
    end

    local chunk, err = read_file_chunk(path, offset, length)
    if not chunk then
        return responses.error(req.id, "BAD_REQUEST", tostring(err or "read failed"))
    end

    return responses.ok(req.id, {
        path = path,
        encoding = "base64",
        offset = chunk.offset,
        next_offset = chunk.next_offset,
        eof = chunk.eof,
        size = chunk.size,
        data = b64.encode(chunk.data or ""),
    })
end)

register("fs_write", function(args, ctx, req)
    local path = str.trim(args.path)
    if path == "" then
        return responses.error(req.id, "BAD_REQUEST", "path required")
    end
    local data_b64 = args.data
    if type(data_b64) ~= "string" or data_b64 == "" then
        return responses.error(req.id, "BAD_REQUEST", "data required")
    end
    local mode = str.trim(args.mode)
    if mode ~= "truncate" and mode ~= "append" then
        mode = "append"
    end
    local encoding = str.trim(args.encoding)
    if encoding == "" then
        encoding = "base64"
    end
    if encoding ~= "base64" then
        return responses.error(req.id, "BAD_REQUEST", "encoding must be base64")
    end

    local bytes = b64.decode(data_b64)
    local ok, n_or_err = write_file_bytes(path, bytes, mode)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(n_or_err or "write failed"))
    end
    return responses.ok(req.id, {
        path = path,
        bytes = n_or_err,
        mode = mode,
    })
end)

register("set_settings", function(args, ctx, req)
    local ok, data_or_err = true, nil
    if settings.update then
        ok, data_or_err = settings.update(args or {})
    else
        ok, data_or_err = false, "settings module missing"
    end
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", tostring(data_or_err or "invalid settings"))
    end
    return responses.ok(req.id, data_or_err or {})
end)

register("get_allowlist", function(args, ctx, req)
    return responses.ok(req.id, { allowlist = list_allowlist() })
end)

register("scan_apps", function(args, ctx, req)
    local apps, meta = scan_apps(ctx, ctx.ADMIN_APP_ID)
    return responses.ok(req.id, { apps = apps, meta = meta })
end)

register("set_policy", function(args, ctx, req)
    local app_id2 = args.app_id
    local pol = args.policy
    local ok, err = policy.set_policy(app_id2, pol)
    if not ok then
        return responses.error(req.id, "BAD_REQUEST", err or "invalid policy")
    end
    return responses.ok(req.id, { ok = true })
end)

register("get_logs", function(args, ctx, req)
    local stats = logmod.get_logs()
    local exec_logs = {}
    if logmod.get_exec_logs then
        exec_logs = logmod.get_exec_logs()
    end
    return responses.ok(req.id, { stats = stats, exec = exec_logs })
end)

register("clear_logs", function(args, ctx, req)
    logmod.clear_logs()
    if logmod.clear_exec_logs then
        logmod.clear_exec_logs()
    end
    return responses.ok(req.id, { ok = true })
end)

register("set_allowlist", function(args, ctx, req)
    local list = args.allowlist
    if type(list) ~= "table" then
        return responses.error(req.id, "BAD_REQUEST", "allowlist must be a table")
    end
    allowlist.set_list(list)
    return responses.ok(req.id, { ok = true })
end)

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

function M.handle(app_id, req, ctx)
    if app_id ~= ctx.ADMIN_APP_ID then
        return responses.error(req.id, "NO_PERMISSION", "Only admin app can send management commands")
    end

    local handler = commands[req.cmd]
    if not handler then
        return responses.error(req.id, "BAD_REQUEST", "Unknown management cmd: " .. tostring(req.cmd))
    end

    return handler(req.args or {}, ctx, req, app_id)
end

return M
