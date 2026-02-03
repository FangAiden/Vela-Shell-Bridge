-- app/config.lua
-- Global path and daemon configuration.

local CONFIG = {}

-- Lua root directory (watchface Lua)
CONFIG.BASE_DIR = "/data/app/watchface/market/219667632/lua"

-- Business data directory
CONFIG.DATA_DIR = CONFIG.BASE_DIR .. "/data"

-- Temporary directory (shell output, job files)
CONFIG.TMP_DIR = CONFIG.BASE_DIR .. "/tmp"

-- QuickApp sandbox root (the actual path of internal://files). Used for IPC scanning.
CONFIG.QUICKAPP_BASE = "/data/files"

-- Log limits
CONFIG.MAX_EXEC_LOGS = 80
CONFIG.MAX_OUTPUT_LEN = 2048
CONFIG.EXEC_LOG_MAX_BYTES = 200 * 1024
CONFIG.STATS_FLUSH_MIN_INTERVAL_SEC = 2

-- Daemon timer
CONFIG.DAEMON_PERIOD_DEFAULT_MS = 300
CONFIG.DAEMON_PERIOD_MIN_MS = 50
CONFIG.DAEMON_PERIOD_MAX_MS = 2000

-- Installed app list (try in order)
CONFIG.APPS_JSON = { "/data/apps.json", "/data/quickapp/apps.json" }

-- Installed package directories (try in order)
CONFIG.APP_INSTALL_BASE = { "/data/quickapp/app", "/data/app", "/data/app/quickapp" }

-- Admin AppID (permission manager)
CONFIG.ADMIN_APP_ID = "com.super.su.aigik"

return CONFIG
