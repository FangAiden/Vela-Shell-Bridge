-- app/core/ipc.lua
-- 文件 IPC 守护进程

local config    = require("su_config")
local fs        = require("util.fs_util")
local str       = require("util.str")
local num       = require("util.num")
local ulog      = require("util.log")
local ctx       = require("core.context")
local allowlist = require("domain.allowlist")
local logmod    = require("domain.log")
local policy    = require("domain.policy")
local settings  = require("domain.settings")
local router    = require("core.ipc_router")
local responses = require("core.ipc_responses")

local JSON = require("core.json")

local M = {}

local log = ulog.create("ipc")

local function normalize_quickapp_paths()
    local admin = config.ADMIN_APP_ID
    if type(admin) ~= "string" then
        admin = ""
    end

    local base = str.trim_trailing_slashes(config.QUICKAPP_BASE or "")
    if base == "" then
        base = "/data/files"
    end

    if admin ~= "" then
        local suffix = "/" .. admin
        if base:sub(-#suffix) == suffix then
            local root = base:sub(1, #base - #suffix)
            root = str.trim_trailing_slashes(root)
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

-- IPC optimization: fixed-slot mailbox + per-app pending marker.
local IPC_SLOT_COUNT = num.clamp_int(config.IPC_SLOT_COUNT, 1, 8, 2)
local IPC_PENDING_FILE = "ipc_pending"
local IPC_SLOT_REQ_FMT = "ipc_slot_%d.req.json"
local IPC_SLOT_READY_FMT = "ipc_slot_%d.ready"

local IPC_COLD_BASE_MS = num.clamp_int(config.IPC_COLD_BASE_MS, 50, 20000, 200)
local IPC_COLD_MAX_MS = num.clamp_int(config.IPC_COLD_MAX_MS, 200, 60000, 5000)
local IPC_IDLE_LEVEL_MAX = 8

local TICK = 0
local APP_STATE = {}
local GC_INTERVAL_TICKS = 60

-- Dirty stores to flush at end of each tick.
local stores = { policy, settings, logmod, allowlist }

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

local function read_trim(path)
    local txt = fs.read_file(path)
    if not txt then return "" end
    return str.trim(txt)
end

local function daemon_period_ms()
    return num.clamp_int(ctx.daemon_period_ms, 50, 2000, 300)
end

local function ms_to_ticks(ms, period_ms)
    if not ms or ms <= 0 then return 1 end
    local t = math.floor((ms + period_ms - 1) / period_ms)
    if t < 1 then t = 1 end
    return t
end

local function cold_delay_ms(idle_level, period_ms)
    local base = IPC_COLD_BASE_MS
    if base < period_ms * 2 then
        base = period_ms * 2
    end
    local exp = (idle_level or 0) - 1
    if exp < 0 then exp = 0 end
    local delay = base * (2 ^ exp)
    if delay > IPC_COLD_MAX_MS then
        delay = IPC_COLD_MAX_MS
    end
    return delay
end

----------------------------------------------------------------------
-- 处理单个请求文件
----------------------------------------------------------------------

local function process_slot(app_id, app_dir, slot_index)
    local ready_path = app_dir .. "/" .. string.format(IPC_SLOT_READY_FMT, slot_index)
    if not fs.file_exists(ready_path) then
        return false, false
    end

    local ready_id = str.trim(fs.read_file(ready_path) or "")
    if ready_id == "" then
        return false, true
    end

    local req_path = app_dir .. "/" .. string.format(IPC_SLOT_REQ_FMT, slot_index)
    local req, err = read_json_file(req_path)
    if not req then
        return false, true
    end

    local req_id = req.id ~= nil and str.trim(tostring(req.id)) or ""
    if req_id == "" then
        req.id = ready_id
        req_id = ready_id
    end

    if req_id ~= ready_id then
        return false, true
    end

    local resp_path = app_dir .. "/ipc_response_" .. req_id .. ".json"

    local ok, resp = pcall(router.route_request, IPC_CTX, app_id, req)
    if not ok then
        log("route_request error: " .. tostring(resp))
        resp = responses.error(req_id, "INTERNAL_ERROR", tostring(resp))
    end

    if resp then
        write_json_file(resp_path, resp)
    end

    local cur = str.trim(fs.read_file(ready_path) or "")
    if cur == ready_id then
        fs.remove_file(ready_path)
    end

    return true, false
end

----------------------------------------------------------------------
-- 扫描 app
----------------------------------------------------------------------

local function get_state(app_id)
    local st = APP_STATE[app_id]
    if st then return st end
    st = {
        next_tick = 0,
        idle_level = 0,
        last_pending = "",
        force_scan = false,
    }
    APP_STATE[app_id] = st
    return st
end

local function scan_app(app_id, st)
    local app_dir = QUICKAPP_BASE .. "/" .. app_id
    local pending_path = app_dir .. "/" .. IPC_PENDING_FILE
    local token = read_trim(pending_path)

    if token == "" then
        st.force_scan = false
        st.last_pending = ""
        return false
    end

    if token == st.last_pending and (not st.force_scan) then
        return false
    end

    local any_ready = false
    local did_work = false
    local had_error = false

    for i = 0, IPC_SLOT_COUNT - 1 do
        local ready_path = app_dir .. "/" .. string.format(IPC_SLOT_READY_FMT, i)
        if fs.file_exists(ready_path) then
            any_ready = true
            local ok, err = process_slot(app_id, app_dir, i)
            if ok then
                did_work = true
            end
            if err then
                had_error = true
            end
        end
    end

    if not any_ready then
        st.force_scan = true
        return false
    end

    local remaining_ready = false
    for i = 0, IPC_SLOT_COUNT - 1 do
        local ready_path = app_dir .. "/" .. string.format(IPC_SLOT_READY_FMT, i)
        if fs.file_exists(ready_path) then
            remaining_ready = true
            break
        end
    end

    if remaining_ready or had_error then
        st.force_scan = true
        return did_work
    end

    st.force_scan = false
    st.last_pending = token
    return did_work
end

----------------------------------------------------------------------
-- APP_STATE GC: remove entries for apps no longer in allowlist
----------------------------------------------------------------------

local function gc_app_state()
    local list = allowlist.get_all() or {}
    for app_id, _ in pairs(APP_STATE) do
        if app_id ~= ADMIN_APP_ID and not list[app_id] then
            APP_STATE[app_id] = nil
        end
    end
end

----------------------------------------------------------------------
-- 每轮运行
----------------------------------------------------------------------

function M.run_once()
    TICK = TICK + 1
    local period_ms = daemon_period_ms()

    -- Admin app: always check (still cheap when idle).
    local admin_st = get_state(ADMIN_APP_ID)
    scan_app(ADMIN_APP_ID, admin_st)
    admin_st.idle_level = 0
    admin_st.next_tick = TICK + 1

    local list = allowlist.get_all()
    if list then
        for app_id, enabled in pairs(list) do
            if enabled and app_id ~= ADMIN_APP_ID then
                local st = get_state(app_id)
                if TICK >= (st.next_tick or 0) then
                    local did_work = scan_app(app_id, st)

                    local hot = did_work or st.force_scan == true
                    if hot then
                        st.idle_level = 0
                        st.next_tick = TICK + 1
                    else
                        local lvl = (st.idle_level or 0) + 1
                        if lvl > IPC_IDLE_LEVEL_MAX then
                            lvl = IPC_IDLE_LEVEL_MAX
                        end
                        st.idle_level = lvl
                        local delay_ms = cold_delay_ms(lvl, period_ms)
                        st.next_tick = TICK + ms_to_ticks(delay_ms, period_ms)
                    end
                end
            end
        end
    end

    -- APP_STATE GC
    if TICK % GC_INTERVAL_TICKS == 0 then
        gc_app_state()
    end

    -- Unified persistence flush
    for _, s in ipairs(stores) do
        if s.save_if_dirty then s.save_if_dirty() end
    end
end

return M
