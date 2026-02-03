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
-- UI: Theme
-------------------------------------------------
local C = {
    BG         = 0x000000,
    CARD       = 0x111111,
    CARD_EDGE  = 0x2a2a2a,
    GREEN      = 0x00d36f,
    GREEN_DIM  = 0x0f2618,
    RED        = 0xff5555,
    RED_DIM    = 0x2a0f0f,
    TERM_TEXT  = 0x50fa7b,
    TEXT       = 0xf2f2f2,
    TEXT_DIM   = 0x7a7a7a,
    BTN_BG     = 0x1a1a1a,
    BTN_EDGE   = 0x333333,
}

-------------------------------------------------
-- UI: Layout
-------------------------------------------------
local screen_w = lvgl.HOR_RES()
local screen_h = lvgl.VER_RES()
local diameter = math.min(screen_w, screen_h)
local safe = diameter - 40
if safe < 100 then safe = diameter end

-- Root
local root = lvgl.Object(nil, {
    w = screen_w, h = screen_h,
    align = lvgl.ALIGN.CENTER,
    bg_color = C.BG, bg_opa = 255,
    border_width = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

-- Top bar: time left + status right
local top_bar = lvgl.Object(root, {
    w = 250, h = 34,
    align = lvgl.ALIGN.TOP_MID, y = 50,
    bg_color = C.BG, border_width = 0,
})
top_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Time (left side of top bar)
local time_label = lvgl.Label(top_bar, {
    text = "--:--",
    text_color = C.TEXT_DIM,
    align = lvgl.ALIGN.LEFT_MID, x = 4,
})

-- Status pill (right side of top bar, clickable)
local status_pill = lvgl.Object(top_bar, {
    w = 130, h = 30,
    align = lvgl.ALIGN.RIGHT_MID,
    bg_color = C.GREEN_DIM, bg_opa = 255,
    radius = 15,
    border_width = 1, border_color = C.GREEN,
})
status_pill:clear_flag(lvgl.FLAG.SCROLLABLE)
status_pill:add_flag(lvgl.FLAG.CLICKABLE)

local status_label = lvgl.Label(status_pill, {
    text = "SU ON",
    text_color = C.GREEN,
    align = lvgl.ALIGN.CENTER,
})

-- Log terminal card (scrollable)
local log_card = lvgl.Object(root, {
    w = safe - 20, h = math.floor(safe * 0.50),
    align = lvgl.ALIGN.CENTER, y = 0,
    bg_color = C.CARD, bg_opa = 255,
    radius = 16,
    border_width = 1, border_color = C.CARD_EDGE,
    pad_left = 10, pad_right = 10, pad_top = 8, pad_bottom = 8,
})
log_card:clear_flag(lvgl.FLAG.SCROLLABLE)

log_view = lvgl.Textarea(log_card, {
    w = safe - 40,
    h = math.max(20, math.floor(safe * 0.50) - 16),
    text = "",
    text_color = C.TERM_TEXT,
    align = lvgl.ALIGN.TOP_LEFT,
    bg_opa = 0,
    border_width = 0,
    pad_left = 0, pad_right = 0, pad_top = 0, pad_bottom = 0,
})
log_view:add_flag(lvgl.FLAG.SCROLLABLE)
ctx.log_view = log_view

-- Bottom button bar
local btn_bar = lvgl.Object(root, {
    w = 310, h = 95,
    bg_color = C.BG, border_width = 0,
    align = lvgl.ALIGN.BOTTOM_MID, y = -52,
})
btn_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Pill button factory
local function make_btn(parent, text, align_mode)
    local pill = lvgl.Object(parent, {
        w = 84, h = 34,
        align = align_mode,
        bg_color = C.BTN_BG, bg_opa = 255,
        radius = 17,
        border_width = 1, border_color = C.BTN_EDGE,
    })
    pill:clear_flag(lvgl.FLAG.SCROLLABLE)
    pill:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(pill, {
        text = text,
        text_color = C.TEXT,
        align = lvgl.ALIGN.CENTER,
    })
    return pill
end

local btn_scan     = make_btn(btn_bar, "Scan",   lvgl.ALIGN.LEFT_MID)
local btn_policies = make_btn(btn_bar, "Policy", lvgl.ALIGN.CENTER)
local btn_clear    = make_btn(btn_bar, "Clear",  lvgl.ALIGN.RIGHT_MID)

-------------------------------------------------
-- UI: Status update helper
-------------------------------------------------
local function update_status_ui()
    if ctx.enabled then
        pcall(function() status_pill:set { bg_color = C.GREEN_DIM, border_color = C.GREEN } end)
        pcall(function() status_dot:set  { bg_color = C.GREEN } end)
        pcall(function() status_label:set { text = "SU Daemon" } end)
    else
        pcall(function() status_pill:set { bg_color = C.RED_DIM, border_color = C.RED } end)
        pcall(function() status_dot:set  { bg_color = C.RED } end)
        pcall(function() status_label:set { text = "SU Stopped" } end)
    end
end

-------------------------------------------------
-- Button handlers
-------------------------------------------------
btn_scan:onevent(lvgl.EVENT.CLICKED, function()
    append_log("[Scan] " .. config.QUICKAPP_BASE)
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

status_pill:onevent(lvgl.EVENT.CLICKED, function()
    ctx.enabled = not ctx.enabled
    update_status_ui()
    append_log("SU Daemon " .. (ctx.enabled and "ENABLED" or "DISABLED"))
end)

-------------------------------------------------
-- Daemon timer
-------------------------------------------------
init_daemon_state()
update_status_ui()

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
            append_log("Period -> " .. desired .. " ms")
        end

        pcall(ipc.run_once)
    end
}

append_log("Ready (" .. period_ms .. " ms)")
