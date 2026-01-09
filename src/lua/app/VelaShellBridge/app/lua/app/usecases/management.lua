-- app/usecases/management.lua
-- Management commands for IPC.

local policy = require("app.domain.policy")
local logmod = require("app.domain.log")
local allowlist = require("app.domain.allowlist")
local appscan = require("app.domain.app_scan")
local settings = require("app.domain.settings")
local responses = require("app.core.ipc_responses")

local M = {}

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
