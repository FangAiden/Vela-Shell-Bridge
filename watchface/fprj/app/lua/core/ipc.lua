-- core/ipc.lua
-- 极简文件 IPC 守护进程
-- 协议：每个 app 固定 2 个文件
--   ipc_in.json  ← JS 写请求（文件存在=有请求）
--   ipc_out.json ← Lua 写响应

local config    = require("su_config")
local fs        = require("util.fs_util")
local str       = require("util.str")
local ulog      = require("util.log")
local allowlist = require("domain.allowlist")
local logmod    = require("domain.log")
local policy    = require("domain.policy")
local settings  = require("domain.settings")
local router    = require("core.ipc_router")
local JSON      = require("core.json")
local execmod   = require("domain.exec")

local M = {}

local log = ulog.create("ipc")

-- GC configuration
local GC_INTERVAL_TICKS = 100  -- Run GC every 100 ticks (~30 seconds at 300ms interval)
local gc_tick_counter = 0

-- 路径配置
local QUICKAPP_BASE = str.trim_trailing_slashes(config.QUICKAPP_BASE or "/data/files")
local ADMIN_APP_ID = config.ADMIN_APP_ID or ""

local IPC_CTX = {
    ADMIN_APP_ID     = ADMIN_APP_ID,
    QUICKAPP_BASE    = QUICKAPP_BASE,
    APPS_JSON        = config.APPS_JSON,
    APP_INSTALL_BASE = config.APP_INSTALL_BASE,
}

-- Dirty stores to flush at end of each tick
local stores = { policy, settings, logmod, allowlist }

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------

local function write_json_file(path, obj)
    local txt = JSON.encode(obj)
    return fs.write_file(path, txt)
end

local function normalize_base(path)
    return str.trim_trailing_slashes(tostring(path or ""))
end

function M.get_quickapp_base()
    return QUICKAPP_BASE
end

function M.set_quickapp_base(path)
    local base = normalize_base(path)
    if base == "" then
        return false, "empty quickapp base"
    end

    QUICKAPP_BASE = base
    IPC_CTX.QUICKAPP_BASE = base

    if type(config.set_quickapp_base) == "function" then
        config.set_quickapp_base(base)
    else
        config.QUICKAPP_BASE = base
    end
    IPC_CTX.APP_INSTALL_BASE = config.APP_INSTALL_BASE

    return true, base
end

----------------------------------------------------------------------
-- 扫描单个 app（带重试）
----------------------------------------------------------------------

local function scan_app(app_id)
    local app_dir = QUICKAPP_BASE .. "/" .. app_id
    local in_path = app_dir .. "/ipc_in.json"
    local out_path = app_dir .. "/ipc_out.json"

    -- 检查是否有请求
    if not fs.file_exists(in_path) then return end

    -- 读取请求（带重试，避免竞态条件）
    -- 注意：先读取完成后再删除，避免重试时文件已被删除
    local req = nil
    local raw_content = nil
    for attempt = 1, 3 do
        raw_content = fs.read_file(in_path)
        if raw_content and raw_content ~= "" then
            local ok, obj = pcall(JSON.decode, raw_content)
            if ok and obj then
                req = obj
                break
            end
        end
        -- 等待一小段时间后重试
        if attempt < 3 then
            local start = os.clock()
            while os.clock() - start < 0.05 do end  -- ~50ms delay
        end
    end

    -- 读取成功或所有重试完成后再删除请求文件（避免重复处理）
    fs.remove_file(in_path)

    if not req then
        log("Invalid request from " .. app_id .. " after retries")
        if raw_content then
            log("raw content (first 200): " .. tostring(raw_content):sub(1, 200))
        end
        return
    end

    -- 确保 req.id 存在
    local req_id = req.id
    if not req_id or req_id == "" then
        req_id = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
        req.id = req_id
    end

    -- 路由处理
    local ok, resp = pcall(router.route_request, IPC_CTX, app_id, req)
    if not ok then
        log("route_request error: " .. tostring(resp))
        resp = {
            id = req_id,
            ok = false,
            error = { code = "INTERNAL_ERROR", message = tostring(resp) }
        }
    end

    -- 写响应
    if resp then
        write_json_file(out_path, resp)
    end
end

----------------------------------------------------------------------
-- 每轮运行
----------------------------------------------------------------------

function M.run_once()
    -- 1. Admin app 始终检查
    if ADMIN_APP_ID ~= "" then
        scan_app(ADMIN_APP_ID)
    end

    -- 2. 检查所有 allowlist 中的 app
    local list = allowlist.get_all()
    if list then
        for app_id, enabled in pairs(list) do
            if enabled and app_id ~= ADMIN_APP_ID then
                scan_app(app_id)
            end
        end
    end

    -- 3. Flush dirty stores
    for _, s in ipairs(stores) do
        if s.save_if_dirty then
            s.save_if_dirty()
        end
    end

    -- 4. Periodic GC for session/CWD cleanup (every GC_INTERVAL_TICKS)
    gc_tick_counter = gc_tick_counter + 1
    if gc_tick_counter >= GC_INTERVAL_TICKS then
        gc_tick_counter = 0
        -- Build list of valid app IDs (admin + allowlist)
        local valid_ids = { ADMIN_APP_ID }
        local all_apps = allowlist.get_all()
        if all_apps then
            for app_id, enabled in pairs(all_apps) do
                if enabled then
                    valid_ids[#valid_ids + 1] = app_id
                end
            end
        end
        -- Clean up stale session policies and CWD entries
        if policy.gc_session then
            pcall(policy.gc_session, valid_ids)
        end
        if execmod.gc_cwd_map then
            pcall(execmod.gc_cwd_map, valid_ids)
        end
    end
end

return M
