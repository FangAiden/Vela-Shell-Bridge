-- VelaShellBridge main entry point
-- Hot-reload friendly main script entry.

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
-- UI: Components
-------------------------------------------------
local ui_theme = require("ui.theme")
local ui_layout = require("ui.layout")
local ui_components = require("ui.components")

local screen_w = lvgl.HOR_RES()
local screen_h = lvgl.VER_RES()
local ui = ui_layout.compute(screen_w, screen_h)
local bucket_key = ui.bucket_key

local ui_text = {
    status_on_text = "SU Daemon",
    status_off_text = "SU Stopped",
    btn_scan_text = "Scan",
    btn_policy_text = "Policy",
    btn_clear_text = "Clear",
}

if ui.is_pill_screen then
    ui_text.status_on_text = "SU ON"
    ui_text.status_off_text = "SU OFF"
    ui_text.btn_policy_text = "Rule"
end

if ui.log_w and ui.log_w > 0 then
    log_wrap_chars = math.max(20, math.floor((ui.log_w - 20) / math.max(ui.char_w, 6)))
end

local ui_view = ui_components.create(lvgl, ui_theme, ui, ui_text)
local root = ui_view.root
local time_label = ui_view.time_label
local status_pill = ui_view.status_pill
log_view = ui_view.log_view
ctx.log_view = log_view
local btn_scan = ui_view.btn_scan
local btn_policies = ui_view.btn_policies
local btn_clear = ui_view.btn_clear

local function update_status_ui()
    ui_view.update_status(ctx.enabled)
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

local function run_scan(trigger)
    local from = tostring(trigger or "manual")
    append_log("[Scan] (" .. from .. ") searching /data for " .. tostring(config.ADMIN_APP_ID) .. "/hello")

    local ok, info = find_admin_sandbox_dir()
    if not ok then
        append_log("Sandbox not found (checked=" .. tostring(info.checked or 0) .. ", candidates=" .. tostring(info.candidates or 0) .. ")")
        append_log("Hint: start QuickApp once and ensure internal://files/hello exists")
        return false
    end

    append_log("Found app dir: " .. tostring(info.app_dir))
    append_log("Marker ok: " .. tostring(info.marker))
    append_log("Source: " .. tostring(info.source))

    local old_base = str.trim_trailing_slashes(tostring(config.QUICKAPP_BASE or ""))
    local ok_set, new_base_or_err = apply_quickapp_base(info.base)
    if not ok_set then
        append_log("Update base failed: " .. tostring(new_base_or_err))
        return false
    end

    local new_base = tostring(new_base_or_err)
    append_log("QUICKAPP_BASE: " .. old_base .. " -> " .. new_base)

    local apps = app_scan.scan_all_apps(new_base)
    append_log("Found " .. #apps .. " apps")
    append_log(JSON.encode(apps))
    return true
end

-------------------------------------------------
-- Button handlers
-------------------------------------------------
btn_scan:onevent(lvgl.EVENT.CLICKED, function()
    run_scan("button")
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
append_log(string.format(
    "UI %dx%d bucket=%s top_h=%d log_min_h=%d btn_h=%d",
    screen_w, screen_h, tostring(bucket_key),
    ui.top_zone_h,
    ui.log_min_h,
    ui.btn_zone_h
))
run_scan("startup")

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
