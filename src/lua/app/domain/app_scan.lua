local fs     = require("app.util.fs_util")

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
    
    return true
end

function M.scan_all_apps(base_dir)
    local apps = {}

    if type(base_dir) ~= "string" or base_dir == "" then
        return apps
    end

    local dirs = fs.list_dirs(base_dir)
    if not dirs or #dirs == 0 then
        return apps
    end

    for _, name in ipairs(dirs) do
        if is_valid_app_id(name) then
            apps[#apps + 1] = name
        end
    end

    table.sort(apps)

    return apps
end

return M
