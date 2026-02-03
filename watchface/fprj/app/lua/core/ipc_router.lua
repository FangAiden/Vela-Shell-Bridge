-- app/core/ipc_router.lua
-- Request router: dispatches to usecases.

local responses = require("core.ipc_responses")
local exec_usecase = require("usecases.exec")
local mgmt_usecase = require("usecases.management")

local M = {}

function M.route_request(ctx, app_id, req)
    if req.type == "exec" then
        return exec_usecase.handle(app_id, req, ctx)
    elseif req.type == "management" then
        return mgmt_usecase.handle(app_id, req, ctx)
    end
    return responses.error(req.id, "BAD_REQUEST", "Unknown request type: " .. tostring(req.type))
end

return M
