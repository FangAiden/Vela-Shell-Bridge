-- app/util/store.lua
-- Generic JSON file persistence with dirty tracking.

local fs   = require("util.fs_util")
local JSON = require("core.json")

local M = {}

function M.new(file_path, opts)
    opts = opts or {}
    local default_fn = opts.default or function() return {} end
    local normalize_fn = opts.normalize

    local store = {
        data  = default_fn(),
        dirty = false,
    }

    function store.load()
        local txt = fs.read_file(file_path)
        if not txt or txt == "" then
            store.data = default_fn()
            return
        end
        local ok, obj = pcall(JSON.decode, txt)
        if not ok or type(obj) ~= "table" then
            store.data = default_fn()
            return
        end
        if normalize_fn then
            store.data = normalize_fn(obj)
        else
            store.data = obj
        end
    end

    function store.save()
        local txt = JSON.encode(store.data)
        fs.write_file(file_path, txt)
        store.dirty = false
    end

    function store.save_if_dirty()
        if not store.dirty then return end
        store.save()
    end

    function store.mark_dirty()
        store.dirty = true
    end

    return store
end

return M
