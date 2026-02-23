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
local fs       = require("util.fs_util")
local str      = require("util.str")

-------------------------------------------------
-- Log buffer
-------------------------------------------------
local log_lines = {}
local log_view = nil
local log_wrap_chars = 56

local function refresh_log_view()
    if log_view then
        pcall(function() log_view:set { text = table.concat(log_lines, "\n") } end)
    end
end

local function wrap_line_by_chars(line, width)
    if type(line) ~= "string" then line = tostring(line or "") end
    if not width or width <= 0 or #line <= width then return line end
    local out = {}
    local i = 1
    while i <= #line do
        out[#out + 1] = line:sub(i, i + width - 1)
        i = i + width
    end
    return table.concat(out, "\n")
end

local function normalize_log_text(msg)
    local src = tostring(msg or "")
    src = src:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = wrap_line_by_chars(line, log_wrap_chars)
    end
    return table.concat(out, "\n")
end

ctx.log_fn = function(msg)
    -- Include date for cross-day log identification
    local ts = os.date("%m-%d %H:%M:%S")
    local line = normalize_log_text("[" .. ts .. "] " .. tostring(msg))
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
local short_edge = math.min(screen_w, screen_h)
local long_edge = math.max(screen_w, screen_h)
local screen_ratio = long_edge / math.max(short_edge, 1)

-- 胶囊屏（狭长屏）检测：优先匹配已知分辨率，兼容未来同类比例
local is_pill_screen = (screen_h > screen_w) and (
    (short_edge == 192 and long_edge == 490) or
    (short_edge == 212 and long_edge == 520) or
    (short_edge <= 220 and screen_ratio >= 2.0)
)

local ui = {
    status_on_text = "SU Daemon",
    status_off_text = "SU Stopped",
    btn_scan_text = "Scan",
    btn_policy_text = "Policy",
    btn_clear_text = "Clear",
}

if is_pill_screen then
    ui.content_w = screen_w - math.max(14, math.floor(screen_w * 0.10))
    ui.top_pad = math.max(10, math.floor(screen_h * 0.03))
    ui.bottom_pad = math.max(26, math.floor(screen_h * 0.07))
    ui.top_bar_h = 32
    ui.status_h = 28
    ui.status_w = math.max(84, math.floor(ui.content_w * 0.46))
    ui.status_radius = 14
    ui.log_radius = 12
    ui.btn_h = 34
    ui.btn_radius = 16
    ui.status_on_text = "SU ON"
    ui.status_off_text = "SU OFF"
    ui.btn_policy_text = "Rules"
else
    ui.content_w = math.max(140, math.min(screen_w - 18, safe))
    ui.top_pad = math.max(24, math.floor((screen_h - safe) * 0.5) + 10)
    ui.bottom_pad = math.max(24, math.floor((screen_h - safe) * 0.5) + 14)
    ui.top_bar_h = 34
    ui.status_h = 30
    ui.status_w = math.max(96, math.floor(ui.content_w * 0.50))
    ui.status_radius = 15
    ui.log_radius = 16
    ui.btn_h = 34
    ui.btn_radius = 17
end

ui.content_x = math.floor((screen_w - ui.content_w) / 2)
ui.gap_y = math.max(8, math.floor(screen_h * 0.02))
ui.top_bar_x = ui.content_x
ui.top_bar_y = ui.top_pad
ui.top_bar_w = ui.content_w
ui.time_x = 4
ui.time_y = math.max(2, math.floor((ui.top_bar_h - 20) / 2))
ui.status_x = math.max(0, ui.top_bar_w - ui.status_w)
ui.status_y = math.max(0, math.floor((ui.top_bar_h - ui.status_h) / 2))

ui.btn_bar_w = ui.content_w
ui.btn_bar_h = math.max(44, ui.btn_h + 12)
ui.btn_w = math.max(50, math.floor((ui.btn_bar_w - 20) / 3))
ui.btn_bar_x = ui.content_x
ui.btn_bar_y = screen_h - ui.bottom_pad - ui.btn_bar_h
ui.btn_y = math.max(0, math.floor((ui.btn_bar_h - ui.btn_h) / 2))
ui.btn_scan_x = 0
ui.btn_policy_x = math.floor((ui.btn_bar_w - ui.btn_w) / 2)
ui.btn_clear_x = math.max(0, ui.btn_bar_w - ui.btn_w)

ui.log_x = ui.content_x
ui.log_y = ui.top_bar_y + ui.top_bar_h + ui.gap_y
local log_bottom = ui.btn_bar_h + ui.bottom_pad + ui.gap_y
ui.log_h = screen_h - ui.log_y - log_bottom
ui.log_h = num.clamp_int(ui.log_h, 120, math.floor(screen_h * 0.70), math.floor(screen_h * 0.45))
ui.log_w = ui.content_w

-- 根据日志区域宽度粗略估算每行字符数，避免长日志撑出可视区
if ui.log_w and ui.log_w > 0 then
    log_wrap_chars = math.max(20, math.floor((ui.log_w - 20) / 7))
end

-- Root
local root = lvgl.Object(nil, {
    w = screen_w, h = screen_h,
    x = 0, y = 0,
    bg_color = C.BG, bg_opa = 255,
    border_width = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

-- Top bar: time left + status right (absolute position)
local top_bar = lvgl.Object(root, {
    w = ui.top_bar_w, h = ui.top_bar_h,
    x = ui.top_bar_x, y = ui.top_bar_y,
    bg_color = C.BG, border_width = 0,
})
top_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Time (left side of top bar)
local time_label = lvgl.Label(top_bar, {
    text = "--:--",
    text_color = C.TEXT_DIM,
    x = ui.time_x, y = ui.time_y,
})

-- Status pill (right side of top bar, clickable)
local status_pill = lvgl.Object(top_bar, {
    w = ui.status_w, h = ui.status_h,
    x = ui.status_x, y = ui.status_y,
    bg_color = C.GREEN_DIM, bg_opa = 255,
    radius = ui.status_radius,
    border_width = 1, border_color = C.GREEN,
})
status_pill:clear_flag(lvgl.FLAG.SCROLLABLE)
status_pill:add_flag(lvgl.FLAG.CLICKABLE)

local status_label = lvgl.Label(status_pill, {
    text = ui.status_on_text,
    text_color = C.GREEN,
    align = lvgl.ALIGN.CENTER,
})

-- Log terminal card (scrollable)
local log_card = lvgl.Object(root, {
    w = ui.log_w, h = ui.log_h,
    x = ui.log_x, y = ui.log_y,
    bg_color = C.CARD, bg_opa = 255,
    radius = ui.log_radius,
    border_width = 1, border_color = C.CARD_EDGE,
    pad_left = 10, pad_right = 10, pad_top = 8, pad_bottom = 8,
})
log_card:clear_flag(lvgl.FLAG.SCROLLABLE)

log_view = lvgl.Textarea(log_card, {
    w = math.max(20, ui.log_w - 20),
    h = math.max(20, ui.log_h - 16),
    text = "",
    text_color = C.TERM_TEXT,
    x = 0, y = 0,
    bg_opa = 0,
    border_width = 0,
    pad_left = 0, pad_right = 0, pad_top = 0, pad_bottom = 0,
})
log_view:add_flag(lvgl.FLAG.SCROLLABLE)
ctx.log_view = log_view

-- Bottom button bar
local btn_bar = lvgl.Object(root, {
    w = ui.btn_bar_w, h = ui.btn_bar_h,
    bg_color = C.BG, border_width = 0,
    x = ui.btn_bar_x, y = ui.btn_bar_y,
})
btn_bar:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Pill button factory
local function make_btn(parent, text, x)
    local pill = lvgl.Object(parent, {
        w = ui.btn_w, h = ui.btn_h,
        x = x, y = ui.btn_y,
        bg_color = C.BTN_BG, bg_opa = 255,
        radius = ui.btn_radius,
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

local btn_scan     = make_btn(btn_bar, ui.btn_scan_text, ui.btn_scan_x)
local btn_policies = make_btn(btn_bar, ui.btn_policy_text, ui.btn_policy_x)
local btn_clear    = make_btn(btn_bar, ui.btn_clear_text, ui.btn_clear_x)

-------------------------------------------------
-- UI: Status update helper
-------------------------------------------------
local function update_status_ui()
    if ctx.enabled then
        pcall(function() status_pill:set { bg_color = C.GREEN_DIM, border_color = C.GREEN } end)
        pcall(function() status_label:set { text = ui.status_on_text, text_color = C.GREEN } end)
    else
        pcall(function() status_pill:set { bg_color = C.RED_DIM, border_color = C.RED } end)
        pcall(function() status_label:set { text = ui.status_off_text, text_color = C.RED } end)
    end
end

local function parse_lines(text)
    local out = {}
    local src = tostring(text or "")
    src = src:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (src .. "\n"):gmatch("(.-)\n") do
        local s = str.trim(line)
        if s ~= "" then
            out[#out + 1] = s
        end
    end
    return out
end

local function parent_dir(path)
    if type(path) ~= "string" then return "" end
    return path:match("^(.*)/[^/]+$") or ""
end

local function find_admin_sandbox_dir()
    local app_id = config.ADMIN_APP_ID or "com.vela.su.aigik"
    local marker_name = "hello"

    local quick_try = {
        (config.QUICKAPP_BASE or "") .. "/" .. app_id,
        "/data/files/" .. app_id,
        "/data/quickapp/files/" .. app_id,
    }

    for _, dir in ipairs(quick_try) do
        local d = str.trim_trailing_slashes(tostring(dir or ""))
        if d ~= "" then
            local marker = d .. "/" .. marker_name
            if fs.file_exists(marker) then
                local base = parent_dir(d)
                if base ~= "" then
                    return true, {
                        app_dir = d,
                        marker = marker,
                        base = base,
                        source = "fast",
                        checked = 1,
                    }
                end
            end
        end
    end

    local tmp = config.TMP_DIR .. "/scan_admin_dir_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
    local cmd = "find /data -type d -name " .. str.sh_quote(app_id) .. " 2>/dev/null > " .. str.sh_quote(tmp)
    os.execute(cmd)
    local lines = parse_lines(fs.read_file(tmp) or "")
    fs.remove_file(tmp)

    local checked = 0
    for _, dir in ipairs(lines) do
        checked = checked + 1
        local marker = dir .. "/" .. marker_name
        if fs.file_exists(marker) then
            local base = parent_dir(dir)
            if base ~= "" then
                return true, {
                    app_dir = dir,
                    marker = marker,
                    base = base,
                    source = "find",
                    checked = checked,
                    candidates = #lines,
                }
            end
        end
    end

    return false, {
        source = "find",
        checked = checked,
        candidates = #lines,
    }
end

local function apply_quickapp_base(base)
    local normalized = str.trim_trailing_slashes(tostring(base or ""))
    if normalized == "" then
        return false, "empty base"
    end

    if type(config.set_quickapp_base) == "function" then
        local ok, err = config.set_quickapp_base(normalized)
        if ok == false then
            return false, tostring(err or "set_quickapp_base failed")
        end
    else
        config.QUICKAPP_BASE = normalized
    end

    if ipc and type(ipc.set_quickapp_base) == "function" then
        local ok, err = ipc.set_quickapp_base(normalized)
        if ok == false then
            return false, tostring(err or "ipc set_quickapp_base failed")
        end
    end

    return true, normalized
end

-------------------------------------------------
-- Button handlers
-------------------------------------------------
btn_scan:onevent(lvgl.EVENT.CLICKED, function()
    append_log("[Scan] searching /data for " .. tostring(config.ADMIN_APP_ID) .. "/hello")

    local ok, info = find_admin_sandbox_dir()
    if not ok then
        append_log("Sandbox not found (checked=" .. tostring(info.checked or 0) .. ", candidates=" .. tostring(info.candidates or 0) .. ")")
        append_log("Hint: start QuickApp once and ensure internal://files/hello exists")
        return
    end

    append_log("Found app dir: " .. tostring(info.app_dir))
    append_log("Marker ok: " .. tostring(info.marker))
    append_log("Source: " .. tostring(info.source))

    local old_base = str.trim_trailing_slashes(tostring(config.QUICKAPP_BASE or ""))
    local ok_set, new_base_or_err = apply_quickapp_base(info.base)
    if not ok_set then
        append_log("Update base failed: " .. tostring(new_base_or_err))
        return
    end

    local new_base = tostring(new_base_or_err)
    append_log("QUICKAPP_BASE: " .. old_base .. " -> " .. new_base)

    local apps = app_scan.scan_all_apps(new_base)
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
