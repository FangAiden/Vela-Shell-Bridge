-- app/core/ipc_responses.lua
-- IPC response helpers shared by router/usecases.

local M = {}

function M.ok(req_id, data)
    return {
        id = req_id,
        ok = true,
        data = data
    }
end

function M.error(req_id, code, message, extra)
    local resp = {
        id = req_id,
        ok = false,
        error = { code = code, message = message },
        message = message
    }
    if extra then
        for k, v in pairs(extra) do
            resp[k] = v
        end
    end
    return resp
end

return M
