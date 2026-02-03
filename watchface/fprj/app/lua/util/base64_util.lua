-- util/base64_util.lua
-- Pure Lua base64 (encode/decode) for binary-safe IPC payloads.

local M = {}

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.encode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end

    return (
        (data:gsub(".", function(x)
            local byte = x:byte()
            local bits = ""
            for i = 8, 1, -1 do
                bits = bits .. (((byte % (2 ^ i) - byte % (2 ^ (i - 1))) > 0) and "1" or "0")
            end
            return bits
        end) .. "0000")
            :gsub("%d%d%d?%d?%d?%d?", function(x)
                if #x < 6 then
                    return ""
                end
                local c = 0
                for i = 1, 6 do
                    c = c + ((x:sub(i, i) == "1") and (2 ^ (6 - i)) or 0)
                end
                return B64_ALPHABET:sub(c + 1, c + 1)
            end)
            .. ({ "", "==", "=" })[#data % 3 + 1]
    )
end

function M.decode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end

    data = data:gsub("[^" .. B64_ALPHABET .. "=]", "")

    return (
        data:gsub(".", function(x)
            if x == "=" then
                return ""
            end
            local idx = B64_ALPHABET:find(x, 1, true)
            if not idx then
                return ""
            end
            local f = idx - 1
            local bits = ""
            for i = 6, 1, -1 do
                bits = bits .. (((f % (2 ^ i) - f % (2 ^ (i - 1))) > 0) and "1" or "0")
            end
            return bits
        end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
            if #x ~= 8 then
                return ""
            end
            local c = 0
            for i = 1, 8 do
                c = c + ((x:sub(i, i) == "1") and (2 ^ (8 - i)) or 0)
            end
            return string.char(c)
        end)
    )
end

return M

