-- VelaShellBridge main entry point
-- 重载器对用户代码透明：自动追踪顶层对象和 lvgl.Timer，重载时统一清理

-- Fix package.path: add the directory this file lives in
do
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*[/\\])") or "./"
        local sep = package.config:sub(1, 1) or "/"
        local pattern = dir .. "?.lua;" .. dir .. "?" .. sep .. "init.lua;"
        if not package.path:find(pattern, 1, true) then
            package.path = pattern .. package.path
        end
    end
end

local lvgl = require("lvgl")
local JSON = require("core.json")

local config   = require("su_config")
local ctx      = require("core.context")
local ipc      = require("core.ipc")
local policy   = require("domain.policy")
local logmod   = require("domain.log")
local allowlst = require("domain.allowlist")
local settings = require("domain.settings")
local app_scan = require("domain.app_scan")
local num      = require("util.num")

-------------------------------------------------
-- Log buffer
-------------------------------------------------
local log_lines = {}
local log_view = nil

local function refresh_log_view()
    if log_view then
        pcall(function() log_view:set { text = table.concat(log_lines, "\n") } end)
    end
end

ctx.log_fn = function(msg)
    local ts = os.date("%H:%M:%S")
    local line = "[" .. ts .. "] " .. tostring(msg)
    log_lines[#log_lines + 1] = line
    if #log_lines > 100 then table.remove(log_lines, 1) end
    refresh_log_view()
    print("[SU]", line)
end

local function append_log(msg) ctx.log_fn(msg) end

local function clear_log()
    log_lines = {}
    if log_view then
        pcall(function() log_view:set { text = "" } end)
    end
end

-------------------------------------------------
-- Init daemon state
-------------------------------------------------
local function init_daemon_state()
    local ok, err = pcall(function()
        settings.load()
        policy.load()
        logmod.load()
        allowlst.load()
    end)
    if not ok then
        append_log("Init failed: " .. tostring(err))
    else
        append_log("Daemon state loaded")
    end
end

-------------------------------------------------
-- UI
-------------------------------------------------
local screen_w = lvgl.HOR_RES()
local screen_h = lvgl.VER_RES()
local diameter = math.min(screen_w, screen_h)
local safe_size = diameter - 40
if safe_size < 100 then safe_size = diameter end

local root = lvgl.Object(nil, {
    w = screen_w, h = screen_h,
    align = lvgl.ALIGN.CENTER,
    bg_color = 0x000000, border_width = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local time_label = lvgl.Label(root, {
    text = "--:--:--",
    text_color = 0xCCCCCC,
    align = lvgl.ALIGN.TOP_MID, y = 6,
})

local btn_toggle = lvgl.Label(root, {
    text = ctx.enabled and "[SU: ON]" or "[SU: OFF]",
    text_color = 0xCCCCCC,
    align = lvgl.ALIGN.TOP_MID, y = 40,
})
btn_toggle:add_flag(lvgl.FLAG.CLICKABLE)

log_view = lvgl.Label(root, {
    w = safe_size - 20,
    h = math.floor(safe_size * 0.55),
    text = "",
    text_color = 0xEEEEEE, bg_color = 0x202020,
    align = lvgl.ALIGN.CENTER,
    long_mode = lvgl.LABEL.LONG_WRAP,
})
ctx.log_view = log_view

local btn_bar = lvgl.Object(root, {
    w = 310, h = 40,
    bg_color = 0x000000, border_width = 0,
    align = lvgl.ALIGN.BOTTOM_MID, y = -40,
})
btn_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

local btn_scan = lvgl.Label(btn_bar, { text = "[Scan]", text_color = 0xCCCCCC, align = lvgl.ALIGN.LEFT_MID })
btn_scan:add_flag(lvgl.FLAG.CLICKABLE)

local btn_policies = lvgl.Label(btn_bar, { text = "[Policies]", text_color = 0xCCCCCC, align = lvgl.ALIGN.CENTER })
btn_policies:add_flag(lvgl.FLAG.CLICKABLE)

local btn_clear = lvgl.Label(btn_bar, { text = "[Clear]", text_color = 0xCCCCCC, align = lvgl.ALIGN.RIGHT_MID })
btn_clear:add_flag(lvgl.FLAG.CLICKABLE)

-------------------------------------------------
-- Button handlers
-------------------------------------------------
btn_scan:onevent(lvgl.EVENT.CLICKED, function()
    append_log("[Scan] Dir = " .. config.QUICKAPP_BASE)
    local apps = app_scan.scan_all_apps(config.QUICKAPP_BASE)
    append_log("Found " .. #apps .. " apps")
    append_log(JSON.encode(apps))
end)

btn_policies:onevent(lvgl.EVENT.CLICKED, function()
    append_log("[Policies]")
    append_log(JSON.encode(policy.get_all_policies()))
end)

btn_clear:onevent(lvgl.EVENT.CLICKED, function()
    clear_log()
    append_log("Log cleared")
end)

btn_toggle:onevent(lvgl.EVENT.CLICKED, function()
    ctx.enabled = not ctx.enabled
    btn_toggle:set { text = ctx.enabled and "[SU: ON]" or "[SU: OFF]" }
    append_log("SU Daemon " .. (ctx.enabled and "ENABLED" or "DISABLED"))
end)

-------------------------------------------------
-- Daemon timer
-------------------------------------------------
init_daemon_state()

local period_ms = num.clamp_int(ctx.daemon_period_ms, 50, 2000, 300)
local current_period_ms = period_ms
local last_time_str = ""

lvgl.Timer {
    period = period_ms,
    cb = function(self)
        local t = os.date("%H:%M:%S")
        if t ~= last_time_str then
            last_time_str = t
            time_label:set { text = t }
        end

        if not ctx.enabled then return end

        local desired = num.clamp_int(ctx.daemon_period_ms, 50, 2000, current_period_ms)
        if desired ~= current_period_ms then
            current_period_ms = desired
            pcall(function() self:set({ period = desired }) end)
            append_log("Daemon period -> " .. desired .. " ms")
        end

        pcall(ipc.run_once)
    end
}

append_log("UI ready (" .. period_ms .. " ms)")
