local fs     = require("app.util.fs_util")
local config = require("app.config")
local JSON   = _G.JSON or require("app.util.json_util")

local M = {}

local function is_valid_app_id(name)
    if type(name) ~= "string" then
        return false
    end

    -- 去掉前后空白
    name = name:match("^%s*(.-)%s*$")

    if name == "" or name == "." or name == ".." then
        return false
    end

    -- 过滤掉 ls 的目录头部，比如 "/data/files:"
    if name:find(":") or name:find("/") then
        return false
    end

    -- /data/files 下可能存在临时脚本或其它文件（如 "_bg_exit.sh"），这里做更严格的 AppId 过滤：
    -- - 必须包含 "."（形如 com.example.app）
    -- - 仅允许字母/数字/下划线/中划线/点
    -- - 不能以 "_" 或 "." 开头
    -- - 不能以 ".sh" 等脚本后缀结尾
    if name:sub(1, 1) == "_" or name:sub(1, 1) == "." then
        return false
    end

    if name:sub(-3) == ".sh" or name:sub(-4) == ".lua" or name:sub(-5) == ".json" then
        return false
    end

    if not name:find("%.") then
        return false
    end

    if name:sub(-1) == "." or name:find("%.%.") then
        return false
    end

    if not name:match("^[%w][%w%._%-]*$") then
        return false
    end
    
    return true
end

function M.scan_all_apps(base_dir)
    local apps = {}

    if type(base_dir) ~= "string" or base_dir == "" then
        return apps
    end

    local entries = fs.list_files(base_dir)
    if not entries or #entries == 0 then
        return apps
    end

    for _, name in ipairs(entries) do
        if type(name) == "string" and name:sub(-1) == "/" then
            name = name:sub(1, -2)
        end

        if is_valid_app_id(name) then
            -- /data/files 下可能混入脚本/日志文件：只认目录
            local full = base_dir .. "/" .. name
            if fs.is_dir and fs.is_dir(full) then
                apps[#apps + 1] = name
            end
        end
    end

    table.sort(apps)

    return apps
end

local function as_list(v)
    if type(v) == "table" then
        return v
    end
    if type(v) == "string" and v ~= "" then
        return { v }
    end
    return {}
end

local function safe_str(v)
    if v == nil then return "" end
    return tostring(v)
end

local function pick_app_name(it)
    if type(it) ~= "table" then return "" end
    local names = it.names
    if type(names) ~= "table" then return "" end
    local first = names[1]
    if type(first) == "table" and first.value ~= nil then
        return safe_str(first.value)
    end
    return ""
end

local function resolve_app_dir(pkg)
    local bases = as_list(config.APP_INSTALL_BASE)
    if #bases == 0 then
        bases = { "/data/app" }
    end

    for _, base in ipairs(bases) do
        if type(base) == "string" and base ~= "" then
            local dir = base .. "/" .. pkg
            if fs.is_dir and fs.is_dir(dir) then
                return dir, base
            end
        end
    end

    return nil, nil
end

local function join_path(dir, rel)
    local r = safe_str(rel)
    r = r:gsub("^/+", "")
    if r == "" then return "" end
    return dir .. "/" .. r
end

local function is_system_abs_path(p)
    if type(p) ~= "string" or p == "" then
        return false
    end
    return (
        p:sub(1, 6) == "/data/" or
        p:sub(1, 5) == "/tmp/" or
        p:sub(1, 6) == "/proc/" or
        p:sub(1, 5) == "/dev/" or
        p:sub(1, 8) == "/system/"
    )
end

local function resolve_icon_abs(app_dir, icon_rel)
    local raw = safe_str(icon_rel)
    raw = raw:match("^%s*(.-)%s*$")

    -- 兼容 "internal://files/xx.png"
    local prefix = "internal://files/"
    if raw:sub(1, #prefix) == prefix then
        raw = raw:sub(#prefix + 1)
    end

    -- apps.json 通常是相对路径；如果给了“系统绝对路径”，也直接用
    if raw:sub(1, 1) == "/" then
        if is_system_abs_path(raw) then
            if fs.file_exists and fs.file_exists(raw) then
                return raw
            end
        else
            -- 像 "/resources/xx.png" 这种更像“应用内绝对路径”，按相对路径处理
            raw = raw:gsub("^/+", "")
        end
    end

    if raw ~= "" then
        local abs = join_path(app_dir, raw)
        if fs.file_exists and fs.file_exists(abs) then
            return abs
        end
    end

    -- 兜底：一些常见 icon 名称（尽量放 png）
    local candidates = {
        "assets/image/logo.png",
        "assets/images/logo.png",
        "logo.png",
        "icon.png",
        "common/logo.png",
        "common/logo_144.png",
        "common/img/icon/icon.png",
        "resources/base/media/logo_144.png",
        "resources/base/media/icon.png",
        "assets/logo.png",
    }
    for _, rel in ipairs(candidates) do
        local p = join_path(app_dir, rel)
        if fs.file_exists and fs.file_exists(p) then
            return p
        end
    end

    return ""
end

local function resolve_apps_json_path()
    local candidates = as_list(config.APPS_JSON)
    if #candidates == 0 then
        candidates = { "/data/apps.json", "/data/quickapp/apps.json" }
    end

    for _, p in ipairs(candidates) do
        if type(p) == "string" and p ~= "" then
            if fs.file_exists and fs.file_exists(p) then
                return p
            end
        end
    end
    return nil
end

local function scan_install_dirs_fallback()
    local out_apps = {}
    local meta = {}
    local seen = {}

    local bases = as_list(config.APP_INSTALL_BASE)
    if #bases == 0 then
        bases = { "/data/app" }
    end

    for _, base in ipairs(bases) do
        if type(base) == "string" and base ~= "" then
            local entries = fs.list_files(base)
            if entries and #entries > 0 then
                for _, name in ipairs(entries) do
                    if type(name) == "string" and name:sub(-1) == "/" then
                        name = name:sub(1, -2)
                    end

                    if is_valid_app_id(name) then
                        local app_dir = base .. "/" .. name
                        if fs.is_dir and fs.is_dir(app_dir) and not seen[name] then
                            seen[name] = true
                            out_apps[#out_apps + 1] = name
                            meta[name] = {
                                name = "",
                                icon = resolve_icon_abs(app_dir, ""),
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(out_apps)
    return out_apps, meta
end

-- 从 apps.json 获取已安装包名，并用 APP_INSTALL_BASE 校验目录存在；同时返回 icon 的绝对路径（若能定位）。
function M.scan_installed_apps()
    local apps = {}
    local meta = {}

    local apps_json_path = resolve_apps_json_path()
    local txt = apps_json_path and fs.read_file(apps_json_path) or nil
    if not txt or txt == "" then
        return scan_install_dirs_fallback()
    end

    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then
        return scan_install_dirs_fallback()
    end

    local list = obj.InstalledApps
    if type(list) ~= "table" then
        return scan_install_dirs_fallback()
    end

    local seen = {}
    for _, it in ipairs(list) do
        if type(it) == "table" then
            local pkg = safe_str(it.package)
            if pkg ~= "" and is_valid_app_id(pkg) then
                local app_dir = resolve_app_dir(pkg)
                if app_dir then
                    if not seen[pkg] then
                        seen[pkg] = true
                        apps[#apps + 1] = pkg
                    end
                    meta[pkg] = {
                        name = pick_app_name(it),
                        icon = resolve_icon_abs(app_dir, it.icon),
                    }
                end
            end
        end
    end

    table.sort(apps)
    return apps, meta
end

return M
