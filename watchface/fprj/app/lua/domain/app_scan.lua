local fs     = require("util.fs_util")
local config = require("su_config")
local JSON   = require("core.json")
local str    = require("util.str")

local M = {}

local APPS_JSON_MAX_DEPTH = 10
local apps_json_path_cache = nil
local APP_DIR_FIND_MAX_DEPTH = 10
local FALLBACK_FIND_MAX_DEPTH = 8
local app_dir_cache = {}
local app_dir_cache_key = ""
local ADMIN_DIR_FIND_MAX_DEPTH = 12
local admin_dir_cache = nil
local admin_root_cache = nil
local admin_cache_key = ""

local function safe_str(v)
    return str.safe_str(v)
end

local function trim(v)
    return (safe_str(v):match("^%s*(.-)%s*$"))
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

local function append_unique(list, seen, value)
    local s = trim(value)
    if s == "" then return false end
    if seen[s] then return false end
    seen[s] = true
    list[#list + 1] = s
    return true
end

local function is_valid_app_id(name)
    if type(name) ~= "string" then
        return false
    end

    name = name:match("^%s*(.-)%s*$")
    if name == "" or name == "." or name == ".." then
        return false
    end
    if name:find(":") or name:find("/") then
        return false
    end
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

local function parse_lines(text)
    local out = {}
    local src = safe_str(text):gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (src .. "\n"):gmatch("(.-)\n") do
        local s = trim(line)
        if s ~= "" then
            out[#out + 1] = s
        end
    end
    return out
end

local function starts_with(s, prefix)
    if type(s) ~= "string" or type(prefix) ~= "string" then
        return false
    end
    return s:sub(1, #prefix) == prefix
end

local function dir_name(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end
    local p = path:gsub("/+$", "")
    return p:match("([^/]+)$") or ""
end

local function parent_dir(path)
    if type(path) ~= "string" then return "" end
    return path:match("^(.*)/[^/]+$") or ""
end

local function has_manifest(dir)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    return fs.file_exists and fs.file_exists(dir .. "/manifest.json") or false
end

local function has_meta_inf(dir)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    return fs.is_dir and fs.is_dir(dir .. "/META-INF") or false
end

local function current_app_base_key()
    local list = as_list(config.APP_INSTALL_BASE)
    local parts = {}
    for _, v in ipairs(list) do
        local s = trim(v)
        if s ~= "" then
            parts[#parts + 1] = s
        end
    end
    return table.concat(parts, "|")
end

local function ensure_app_dir_cache_fresh()
    local key = current_app_base_key()
    if key ~= app_dir_cache_key then
        app_dir_cache_key = key
        app_dir_cache = {}
    end
end

local function ensure_admin_cache_fresh()
    local key = trim(config.ADMIN_APP_ID or "")
    if key ~= admin_cache_key then
        admin_cache_key = key
        admin_dir_cache = nil
        admin_root_cache = nil
    end
end

function M.scan_all_apps(base_dir)
    local apps = {}
    local seen = {}

    if type(base_dir) ~= "string" or base_dir == "" then
        return apps
    end

    local entries = fs.list_files(base_dir)
    if not entries or #entries == 0 then
        return apps
    end

    for _, raw_name in ipairs(entries) do
        local name = raw_name
        if type(name) == "string" and name:sub(-1) == "/" then
            name = name:sub(1, -2)
        end
        if is_valid_app_id(name) then
            local full = base_dir .. "/" .. name
            if fs.is_dir and fs.is_dir(full) and not seen[name] then
                seen[name] = true
                apps[#apps + 1] = name
            end
        end
    end

    table.sort(apps)
    return apps
end

local function pick_app_id(it)
    if type(it) ~= "table" then return "" end
    local candidates = {
        it.package, it.packageName, it.package_name,
        it.appId, it.app_id, it.id,
    }
    for _, raw in ipairs(candidates) do
        local pkg = trim(raw)
        if pkg ~= "" and is_valid_app_id(pkg) then
            return pkg
        end
    end
    return ""
end

local function pick_app_name(it)
    if type(it) ~= "table" then return "" end

    local direct = {
        it.name, it.appName, it.app_name, it.title, it.label,
    }
    for _, raw in ipairs(direct) do
        local v = trim(raw)
        if v ~= "" then return v end
    end

    local names = it.names
    if type(names) == "table" then
        local first = names[1]
        if type(first) == "table" then
            local value = trim(first.value or first.name or first.title)
            if value ~= "" then return value end
        elseif type(first) == "string" then
            local value = trim(first)
            if value ~= "" then return value end
        end
    end

    local locale_names = it.localeNames or it.locale_names
    if type(locale_names) == "table" then
        for _, v in pairs(locale_names) do
            local value = trim(v)
            if value ~= "" then return value end
        end
    end

    return ""
end

local function pick_icon_raw(it)
    if type(it) ~= "table" then return "" end
    local candidates = {
        it.icon, it.iconPath, it.icon_path,
        it.logo, it.logoPath, it.logo_path,
    }
    for _, raw in ipairs(candidates) do
        local s = trim(raw)
        if s ~= "" then return s end
    end
    return ""
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

local function join_path(dir, rel)
    local r = safe_str(rel):gsub("^/+", "")
    if r == "" then return "" end
    return dir .. "/" .. r
end

local function resolve_icon_abs(app_dir, icon_rel)
    local raw = trim(icon_rel)
    local prefix = "internal://files/"
    if raw:sub(1, #prefix) == prefix then
        raw = raw:sub(#prefix + 1)
    end

    if raw:sub(1, 1) == "/" then
        if is_system_abs_path(raw) and fs.file_exists and fs.file_exists(raw) then
            return raw
        end
        raw = raw:gsub("^/+", "")
    end

    if raw ~= "" then
        local abs = join_path(app_dir, raw)
        if fs.file_exists and fs.file_exists(abs) then
            return abs
        end
    end

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

local function score_app_dir(path, pkg, bases)
    if type(path) ~= "string" or path == "" then
        return -1000000
    end
    local score = 0
    local suffix = "/" .. tostring(pkg or "")
    if suffix ~= "/" and path:sub(-#suffix) == suffix then
        score = score + 100
    end

    for i, base in ipairs(bases or {}) do
        local b = trim(base)
        if b ~= "" then
            if path == (b .. "/" .. pkg) then
                score = score + 1000 - i
            elseif starts_with(path, b .. "/") then
                score = score + 500 - i
            end
        end
    end
    return score
end

local function find_pkg_dirs_by_name(pkg)
    local tmp = config.TMP_DIR
        .. "/scan_pkg_dir_"
        .. tostring(os.time())
        .. "_"
        .. tostring(math.random(1000, 9999))
        .. ".txt"
    local cmd = "find /data -maxdepth "
        .. tostring(APP_DIR_FIND_MAX_DEPTH)
        .. " -type d -name "
        .. str.sh_quote(pkg)
        .. " 2>/dev/null > "
        .. str.sh_quote(tmp)
    os.execute(cmd)
    local lines = parse_lines(fs.read_file(tmp) or "")
    fs.remove_file(tmp)
    return lines
end

local function find_admin_pkg_dir()
    ensure_admin_cache_fresh()
    if admin_dir_cache ~= nil then
        if admin_dir_cache == false then
            return nil, nil
        end
        if has_meta_inf(admin_dir_cache) and fs.is_dir and fs.is_dir(admin_dir_cache) then
            return admin_dir_cache, admin_root_cache
        end
        admin_dir_cache = nil
        admin_root_cache = nil
    end

    local admin_pkg = trim(config.ADMIN_APP_ID or "")
    if admin_pkg == "" then
        admin_dir_cache = false
        return nil, nil
    end

    local tmp = config.TMP_DIR
        .. "/scan_admin_pkg_"
        .. tostring(os.time())
        .. "_"
        .. tostring(math.random(1000, 9999))
        .. ".txt"
    local cmd = "find /data -maxdepth "
        .. tostring(ADMIN_DIR_FIND_MAX_DEPTH)
        .. " -type d -name "
        .. str.sh_quote(admin_pkg)
        .. " 2>/dev/null > "
        .. str.sh_quote(tmp)
    os.execute(cmd)
    local lines = parse_lines(fs.read_file(tmp) or "")
    fs.remove_file(tmp)

    local pick = nil
    for _, dir in ipairs(lines) do
        local d = trim(dir)
        if d ~= "" and has_meta_inf(d) then
            pick = d
            break
        end
    end

    if not pick then
        admin_dir_cache = false
        return nil, nil
    end

    local root = parent_dir(pick)
    if root == "" then
        admin_dir_cache = false
        return nil, nil
    end

    admin_dir_cache = pick
    admin_root_cache = root
    return pick, root
end

local function resolve_app_dir(pkg)
    ensure_app_dir_cache_fresh()
    if app_dir_cache[pkg] ~= nil then
        local cached = app_dir_cache[pkg]
        if cached == false then
            return nil, nil
        end
        return cached, parent_dir(cached)
    end

    local bases = as_list(config.APP_INSTALL_BASE)
    if #bases == 0 then
        bases = { "/data/app", "/data/quickapp/app", "/data/app/quickapp" }
    end

    local suffixes = {
        "",
        "/app",
        "/apps",
        "/quickapp",
        "/installed",
    }

    for _, base in ipairs(bases) do
        local b = trim(base)
        if b ~= "" then
            for _, suffix in ipairs(suffixes) do
                local dir = b .. suffix .. "/" .. pkg
                if fs.is_dir and fs.is_dir(dir) and has_manifest(dir) then
                    app_dir_cache[pkg] = dir
                    return dir, b
                end
            end
        end
    end

    local found = find_pkg_dirs_by_name(pkg)
    local best_dir = nil
    local best_score = -1000000
    for _, dir in ipairs(found) do
        local d = trim(dir)
        if d ~= "" and fs.is_dir and fs.is_dir(d) and has_manifest(d) and dir_name(d) == pkg then
            local s = score_app_dir(d, pkg, bases)
            if s > best_score then
                best_score = s
                best_dir = d
            end
        end
    end
    if best_dir then
        app_dir_cache[pkg] = best_dir
        return best_dir, parent_dir(best_dir)
    end

    app_dir_cache[pkg] = false
    return nil, nil
end

local function pick_apps_list(obj)
    if type(obj) ~= "table" then return nil end

    local list_keys = {
        "InstalledApps",
        "installedApps",
        "apps",
        "installed",
        "appList",
        "app_list",
    }

    for _, key in ipairs(list_keys) do
        local v = obj[key]
        if type(v) == "table" then
            return v
        end
    end

    local data = obj.data
    if type(data) == "table" then
        for _, key in ipairs(list_keys) do
            local v = data[key]
            if type(v) == "table" then
                return v
            end
        end
    end

    if type(obj[1]) == "table" then
        return obj
    end

    return nil
end

local function read_apps_json_file(path)
    local txt = path and fs.read_file(path) or nil
    if not txt or txt == "" then return nil, nil end
    local ok, obj = pcall(JSON.decode, txt)
    if not ok or type(obj) ~= "table" then return nil, nil end
    local list = pick_apps_list(obj)
    if type(list) ~= "table" then return nil, nil end
    return obj, list
end

local function apps_list_has_package(list, app_id)
    local target = trim(app_id)
    if target == "" or type(list) ~= "table" then return false end

    local n = #list
    if n > 0 then
        for i = 1, n do
            local it = list[i]
            if type(it) == "table" and pick_app_id(it) == target then
                return true
            end
        end
        return false
    end

    for _, it in pairs(list) do
        if type(it) == "table" and pick_app_id(it) == target then
            return true
        end
    end
    return false
end

local function iter_app_items(list, visitor)
    if type(list) ~= "table" or type(visitor) ~= "function" then
        return
    end

    local n = #list
    if n > 0 then
        for i = 1, n do
            visitor(list[i])
        end
        return
    end

    for _, item in pairs(list) do
        visitor(item)
    end
end

local function find_apps_json_under_data()
    local tmp = config.TMP_DIR .. "/scan_apps_json_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
    local cmd = "find /data -maxdepth " .. tostring(APPS_JSON_MAX_DEPTH) .. " -type f -name apps.json 2>/dev/null > " .. str.sh_quote(tmp)
    os.execute(cmd)
    local lines = parse_lines(fs.read_file(tmp) or "")
    fs.remove_file(tmp)
    return lines
end

local function find_manifest_dirs_under(root, max_depth)
    local out = {}
    local base = trim(root)
    if base == "" then return out end
    if not (fs.is_dir and fs.is_dir(base)) then return out end

    local tmp = config.TMP_DIR
        .. "/scan_manifest_"
        .. tostring(os.time())
        .. "_"
        .. tostring(math.random(1000, 9999))
        .. ".txt"
    local cmd = "find "
        .. str.sh_quote(base)
        .. " -maxdepth "
        .. tostring(max_depth or FALLBACK_FIND_MAX_DEPTH)
        .. " -type f -name manifest.json 2>/dev/null > "
        .. str.sh_quote(tmp)
    os.execute(cmd)
    local files = parse_lines(fs.read_file(tmp) or "")
    fs.remove_file(tmp)

    local seen = {}
    for _, fp in ipairs(files) do
        local d = parent_dir(fp)
        if d ~= "" and not seen[d] then
            seen[d] = true
            out[#out + 1] = d
        end
    end
    return out
end

local function resolve_apps_json_path()
    local admin_pkg = trim(config.ADMIN_APP_ID or "")
    if apps_json_path_cache and fs.file_exists and fs.file_exists(apps_json_path_cache) then
        local _, list = read_apps_json_file(apps_json_path_cache)
        if list and (admin_pkg == "" or apps_list_has_package(list, admin_pkg)) then
            return apps_json_path_cache
        end
        apps_json_path_cache = nil
    end

    local candidates = {}
    local seen = {}
    local configured = as_list(config.APPS_JSON)
    for _, p in ipairs(configured) do
        append_unique(candidates, seen, p)
    end
    append_unique(candidates, seen, "/data/apps.json")
    append_unique(candidates, seen, "/data/quickapp/apps.json")
    append_unique(candidates, seen, "/data/system/apps.json")
    append_unique(candidates, seen, "/data/quickapp/system/apps.json")
    local base = trim(config.QUICKAPP_BASE or "")
    if base ~= "" then
        append_unique(candidates, seen, base .. "/apps.json")
        local p = parent_dir(base)
        if p ~= "" then
            append_unique(candidates, seen, p .. "/apps.json")
            local pp = parent_dir(p)
            if pp ~= "" then
                append_unique(candidates, seen, pp .. "/apps.json")
            end
        end
    end

    local fallback_valid = nil

    for _, p in ipairs(candidates) do
        if fs.file_exists and fs.file_exists(p) then
            local _, list = read_apps_json_file(p)
            if list then
                if admin_pkg == "" or apps_list_has_package(list, admin_pkg) then
                    apps_json_path_cache = p
                    return p
                end
                if not fallback_valid then fallback_valid = p end
            end
        end
    end

    local found = find_apps_json_under_data()
    for _, p in ipairs(found) do
        local _, list = read_apps_json_file(p)
        if list then
            if admin_pkg == "" or apps_list_has_package(list, admin_pkg) then
                apps_json_path_cache = p
                return p
            end
            if not fallback_valid then fallback_valid = p end
        end
    end

    if admin_pkg == "" and fallback_valid then
        apps_json_path_cache = fallback_valid
        return fallback_valid
    end

    return nil
end

local function scan_install_dirs_fallback()
    local out_apps = {}
    local meta = {}
    local seen = {}

    local bases = as_list(config.APP_INSTALL_BASE)
    if #bases == 0 then
        bases = { "/data/app", "/data/quickapp/app", "/data/app/quickapp", "/data/files" }
    end

    for _, base in ipairs(bases) do
        local b = trim(base)
        if b ~= "" then
            local manifest_dirs = find_manifest_dirs_under(b, FALLBACK_FIND_MAX_DEPTH)
            for _, app_dir in ipairs(manifest_dirs) do
                local name = dir_name(app_dir)
                if is_valid_app_id(name) and has_manifest(app_dir) and not seen[name] then
                    seen[name] = true
                    out_apps[#out_apps + 1] = name
                    meta[name] = {
                        name = "",
                        icon = "",
                    }
                end
            end
        end
    end

    table.sort(out_apps)
    return out_apps, meta
end

local function merge_meta(base_meta, extra_meta)
    if type(extra_meta) ~= "table" then return end
    for app_id, m in pairs(extra_meta) do
        if is_valid_app_id(app_id) and type(m) == "table" then
            local cur = base_meta[app_id]
            if type(cur) ~= "table" then
                base_meta[app_id] = {
                    name = trim(m.name),
                    icon = trim(m.icon),
                }
            else
                if trim(cur.name) == "" and trim(m.name) ~= "" then
                    cur.name = trim(m.name)
                end
                if trim(cur.icon) == "" and trim(m.icon) ~= "" then
                    cur.icon = trim(m.icon)
                end
            end
        end
    end
end

function M.scan_installed_apps()
    local apps = {}
    local meta = {}
    local seen = {}

    local apps_json_path = resolve_apps_json_path()
    local _, list = read_apps_json_file(apps_json_path)
    local _, admin_root = find_admin_pkg_dir()

    if type(list) == "table" then
        iter_app_items(list, function(it)
            if type(it) == "table" then
                local pkg = pick_app_id(it)
                if pkg ~= "" and not seen[pkg] then
                    seen[pkg] = true
                    apps[#apps + 1] = pkg
                end

                if pkg ~= "" then
                    local icon_raw = pick_icon_raw(it)
                    local icon = ""
                    if icon_raw ~= "" and admin_root and admin_root ~= "" then
                        local app_dir = admin_root .. "/" .. pkg
                        if fs.is_dir and fs.is_dir(app_dir) then
                            icon = resolve_icon_abs(app_dir, icon_raw)
                            if icon == "" then
                                icon = resolve_icon_abs(app_dir, "")
                            end
                        end
                    end
                    if icon == "" then
                        local app_dir2 = resolve_app_dir(pkg)
                        if app_dir2 then
                            icon = resolve_icon_abs(app_dir2, icon_raw)
                        end
                    end
                    meta[pkg] = {
                        name = pick_app_name(it),
                        icon = trim(icon),
                    }
                end
            end
        end)
    end

    local fb_apps, fb_meta = scan_install_dirs_fallback()
    for _, app_id in ipairs(fb_apps) do
        if not seen[app_id] then
            seen[app_id] = true
            apps[#apps + 1] = app_id
        end
    end
    merge_meta(meta, fb_meta)

    if #apps == 0 then
        return fb_apps, fb_meta
    end

    table.sort(apps)
    return apps, meta
end

return M
