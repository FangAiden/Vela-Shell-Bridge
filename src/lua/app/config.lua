-- config.lua
-- 全局路径配置，所有模块统一从这里读取，避免硬编码重复

local CONFIG = {}

-- Lua 根目录（你可随时改这个，不影响其他模块）
CONFIG.BASE_DIR = "/data/app/watchface/market/167210065/lua"

-- 业务数据文件目录
CONFIG.DATA_DIR = CONFIG.BASE_DIR .. "/data"

-- 临时文件目录（执行 shell 输出）
CONFIG.TMP_DIR = CONFIG.BASE_DIR .. "/tmp"

-- 快应用的根目录（用于 IPC）
CONFIG.QUICKAPP_BASE = "/data/files"

-- 管理器 AppA 的 AppID（权限管理器）
CONFIG.ADMIN_APP_ID = "com.lua.dev.template"

return CONFIG
