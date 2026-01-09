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

-- IPC optimization: fixed-slot mailbox.
-- Must match JS client (src/services/su-daemon/ipc-client.js + tools/su-shell.js).
CONFIG.IPC_SLOT_COUNT = 2

-- Hot/cold backoff for per-app pending checks (ms). Applied on top of daemon tick period.
CONFIG.IPC_COLD_BASE_MS = 200
CONFIG.IPC_COLD_MAX_MS = 5000

-- Log optimization:
-- - exec history uses append-only NDJSON (data/exec_logs.ndjson), rotated by size
-- - request stats flush is throttled to reduce flash writes
CONFIG.EXEC_LOG_MAX_BYTES = 200 * 1024
CONFIG.STATS_FLUSH_MIN_INTERVAL_SEC = 2

-- Installed app list (try in order)
-- Can be string or table (first readable file wins).
CONFIG.APPS_JSON = { "/data/apps.json", "/data/quickapp/apps.json" }

-- Installed package directories (try in order)
-- Can be string or table (first existing package dir wins).
CONFIG.APP_INSTALL_BASE = { "/data/quickapp/app", "/data/app", "/data/app/quickapp" }

-- Admin AppID (permission manager)
CONFIG.ADMIN_APP_ID = "com.super.su.aigik"

return CONFIG

