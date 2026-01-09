-- app/usecases/management.lua
-- Management commands for IPC.

local policy = require("app.domain.policy")
local logmod = require("app.domain.log")
local allowlist = require("app.domain.allowlist")
local appscan = require("app.domain.app_scan")
local settings = require("app.domain.settings")
local execmod = require("app.domain.exec")
local responses = require("app.core.ipc_responses")

local M = {}

local b64 = require("app.util.base64_util")
local fs = require("app.util.fs_util")

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sh_quote(s)
    s = tostring(s or "")
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
end

local function ensure_parent_dir(path)
    if type(path) ~= "string" then
        return
    end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then
        return
    end
    os.execute("mkdir -p " .. sh_quote(dir))
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

    -- Exclude admin app from authorization list.
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

function M.handle(app_id, req, ctx)
    if app_id ~= ctx.ADMIN_APP_ID then
        return responses.error(req.id, "NO_PERMISSION", "Only admin app can send management commands")
    end

    local cmd = req.cmd
    local args = req.args or {}

    if cmd == "get_policies" then
        local data = policy.get_all_policies()
        return responses.ok(req.id, data)

    elseif cmd == "get_settings" then
        local data = settings.get and settings.get() or {}
        return responses.ok(req.id, data)

    elseif cmd == "get_env" then
        return responses.ok(req.id, {
            quickapp_root = ctx.QUICKAPP_ROOT,
            admin_files_dir = ctx.ADMIN_FILES_DIR,
            admin_app_id = ctx.ADMIN_APP_ID,
            apps_json = ctx.APPS_JSON,
            app_install_base = ctx.APP_INSTALL_BASE,
        })

    elseif cmd == "shell_get_cwd" then
        return responses.ok(req.id, { cwd = execmod.get_cwd(app_id) })

    elseif cmd == "shell_set_cwd" then
        local cwd = trim(args.cwd)
        local ok, cwd_or_err = execmod.cd(app_id, cwd)
        if not ok then
            return responses.error(req.id, "BAD_REQUEST", tostring(cwd_or_err or "invalid cwd"))
        end
        return responses.ok(req.id, { cwd = cwd_or_err })

    elseif cmd == "fs_stat" then
        local path = trim(args.path)
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

    elseif cmd == "fs_read" then
        local path = trim(args.path)
        if path == "" then
            return responses.error(req.id, "BAD_REQUEST", "path required")
        end
        local offset = tonumber(args.offset) or 0
        local length = tonumber(args.length) or 2048
        if length < 1 then length = 1 end
        if length > 32768 then length = 32768 end
        local encoding = trim(args.encoding)
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

        local out = {
            path = path,
            encoding = "base64",
            offset = chunk.offset,
            next_offset = chunk.next_offset,
            eof = chunk.eof,
            size = chunk.size,
            data = b64.encode(chunk.data or ""),
        }
        return responses.ok(req.id, out)

    elseif cmd == "fs_write" then
        local path = trim(args.path)
        if path == "" then
            return responses.error(req.id, "BAD_REQUEST", "path required")
        end
        local data_b64 = args.data
        if type(data_b64) ~= "string" or data_b64 == "" then
            return responses.error(req.id, "BAD_REQUEST", "data required")
        end
        local mode = trim(args.mode)
        if mode ~= "truncate" and mode ~= "append" then
            mode = "append"
        end
        local encoding = trim(args.encoding)
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

    elseif cmd == "set_settings" then
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

    elseif cmd == "get_allowlist" then
        return responses.ok(req.id, { allowlist = list_allowlist() })

    elseif cmd == "scan_apps" then
        local apps, meta = scan_apps(ctx, ctx.ADMIN_APP_ID)
        return responses.ok(req.id, { apps = apps, meta = meta })

    elseif cmd == "set_policy" then
        local app_id2 = args.app_id
        local pol = args.policy
        local ok, err = policy.set_policy(app_id2, pol)
        if not ok then
            return responses.error(req.id, "BAD_REQUEST", err or "invalid policy")
        end
        return responses.ok(req.id, { ok = true })

    elseif cmd == "get_logs" then
        local stats = logmod.get_logs()
        local exec_logs = {}
        if logmod.get_exec_logs then
            exec_logs = logmod.get_exec_logs()
        end
        return responses.ok(req.id, { stats = stats, exec = exec_logs })

    elseif cmd == "clear_logs" then
        logmod.clear_logs()
        if logmod.clear_exec_logs then
            logmod.clear_exec_logs()
        end
        return responses.ok(req.id, { ok = true })

    elseif cmd == "set_allowlist" then
        local list = args.allowlist
        if type(list) ~= "table" then
            return responses.error(req.id, "BAD_REQUEST", "allowlist must be a table")
        end
        allowlist.set_list(list)
        return responses.ok(req.id, { ok = true })
    end

    return responses.error(req.id, "BAD_REQUEST", "Unknown management cmd: " .. tostring(cmd))
end

return M
