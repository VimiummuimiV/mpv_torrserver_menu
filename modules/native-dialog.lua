-- Shared native file-picker dialog for mpv scripts (Windows/macOS/Linux).
-- Place at scripts/modules/native-dialog.lua so other scripts can do
-- `require "native-dialog"`.

local mp = require("mp")
local utils = require("mp.utils")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))

local M = {}

M.platform = platform.current

local cache_dir = mp.command_native({"expand-path", "~~/cache"})

local function run_subprocess(args)
    return platform.run_subprocess(args)
end

local function parse_lines(content)
    local files = {}
    for line in content:gmatch("[^\r\n]+") do
        files[#files + 1] = line
    end
    return #files > 0 and files or nil
end

local function command_exists(cmd)
    local result = run_subprocess({"sh", "-c", "command -v " .. cmd})
    return result and result.status == 0 and result.stdout and result.stdout:match("%S") ~= nil
end

--- Windows: System.Windows.Forms.OpenFileDialog ------------------------

local function windows_filter(filters)
    local parts = {}
    for _, filt in ipairs(filters or {}) do
        local patterns = {}
        for _, ext in ipairs(filt.patterns) do
            patterns[#patterns + 1] = "*." .. ext
        end
        local joined = table.concat(patterns, ";")
        parts[#parts + 1] = filt.label .. " (" .. joined .. ")|" .. joined
    end
    parts[#parts + 1] = "All files (*.*)|*.*"
    return table.concat(parts, "|")
end

local function choose_files_windows(opts)
    shared.ensure_dir(cache_dir)
    local result_path = utils.join_path(cache_dir, "native-dialog-result.txt")
    os.remove(result_path)

    local initial_dir_expr
    if opts.initial_dir and opts.initial_dir ~= "" then
        initial_dir_expr = string.format('"%s"', opts.initial_dir:gsub('"', '`"'))
    else
        initial_dir_expr = "[System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyVideos)"
    end

    -- Piped PowerShell stdout mangles non-ASCII text; write UTF-8 to a file instead.
    local ps_cmd = string.format([[
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "%s"
$dialog.InitialDirectory = %s
$dialog.Filter = "%s"
$dialog.Multiselect = $%s
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines("%s", $dialog.FileNames, $utf8NoBom)
}
]], opts.title, initial_dir_expr, windows_filter(opts.filters),
    opts.multiselect and "true" or "false", result_path)

    local result = run_subprocess({"powershell", "-NoProfile", "-Command", ps_cmd})
    if not result or result.status ~= 0 then
        return nil, result and (result.stderr or result.error_string) or "dialog failed"
    end

    local f = io.open(result_path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    os.remove(result_path)
    return parse_lines(content)
end

--- macOS: AppleScript "choose file" -------------------------------------

local function macos_type_list(filters)
    local exts = {}
    for _, filt in ipairs(filters or {}) do
        for _, ext in ipairs(filt.patterns) do
            exts[#exts + 1] = '"' .. ext .. '"'
        end
    end
    if #exts == 0 then return "" end
    return " of type {" .. table.concat(exts, ", ") .. "}"
end

local function choose_files_macos(opts)
    shared.ensure_dir(cache_dir)
    local result_path = utils.join_path(cache_dir, "native-dialog-result.txt")
    local script_path = utils.join_path(cache_dir, "native-dialog.applescript")
    os.remove(result_path)

    local as_script = string.format([[
try
    set theResult to choose file with prompt "%s" multiple selections allowed %s%s
on error
    return
end try
set output to ""
if class of theResult is list then
    repeat with f in theResult
        set output to output & POSIX path of f & linefeed
    end repeat
else
    set output to POSIX path of theResult & linefeed
end if
set outFile to open for access (POSIX file "%s") with write permission
set eof outFile to 0
write output as «class utf8» to outFile
close access outFile
]], opts.title, opts.multiselect and "true" or "false", macos_type_list(opts.filters), result_path)

    local f = io.open(script_path, "w")
    if not f then return nil, "could not write applescript file" end
    f:write(as_script)
    f:close()

    local result = run_subprocess({"osascript", script_path})
    os.remove(script_path)
    if not result or result.status ~= 0 then
        return nil, result and (result.stderr or result.error_string) or "dialog failed"
    end

    local rf = io.open(result_path, "rb")
    if not rf then return nil end
    local content = rf:read("*a")
    rf:close()
    os.remove(result_path)
    return parse_lines(content)
end

--- Linux: zenity / kdialog ----------------------------------------------

local function linux_filter_args(filters)
    local args = {}
    for _, filt in ipairs(filters or {}) do
        local patterns = {}
        for _, ext in ipairs(filt.patterns) do
            patterns[#patterns + 1] = "*." .. ext
        end
        args[#args + 1] = "--file-filter=" .. filt.label .. " | " .. table.concat(patterns, " ")
    end
    return args
end

local function choose_files_linux(opts)
    if command_exists("zenity") then
        local args = {"zenity", "--file-selection", "--title=" .. opts.title, "--separator=\n"}
        if opts.multiselect then args[#args + 1] = "--multiple" end
        if opts.initial_dir and opts.initial_dir ~= "" then
            args[#args + 1] = "--filename=" .. opts.initial_dir .. "/"
        end
        for _, a in ipairs(linux_filter_args(opts.filters)) do args[#args + 1] = a end

        local result = run_subprocess(args)
        if not result or not result.stdout or result.stdout == "" then return nil end
        return parse_lines(result.stdout)
    end

    if command_exists("kdialog") then
        local args = {"kdialog", "--getopenfilename", opts.initial_dir or ".", "--title", opts.title}
        if opts.multiselect then
            table.insert(args, 2, "--separate-output")
            table.insert(args, 2, "--multiple")
        end
        local result = run_subprocess(args)
        if not result or not result.stdout or result.stdout == "" then return nil end
        return parse_lines(result.stdout)
    end

    return nil, "no supported file dialog found (install zenity or kdialog)"
end

--- public API -------------------------------------------------------

-- opts = { title, filters = {{label, patterns = {"mkv", "mp4", ...}}, ...},
--          multiselect = bool, initial_dir = string }
-- Returns a list of selected paths, or nil (+ optional error message) if
-- nothing was picked / the dialog failed.
function M.choose_files(opts)
    opts = opts or {}
    opts.title = opts.title or "Open file"
    if M.platform == "windows" then
        return choose_files_windows(opts)
    elseif M.platform == "macos" then
        return choose_files_macos(opts)
    else
        return choose_files_linux(opts)
    end
end

return M