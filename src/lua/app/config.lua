-- config.lua
-- Global path configuration for the Lua daemon.
-- Adjust these paths for real devices if needed.

local CONFIG = {}

-- Lua root directory (watchface Lua)
CONFIG.BASE_DIR = "/data/app/watchface/market/167210065/lua"

-- Business data directory
CONFIG.DATA_DIR = CONFIG.BASE_DIR .. "/data"

-- Temporary directory (shell output, job files)
CONFIG.TMP_DIR = CONFIG.BASE_DIR .. "/tmp"

-- QuickApp sandbox root (the actual path of internal://files). Used for IPC scanning.
CONFIG.QUICKAPP_BASE = "/data/files"

-- Installed app list (try in order)
-- Can be string or table (first readable file wins).
CONFIG.APPS_JSON = { "/data/apps.json", "/data/quickapp/apps.json" }

-- Installed package directories (try in order)
-- Can be string or table (first existing package dir wins).
CONFIG.APP_INSTALL_BASE = { "/data/quickapp/app", "/data/app", "/data/app/quickapp" }

-- Admin AppID (permission manager)
CONFIG.ADMIN_APP_ID = "com.lua.dev.template"

return CONFIG

