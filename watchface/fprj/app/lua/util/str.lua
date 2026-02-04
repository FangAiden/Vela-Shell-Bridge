-- app/util/str.lua
-- Common string utilities.

local M = {}

function M.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.trim_trailing_slashes(p)
    if type(p) ~= "string" then return "" end
    return (p:gsub("/+$", ""))
end

--- Safely quote a string for shell usage.
--- Uses single quotes to avoid shell expansion of $, `, \, etc.
--- Single quotes inside the string are escaped as: '\''
function M.sh_quote(s)
    s = tostring(s or "")
    -- Use single quotes: safe from $, `, \, ! expansion
    -- Escape embedded single quotes by ending the string, adding escaped quote, and restarting
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.safe_str(v)
    if v == nil then return "" end
    return tostring(v)
end

function M.first_token(cmd)
    if type(cmd) ~= "string" then return "" end
    return cmd:match("^%s*(%S+)") or ""
end

function M.strip_quotes(s)
    local t = M.trim(s)
    if #t >= 2 then
        local a = t:sub(1, 1)
        local b = t:sub(-1)
        if (a == '"' and b == '"') or (a == "'" and b == "'") then
            return t:sub(2, -2)
        end
    end
    return t
end

function M.trim_text(s, max_len)
    if type(s) ~= "string" then return "" end
    if not max_len or max_len <= 0 then return s end
    if #s <= max_len then return s end
    return s:sub(1, max_len) .. "\n...(truncated)"
end

return M
