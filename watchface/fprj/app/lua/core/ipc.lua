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

local M = {}

local log = ulog.create("ipc")

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

local function read_json_file(path)
    local txt = fs.read_file(path)
    if not txt or txt == "" then
        log("read_json_file: empty or nil content from " .. tostring(path))
        return nil
    end
    local ok, obj = pcall(JSON.decode, txt)
    if not ok then
        log("read_json_file: JSON decode failed: " .. tostring(obj))
        log("raw content (first 200): " .. tostring(txt):sub(1, 200))
        return nil
    end
    return obj
end

local function write_json_file(path, obj)
    local txt = JSON.encode(obj)
    return fs.write_file(path, txt)
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
    local req = nil
    for attempt = 1, 3 do
        req = read_json_file(in_path)
        if req then break end
        -- 等待一小段时间后重试
        if attempt < 3 then
            local start = os.clock()
            while os.clock() - start < 0.05 do end  -- ~50ms delay
        end
    end

    -- 立即删除请求文件（避免重复处理）
    fs.remove_file(in_path)

    if not req then
        log("Invalid request from " .. app_id .. " after retries")
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
end

return M
