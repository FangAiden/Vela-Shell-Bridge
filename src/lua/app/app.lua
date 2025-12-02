local lvgl = require("lvgl")

-------------------------------------------------
-- 1. Init JSON
-------------------------------------------------
local ok_json, JSON_mod = pcall(require, "app.util.json_util")
if ok_json and JSON_mod then
    _G.JSON = JSON_mod
elseif not _G.JSON then
    error("JSON module not found: please ensure app/util/json_util.lua exists and returns JSON")
end

-------------------------------------------------
-- 2. SU daemon modules
-------------------------------------------------
local config   = require("app.config")
local ipc      = require("app.core.ipc")
local policy   = require("app.domain.policy")
local logmod   = require("app.domain.log")
local allowlst = require("app.domain.allowlist")
local app_scan = require("app.domain.app_scan")

-------------------------------------------------
-- 2.1 全局开关：控制整套 SU 守护逻辑
-------------------------------------------------
_G.SU_ENABLED = (_G.SU_ENABLED ~= false)  -- 默认开启
local su_timer = nil                      -- 保存定时器引用（如果以后想暂停/恢复）

-------------------------------------------------
-- 3. Log buffer helpers
-------------------------------------------------
local log_lines = {}

-- 全局日志视图引用，由 UI 初始化时赋值
_G.SU_LOG_VIEW = _G.SU_LOG_VIEW or nil

-- 真正干活的日志函数，挂到全局
function _G.SU_LOG(msg)
    local ts = os.date("%H:%M:%S")
    local line = "[" .. ts .. "] " .. tostring(msg)

    log_lines[#log_lines + 1] = line
    if #log_lines > 100 then
        table.remove(log_lines, 1)
    end

    -- 有 UI 就刷新 UI，没有就至少 print 一下
    if _G.SU_LOG_VIEW and _G.SU_LOG_VIEW.set then
        _G.SU_LOG_VIEW:set { text = table.concat(log_lines, "\n") }
    end

    -- 顺便打到串口，方便看
    print("[SU]", line)
end

-- UI 内部继续用的包装函数（保持原调用不改太多）
local function append_log(log_view, msg)
    -- 把当前 log_view 注册成全局视图（只要传进来，就记住它）
    if log_view and log_view ~= _G.SU_LOG_VIEW then
        _G.SU_LOG_VIEW = log_view
    end
    _G.SU_LOG(msg)
end

local function clear_log(log_view)
    log_lines = {}
    if log_view or _G.SU_LOG_VIEW then
        (log_view or _G.SU_LOG_VIEW):set { text = "" }
    end
end

-------------------------------------------------
-- 4. Init daemon state
-------------------------------------------------
local function init_daemon_state(log_view)
    local ok, err = pcall(function()
        policy.load()
        logmod.load()
        allowlst.load()
    end)
    if not ok then
        append_log(log_view, "Init daemon state failed: " .. tostring(err))
    else
        append_log(log_view, "Daemon state loaded")
    end
end

-------------------------------------------------
-- 5. Start SU daemon (lvgl.Timer)
--    ★ 这里尊重全局开关 _G.SU_ENABLED
-------------------------------------------------
local function start_daemon(log_view)
    init_daemon_state(log_view)
    append_log(log_view, "SU Daemon starting...")

    local period_ms = 300

    su_timer = lvgl.Timer {
        period = period_ms,
        paused = false,
        cb = function()
            -- 统一总开关：关闭时，整套 IPC/exec 逻辑不执行
            if not _G.SU_ENABLED then
                return
            end

            local ok, err = pcall(function()
                ipc.run_once()
            end)
            if not ok then
                append_log(log_view, "ipc.run_once error: " .. tostring(err))
            end
        end
    }

    append_log(log_view, "SU Daemon running (" .. period_ms .. " ms)")
end

-------------------------------------------------
-- 6. Build UI: round screen + log box + 3 labels as buttons + time label + Switch
-------------------------------------------------
local function create_ui()
    local screen_w = lvgl.HOR_RES()
    local screen_h = lvgl.VER_RES()
    local diameter = math.min(screen_w, screen_h)

    -- Slightly smaller than circle safe area
    local safe_size = diameter - 40
    if safe_size < 100 then safe_size = diameter end

    local root = lvgl.Object(nil, {
        w = screen_w,
        h = screen_h,
        align = lvgl.ALIGN.CENTER,
        border_width = 0,
    })
    root:clear_flag(lvgl.FLAG.SCROLLABLE)
    root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

    -------------------------------------------------
    -- Top time label
    -------------------------------------------------
    local time_label = lvgl.Label(root, {
        text = "--:--:--",
        align = lvgl.ALIGN.TOP_MID,
        y = 6,
    })

    -------------------------------------------------
    -- 全局开关按钮
    -------------------------------------------------
    local btn4 = lvgl.Label(root, {
        text = _G.SU_ENABLED and "[SU: ON]" or "[SU: OFF]",
        align = lvgl.ALIGN.TOP_MID,
        y = 40,
    })
    btn4:add_flag(lvgl.FLAG.CLICKABLE)

    -------------------------------------------------
    -- Center log box
    -------------------------------------------------
    local log_w = safe_size - 20
    local log_h = math.floor(safe_size * 0.55)

    local log_view = lvgl.Textarea(root, {
        w = log_w,
        h = log_h,
        text = "",
        bg_color = 0x202020,
        font_size = 16,
        align = lvgl.ALIGN.CENTER,
        text_color = "#eeeeee"
    })

    -------------------------------------------------
    -- Bottom button bar with 3 labels (as buttons)
    -------------------------------------------------
    local btn_bar = lvgl.Object(root, {
        w = 310,
        h = 40,
        align = lvgl.ALIGN.BOTTOM_MID,
        y = -40,
    })
    btn_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

    -- Left button
    local btn1 = lvgl.Label(btn_bar, {
        text = "[Scan]",
        align = lvgl.ALIGN.LEFT_MID,
        x = 0,
    })
    -- Middle button
    local btn2 = lvgl.Label(btn_bar, {
        text = "[Policies]",
        align = lvgl.ALIGN.CENTER,
        x = 0,
    })
    -- Right button
    local btn3 = lvgl.Label(btn_bar, {
        text = "[Clear]",
        align = lvgl.ALIGN.RIGHT_MID,
        x = 0,
    })

    local function make_button(label)
        label:add_flag(lvgl.FLAG.CLICKABLE)
    end

    make_button(btn1)
    make_button(btn2)
    make_button(btn3)

    return root, time_label, log_view, btn1, btn2, btn3, btn4
end

-------------------------------------------------
-- 7. Wire button behaviors
-------------------------------------------------
local function wire_buttons(btn1, btn2, btn3, btn4, log_view)
    -- Button 1: scan apps
    btn1:onevent(lvgl.EVENT.CLICKED, function(obj, code)
        append_log(log_view, "[Button] Scan apps")
        append_log(log_view, "Dir = " .. config.QUICKAPP_BASE)
        local apps = app_scan.scan_all_apps(config.QUICKAPP_BASE)
        append_log(log_view, "Found apps: " .. tostring(#apps))
        append_log(log_view, "Apps = " .. JSON.encode(apps))
    end)

    -- Button 2: show policies
    btn2:onevent(lvgl.EVENT.CLICKED, function(obj, code)
        append_log(log_view, "[Button] Show policies")
        local policies = policy.get_all_policies()
        append_log(log_view, "Policies = " .. JSON.encode(policies))
    end)

    -- Button 3: clear log
    btn3:onevent(lvgl.EVENT.CLICKED, function(obj, code)
        clear_log(log_view)
        append_log(log_view, "[Button] Log cleared")
    end)

    -- Button 4: SU 总开关
    btn4:onevent(lvgl.EVENT.CLICKED, function(obj, code)
        _G.SU_ENABLED = not _G.SU_ENABLED

        if _G.SU_ENABLED then
            btn4:set { text = "[SU: ON]" }
            append_log(log_view, "[Switch] SU Daemon ENABLED")
        else
            btn4:set { text = "[SU: OFF]" }
            append_log(log_view, "[Switch] SU Daemon DISABLED")
        end

        -- 如果你想完全暂停定时器，也可以在这里这样写：
        -- if su_timer then
        --     su_timer:set { paused = (not _G.SU_ENABLED) }
        -- end
        -- 目前我们只通过 if _G.SU_ENABLED then ipc.run_once() end 来控制逻辑执行。
    end)
end

-------------------------------------------------
-- 8. Entry: build(api), time via api.on_tick
-------------------------------------------------
local M = {}

function M.build(api)
    local root, time_label, log_view, btn1, btn2, btn3, btn4 = create_ui()

    wire_buttons(btn1, btn2, btn3, btn4, log_view)
    start_daemon(log_view)

    -- Update time from api.on_tick (simulator)
    if api and api.on_tick then
        api.on_tick(function(epoch)
            local t = os.date("%H:%M:%S", epoch)
            if time_label and time_label.set then
                time_label:set { text = t }
            end
        end)
    else
        -- Fallback: internal timer
        lvgl.Timer {
            period = 1000,
            paused = false,
            cb = function()
                local t = os.date("%H:%M:%S")
                if time_label and time_label.set then
                    time_label:set { text = t }
                end
            end
        }
    end

    append_log(log_view, "UI ready on simulator")

    return root
end

return M
