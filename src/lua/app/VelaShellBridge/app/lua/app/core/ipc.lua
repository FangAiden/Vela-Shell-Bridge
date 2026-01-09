-- app/core/ipc.lua
-- 文件 IPC 守护进程
-- 更新：支持 exec 的 sync 模式和 kill 命令

local config    = require("app.config")
local fs        = require("app.util.fs_util")
local allowlist = require("app.domain.allowlist")
local logmod    = require("app.domain.log")
local policy    = require("app.domain.policy")
local settings  = require("app.domain.settings")
local router    = require("app.core.ipc_router")
local responses = require("app.core.ipc_responses")

local JSON = require("app.core.json")

local M = {}

local function trim_trailing_slashes(p)
    if type(p) ~= "string" then
        return ""
    end
    return (p:gsub("/+$", ""))
end

local function normalize_quickapp_paths()
    local admin = config.ADMIN_APP_ID
    if type(admin) ~= "string" then
        admin = ""
    end

    local base = trim_trailing_slashes(config.QUICKAPP_BASE or "")
    if base == "" then
        base = "/data/files"
    end

    if admin ~= "" then
        local suffix = "/" .. admin
        if base:sub(-#suffix) == suffix then
            local root = base:sub(1, #base - #suffix)
            root = trim_trailing_slashes(root)
            if root == "" then
                root = "/data/files"
            end
            return root, base, admin
        end
        return base, (base .. suffix), admin
    end

    return base, (base .. "/"), admin
end

local QUICKAPP_ROOT, ADMIN_FILES_DIR, ADMIN_APP_ID = normalize_quickapp_paths()
local QUICKAPP_BASE = QUICKAPP_ROOT
local IPC_CTX = {
    ADMIN_APP_ID = ADMIN_APP_ID,
    QUICKAPP_ROOT = QUICKAPP_ROOT,
    ADMIN_FILES_DIR = ADMIN_FILES_DIR,
    QUICKAPP_BASE = QUICKAPP_BASE,
    APPS_JSON = config.APPS_JSON,
    APP_INSTALL_BASE = config.APP_INSTALL_BASE,
}

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
        local resp = responses.error(id, "BAD_REQUEST", "invalid json: " .. tostring(err))
        write_json_file(resp_path, resp)
        fs.remove_file(req_path)
        return
    end

    req.id = req.id or id

    local ok, resp = pcall(router.route_request, IPC_CTX, app_id, req)
    if not ok then
        log("route_request error: " .. tostring(resp))
        resp = responses.error(req.id, "INTERNAL_ERROR", tostring(resp))
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
    if settings.save_if_dirty then
        settings.save_if_dirty()
    end
    if logmod.save_if_any_dirty then
        logmod.save_if_any_dirty()
    elseif logmod.save_if_dirty then
        logmod.save_if_dirty()
        if logmod.save_exec_if_dirty then
            logmod.save_exec_if_dirty()
        end
    end
    allowlist.save_if_dirty()
end

return M
