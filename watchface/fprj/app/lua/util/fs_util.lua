-- util/fs_util.lua
-- 无 lfs 环境的文件工具
-- 只依赖 os.execute / io.open

local config = require("su_config")
local str    = require("util.str")

local M = {}

-- 确保 tmp 目录存在
os.execute(string.format('mkdir -p %s', config.TMP_DIR))

local TMP_LIST_FILE = config.TMP_DIR .. "/fs_list_tmp.txt"

----------------------------------------------------------------------
-- 基础文件操作
----------------------------------------------------------------------

function M.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function M.file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

function M.write_file(path, data)
    if data == nil then data = "" end

    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        os.execute(string.format('mkdir -p %s', dir))
    end

    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    local ok_write = f:write(data)
    -- Note: f:flush() is implicit before close, but we call it explicitly for safety
    pcall(function() f:flush() end)
    f:close()

    if not ok_write then
        pcall(function() os.remove(tmp) end)
        return false
    end

    -- Atomic rename: on POSIX systems, rename() is atomic
    -- On NuttX/FAT, it's not perfectly atomic, but safer than remove+rename
    -- We use rename directly (it will overwrite existing file on POSIX)
    local ok_rename = os.rename(tmp, path)
    if not ok_rename then
        -- Fallback: remove target first, then rename (less safe but necessary on some systems)
        os.remove(path)
        ok_rename = os.rename(tmp, path)
        if not ok_rename then
            pcall(function() os.remove(tmp) end)
            return false
        end
    end

    return true
end

function M.append_file(path, data)
    if data == nil then data = "" end

    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        os.execute(string.format('mkdir -p %s', dir))
    end

    local f = io.open(path, "a")
    if not f then return false, "open failed" end
    f:write(data)
    f:close()
    return true
end

function M.remove_file(path)
    os.remove(path)
    return true
end

----------------------------------------------------------------------
-- 目录扫描
----------------------------------------------------------------------

local function run_shell_list(cmd)
    local full_cmd = string.format('%s > %s', cmd, TMP_LIST_FILE)
    os.execute(full_cmd)

    local results = {}
    local f = io.open(TMP_LIST_FILE, "r")
    if f then
        for line in f:lines() do
            line = line:gsub("^%s*(.-)%s*$", "%1")
            if line ~= "" then
                results[#results + 1] = line
            end
        end
        f:close()
    end

    os.remove(TMP_LIST_FILE)
    return results
end

function M.list_files(dir)
    -- -1 确保每行一个条目
    local cmd = string.format('ls -1 %s', str.sh_quote(dir))
    return run_shell_list(cmd)
end

function M.list_dirs(dir)
    local entries = M.list_files(dir)
    local dirs = {}

    for _, name in ipairs(entries) do
        if name:sub(-1) == "/" then
            name = name:sub(1, -2)
        end
        if name ~= "" and name ~= "." and name ~= ".." then
            dirs[#dirs + 1] = name
        end
    end

    return dirs
end

----------------------------------------------------------------------
-- is_dir: 尝试打开 path/. 判断是否为目录
----------------------------------------------------------------------

function M.is_dir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    -- 方法1: 尝试打开 path/. (大多数系统支持)
    local test_path = path:sub(-1) == "/" and path .. "." or path .. "/."
    local f = io.open(test_path, "r")
    if f then
        f:close()
        return true
    end

    -- 方法2: 用 cd 命令判断 (fallback)
    local tmp = config.TMP_DIR .. "/isdir_" .. tostring(os.time()) .. ".txt"
    local cmd = string.format('if cd %s; then echo 1 > %s; else echo 0 > %s; fi',
        str.sh_quote(path), tmp, tmp)
    os.execute(cmd)

    local out = M.read_file(tmp) or ""
    os.remove(tmp)
    return out:match("1") ~= nil
end

return M
