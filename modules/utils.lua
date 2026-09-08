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

return M