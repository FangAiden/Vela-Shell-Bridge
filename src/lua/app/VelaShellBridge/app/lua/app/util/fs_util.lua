-- util/fs_util.lua
-- 无 lfs 环境的文件工具
-- 只依赖 os.execute / io.open
-- 使用 shell 实现目录扫描（ls 不带任何参数）

local config = require("app.config")

local M = {}

-- 确保 tmp 目录存在
os.execute(string.format('mkdir -p %s', config.TMP_DIR))

local TMP_LIST_FILE = config.TMP_DIR .. "/fs_list_tmp.txt"

local function sh_quote(s)
    s = tostring(s or "")
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
end

----------------------------------------------------------------------
-- 1. read / write / remove 基础文件操作
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
    f:write(data)
    f:close()

    os.remove(path)
    os.rename(tmp, path)
    return true
end

-- Append mode (non-atomic): used for low-overhead logs (NDJSON).
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
-- 2. shell 实现目录扫描
--    注意：这里只运行你允许的“裸 ls”，不带任何参数
----------------------------------------------------------------------

local function run_shell_list(cmd)
    -- cmd 里只允许出现裸 ls，重定向在这里加
    local full_cmd = string.format('%s > %s', cmd, TMP_LIST_FILE)
    os.execute(full_cmd)

    local results = {}
    local f = io.open(TMP_LIST_FILE, "r")
    if f then
        for line in f:lines() do
            -- 去掉首尾空白
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

----------------------------------------------------------------------
-- list_files: 返回 dir 下 ls 的所有条目（文件 + 目录名字符串）
-- 等价于：ls dir
----------------------------------------------------------------------

function M.list_files(dir)
    -- 不用 ls 的任何参数，只用 ls dir（避免依赖 && 之类不一定存在的运算符）
    local cmd = string.format('ls %s', dir)
    return run_shell_list(cmd)
end

----------------------------------------------------------------------
-- list_dirs: 返回 dir 下所有子目录名称
-- 依赖 ls 输出末尾是否带 "/"，如果带 "/" 就当它是目录。
-- 对于 /data/quickapp/files 这种“只放子目录”的，也没问题：
--   就算检测不到 "/"，我们仍然可以直接把名字当成目录用。
----------------------------------------------------------------------

function M.list_dirs(dir)
    local entries = M.list_files(dir)
    local dirs = {}

    for _, name in ipairs(entries) do
        -- 典型输出是 "bin/" 这种，我们先检查末尾 "/"
        if name:sub(-1) == "/" then
            name = name:sub(1, -2)
        end

        -- 过滤掉 ".", ".." 之类
        if name ~= "" and name ~= "." and name ~= ".." then
            dirs[#dirs + 1] = name
        end
    end

    return dirs
end

----------------------------------------------------------------------
-- is_dir: 判断路径是否为目录（目标设备 ls 不一定带 "/"，因此用 cd 判断）
----------------------------------------------------------------------

function M.is_dir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    local tmp = config.TMP_DIR .. "/fs_isdir_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
    local q_path = sh_quote(path)
    local q_tmp = sh_quote(tmp)

    -- 用 `cd` 的返回状态判断（避免依赖 [ -d ] 是否存在）
    local cmd = string.format('if cd %s; then echo 1 > %s; else echo 0 > %s; fi', q_path, q_tmp, q_tmp)
    os.execute(cmd)

    local out = M.read_file(tmp) or ""
    os.remove(tmp)
    return (out:match("1") ~= nil)
end

return M
