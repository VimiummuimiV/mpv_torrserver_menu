-- Shared OS/architecture detection and process utilities for mpv scripts.
-- Place at scripts/modules/platform.lua so other scripts can do
-- `dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))`.

local mp = require("mp")

local function detect_os()
    if os.getenv("windir") or package.config:sub(1, 1) == "\\" then
        return "windows"
    end
    local handle = io.popen("uname -s 2>/dev/null")
    if handle then
        local name = handle:read("*l")
        handle:close()
        if name == "Darwin" then return "macos" end
    end
    return "linux"
end

-- Generic bucket, independent of any project's asset-naming convention:
-- "x86_64", "x86", "arm64", "arm"
local function detect_arch(is_windows)
    if is_windows then
        local arch = (os.getenv("PROCESSOR_ARCHITECTURE") or ""):upper()
        if arch:find("ARM64", 1, true) then return "arm64" end
        if arch:find("64", 1, true) then return "x86_64" end
        return "x86"
    end

    local handle = io.popen("uname -m 2>/dev/null")
    local output = handle and (handle:read("*l") or "") or ""
    if handle then handle:close() end
    output = output:lower()

    if output:match("aarch64") or output:match("arm64") then return "arm64" end
    if output:match("armv7") or output:match("armhf") or output == "arm" then return "arm" end
    if output:match("i[3-6]86") or output == "x86" then return "x86" end
    return "x86_64"
end

local M = {}
M.current = detect_os()
M.is_windows = M.current == "windows"
M.arch = detect_arch(M.is_windows)

function M.trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- process helpers -------------------------------------------------------

local function subprocess_request(args, extra)
    local request = {
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }
    if extra then
        for k, v in pairs(extra) do request[k] = v end
    end
    return request
end

-- Blocks until completion. Returns the raw mp.command_native subprocess
-- result table, or nil if the call itself could not be made.
function M.run_subprocess(args, extra)
    return mp.command_native(subprocess_request(args, extra))
end

-- Same as run_subprocess but non-blocking; callback(success, result, error)
-- fires once the process exits, per mp.command_native_async semantics.
function M.run_subprocess_async(args, callback, extra)
    mp.command_native_async(subprocess_request(args, extra), callback)
end

function M.sleep(seconds)
    if M.is_windows then
        M.run_subprocess({"powershell", "-NoProfile", "-Command", "Start-Sleep -Seconds " .. tostring(seconds)})
    else
        M.run_subprocess({"sleep", tostring(seconds)})
    end
end

-- Opens a URL with an explicit browser path, or the OS default handler.
function M.open_url(url, browser_path)
    local args
    if browser_path and browser_path ~= "" then
        args = {browser_path, url}
    elseif M.current == "windows" then
        args = {"powershell.exe", "-NoProfile", "-Command", 'Start-Process "' .. url .. '"'}
    elseif M.current == "macos" then
        args = {"open", url}
    else
        args = {"xdg-open", url}
    end
    M.run_subprocess(args, {detach = true})
end

function M.read_clipboard()
    local result
    if M.current == "windows" then
        result = M.run_subprocess({
            "powershell", "-NoProfile", "-Command",
            "Get-Clipboard -Raw"
        })
    elseif M.current == "macos" then
        result = M.run_subprocess({"pbpaste"})
    else
        result = M.run_subprocess({"xclip", "-selection", "clipboard", "-o"})
    end

    local output = result and result.stdout or ""
    return M.trim(output)
end

function M.write_clipboard(text)
    if M.current == "windows" then
        M.run_subprocess({
            "powershell", "-NoProfile", "-Command",
            "Set-Clipboard -Value " .. string.format("%q", text or "")
        })
    elseif M.current == "macos" then
        M.run_subprocess({"pbcopy"}, {stdin_data = text})
    else
        M.run_subprocess(
            {"xclip", "-selection", "clipboard"},
            {stdin_data = text, detach = true}
        )
    end
end

return M