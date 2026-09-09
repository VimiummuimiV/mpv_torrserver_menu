-- Shared filesystem/JSON helpers for mpv scripts.
-- Place at scripts/modules/utils.lua so other scripts can do
-- `dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))`.

local utils = require("mp.utils")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))

local M = {}

function M.ensure_dir(dir)
    if not dir or dir == "" or utils.file_info(dir) then return end
    if platform.is_windows then
        os.execute('mkdir "' .. dir .. '"') -- cmd's mkdir creates intermediate dirs itself
    else
        os.execute('mkdir -p "' .. dir .. '"')
    end
end

function M.read_json_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(utils.parse_json, content)
    return (ok and type(data) == "table") and data or nil
end

function M.write_json_file(path, data, pretty)
    M.ensure_dir(utils.split_path(path))
    local f = io.open(path, "w")
    if not f then return end
    local json_str = utils.format_json(data)
    f:write(pretty and M.pretty_json(json_str) or json_str)
    f:close()
end

-- Reformats compact JSON (as produced by utils.format_json) into indented,
-- human-readable JSON, so on-disk files stay easy to read/diff.
local json_indent_unit = "  " -- 2 spaces

local function pretty_json(json_str)
    local out, depth, in_str, i, len = {}, 0, false, 1, #json_str
    while i <= len do
        local c = json_str:sub(i, i)
        if in_str then
            out[#out + 1] = c
            if c == "\\" then
                i = i + 1
                out[#out + 1] = json_str:sub(i, i)
            elseif c == "\"" then
                in_str = false
            end
        elseif c == "\"" then
            in_str = true
            out[#out + 1] = c
        elseif c == "{" or c == "[" then
            local next_c = json_str:sub(i + 1, i + 1)
            if next_c == "}" or next_c == "]" then
                out[#out + 1] = c .. next_c
                i = i + 1
            else
                depth = depth + 1
                out[#out + 1] = c .. "\n" .. json_indent_unit:rep(depth)
            end
        elseif c == "}" or c == "]" then
            depth = depth - 1
            out[#out + 1] = "\n" .. json_indent_unit:rep(depth) .. c
        elseif c == "," then
            out[#out + 1] = ",\n" .. json_indent_unit:rep(depth)
        elseif c == ":" then
            out[#out + 1] = ": "
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end
M.pretty_json = pretty_json

function M.encode_path(path)
    local encoded = {}
    for part in path:gmatch("[^/]+") do
        encoded[#encoded + 1] = part:gsub("([^%w%._%-~])", function(char)
            return string.format("%%%02X", char:byte())
        end)
    end
    return table.concat(encoded, "/")
end

function M.format_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes <= 0 then return "0 B" end
    local units = {"B", "KB", "MB", "GB", "TB"}
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format(i == 1 and "%d %s" or "%.2f %s", bytes, units[i])
end

function M.format_speed(bytes_per_sec)
    bytes_per_sec = tonumber(bytes_per_sec) or 0
    if bytes_per_sec <= 0 then return "--" end
    return M.format_size(bytes_per_sec) .. "/s"
end

local function utf8_codepoint(s, i)
    local b1 = s:byte(i)
    if not b1 then return nil, 0 end
    if b1 < 0x80 then return b1, 1
    elseif b1 >= 0xF0 then return b1, 4
    elseif b1 >= 0xE0 then return b1, 3
    elseif b1 >= 0xC0 then return b1, 2
    else return b1, 1 end
end

-- Counts codepoints; with `limit` also stops early and returns the byte
-- prefix cut at that many codepoints (used for both length checks and the
-- hard-cut fallback in M.elide()).
local function utf8_len(s, limit)
    local count, i, len = 0, 1, #s
    while i <= len do
        local cp, size = utf8_codepoint(s, i)
        if not cp then break end
        count = count + 1
        if limit and count > limit then return limit, s:sub(1, i - 1) end
        i = i + size
    end
    return count, s
end

-- Truncates to whole words: a word is kept in full once more than half of
-- it already fits within max_chars, otherwise it's dropped entirely.
function M.elide(str, max_chars, enabled)
    if enabled == false or utf8_len(str) <= max_chars then return str end
    local parts, len, truncated = {}, 0, false
    for word in str:gmatch("%S+") do
        local sep = (#parts > 0) and 1 or 0
        local wlen = utf8_len(word)
        if len + sep + wlen <= max_chars then
            parts[#parts + 1] = word
            len = len + sep + wlen
        else
            local avail = max_chars - len - sep
            if avail >= wlen / 2 then parts[#parts + 1] = word end
            truncated = true
            break
        end
    end
    if #parts == 0 then return select(2, utf8_len(str, max_chars)) .. "…" end
    return truncated and (table.concat(parts, " ") .. "…") or table.concat(parts, " ")
end

return M