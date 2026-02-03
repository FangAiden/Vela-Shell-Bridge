-- util/base64_util.lua
-- High-performance base64 encode/decode using lookup tables

local M = {}

local ENCODE = {}
local DECODE = {}

-- Build lookup tables
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do
        local c = chars:sub(i, i)
        ENCODE[i - 1] = c
        DECODE[c:byte()] = i - 1
    end
    DECODE[string.byte("=")] = 0
end

function M.encode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end

    local result = {}
    local len = #data
    local i = 1

    -- Process 3 bytes at a time
    while i <= len - 2 do
        local b1, b2, b3 = data:byte(i, i + 2)
        result[#result + 1] = ENCODE[(b1 >> 2)]
        result[#result + 1] = ENCODE[((b1 & 3) << 4) | (b2 >> 4)]
        result[#result + 1] = ENCODE[((b2 & 15) << 2) | (b3 >> 6)]
        result[#result + 1] = ENCODE[(b3 & 63)]
        i = i + 3
    end

    -- Handle remaining bytes
    local remain = len - i + 1
    if remain == 2 then
        local b1, b2 = data:byte(i, i + 1)
        result[#result + 1] = ENCODE[(b1 >> 2)]
        result[#result + 1] = ENCODE[((b1 & 3) << 4) | (b2 >> 4)]
        result[#result + 1] = ENCODE[((b2 & 15) << 2)]
        result[#result + 1] = "="
    elseif remain == 1 then
        local b1 = data:byte(i)
        result[#result + 1] = ENCODE[(b1 >> 2)]
        result[#result + 1] = ENCODE[((b1 & 3) << 4)]
        result[#result + 1] = "=="
    end

    return table.concat(result)
end

function M.decode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end

    -- Remove non-base64 characters
    data = data:gsub("[^A-Za-z0-9+/=]", "")
    if data == "" then
        return ""
    end

    local result = {}
    local len = #data
    local i = 1

    -- Process 4 characters at a time
    while i <= len - 3 do
        local c1, c2, c3, c4 = data:byte(i, i + 3)
        local v1, v2, v3, v4 = DECODE[c1], DECODE[c2], DECODE[c3], DECODE[c4]

        if not (v1 and v2) then
            i = i + 4
        else
            result[#result + 1] = string.char((v1 << 2) | (v2 >> 4))

            if c3 ~= 61 and v3 then  -- '=' is 61
                result[#result + 1] = string.char(((v2 & 15) << 4) | (v3 >> 2))

                if c4 ~= 61 and v4 then
                    result[#result + 1] = string.char(((v3 & 3) << 6) | v4)
                end
            end
            i = i + 4
        end
    end

    return table.concat(result)
end

return M
