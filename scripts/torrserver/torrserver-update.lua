local mp = require("mp")
local utils = require("mp.utils")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))

local release_api = "https://api.github.com/repos/YouROK/TorrServer/releases/latest"
local api_timeout = 20
local download_timeout = 300
local download_retries = 3
local download_retry_delay = 2

local function run_command(args)
    local result = platform.run_subprocess(args)
    if not result or result.status ~= 0 then
        return nil, result and (result.stderr or result.error_string) or "no response"
    end
    return result.stdout or "", nil
end

-- Non-blocking counterpart of run_command; on_done(output, error_text).
local function run_command_async(args, on_done)
    platform.run_subprocess_async(args, function(success, result, err)
        if not success or not result or result.status ~= 0 then
            on_done(nil, result and (result.stderr or result.error_string) or (err and tostring(err)) or "no response")
        else
            on_done(result.stdout or "", nil)
        end
    end)
end

local function curl_base_args()
    local args = {
        "curl", "--silent", "--show-error", "--fail", "--ssl-revoke-best-effort",
        "--location",
    }
    -- Windows: avoid CRYPT_E_REVOCATION_OFFLINE when CRL/OCSP is unreachable
    if platform.is_windows then
        args[#args + 1] = "--ssl-no-revoke"
    end
    return args
end

local function append_args(args, ...)
    for i = 1, select("#", ...) do
        args[#args + 1] = select(i, ...)
    end
    return args
end

-- Local install name, kept short for typing at a terminal (unlike the
-- arch-qualified GitHub asset name used in asset_name_for).
local function default_bin_name(platform)
    return platform == "windows" and "TorrServer.exe" or "TorrServer"
end

-- Shared by installed_version and installed_version_async: pulls the version
-- string out of `bin_path --version` output.
local function parse_installed_version(output)
    if not output then return nil end
    local version = output:match("MatriX%.[%w%.%-]+")
    if version then return version end
    version = output:match("([%w%.%-]+)%s*$")
    if version and version ~= "" then return version end
    return nil
end

local function installed_version(bin_path)
    if not bin_path or bin_path == "" or not utils.file_info(bin_path) then
        return nil
    end
    return parse_installed_version(run_command({bin_path, "--version"}))
end

-- Non-blocking counterpart; on_done(version_or_nil). Used for the passive,
-- automatic update check so it never stalls mpv spawning the binary.
local function installed_version_async(bin_path, on_done)
    if not bin_path or bin_path == "" or not utils.file_info(bin_path) then
        on_done(nil)
        return
    end
    run_command_async({bin_path, "--version"}, function(output)
        on_done(parse_installed_version(output))
    end)
end

-- TorrServer's own asset-naming convention, mapped from the generic
-- arch bucket in platform.lua.
local arch_names = {x86_64 = "amd64", x86 = "386", arm64 = "arm64", arm = "arm7"}

local function torrserver_arch()
    return arch_names[platform.arch] or "amd64"
end

-- Exact asset name for current OS + arch (no gst builds).
local function asset_name_for(platform, arch)
    if platform == "windows" then
        return "TorrServer-windows-" .. arch .. ".exe"
    elseif platform == "macos" then
        return "TorrServer-darwin-" .. arch
    else
        return "TorrServer-linux-" .. arch
    end
end

-- Shared by latest_release and latest_release_async: turns the GitHub API
-- response body into a release table (or nil, error).
local function parse_release_response(output, err, platform)
    if not output then
        return nil, err or "failed to fetch latest release"
    end

    local ok, data = pcall(utils.parse_json, output)
    if not ok or type(data) ~= "table" then
        return nil, "invalid JSON from GitHub"
    end

    local version = data.tag_name or data.name
    if not version or version == "" then
        return nil, "no version in release"
    end
    version = version:gsub("^v", "")

    local arch = torrserver_arch()
    local wanted = asset_name_for(platform, arch)
    local url, size = nil, nil

    if type(data.assets) == "table" then
        for _, asset in ipairs(data.assets) do
            if type(asset) == "table"
                and asset.name == wanted
                and type(asset.browser_download_url) == "string"
            then
                url = asset.browser_download_url
                size = tonumber(asset.size)
                break
            end
        end
    end

    if not url then
        return nil, "no asset for " .. wanted
    end

    return {
        version = version,
        url = url,
        asset = wanted,
        size = size, -- bytes, may be nil; used for download progress only
    }, nil
end

local function latest_release(platform)
    local args = append_args(curl_base_args(), "--max-time", tostring(api_timeout), release_api)
    local output, err = run_command(args)
    return parse_release_response(output, err, platform)
end

-- Non-blocking counterpart; on_done(release_or_nil, error_text).
local function latest_release_async(platform, on_done)
    local args = append_args(curl_base_args(), "--max-time", tostring(api_timeout), release_api)
    run_command_async(args, function(output, err)
        on_done(parse_release_response(output, err, platform))
    end)
end

-- Wraps latest_release_async() with an on-disk TTL cache, so callers that
-- check passively/repeatedly (e.g. every time a menu returns to its root)
-- don't hit the release API on every single call, and never block mpv while
-- doing so. Falls back to a stale cached entry if the network call fails, so
-- a temporary outage doesn't erase the last known result.
local function cached_latest_release_async(platform, cache_path, ttl_seconds, on_done)
    local cached = shared.read_json_file(cache_path)
    local now = os.time()
    if cached and cached.checked_at and cached.release and (now - cached.checked_at) < (ttl_seconds or 86400) then
        on_done(cached.release, nil)
        return
    end

    latest_release_async(platform, function(release, err)
        if release then
            shared.write_json_file(cache_path, {checked_at = now, release = release}, true)
            on_done(release, nil)
            return
        end
        if cached and cached.release then
            on_done(cached.release, nil)
            return
        end
        on_done(nil, err)
    end)
end

-- Non-blocking download with progress. on_progress(percent) fires roughly
-- every 0.5s while total_size (bytes) is known; on_done(ok, error) fires once.
-- Progress is inferred from the destination file's size on disk since curl's
-- own progress meter writes to a terminal, not to captured stdout/stderr.
local function download_async(url, dest_path, total_size, on_progress, on_done)
    if not url or not dest_path then
        on_done(false, "missing url or destination")
        return
    end
    shared.ensure_dir(utils.split_path(dest_path))

    local args = append_args(
        curl_base_args(),
        "--max-time", tostring(download_timeout),
        "--retry", tostring(download_retries),
        "--retry-delay", tostring(download_retry_delay),
        "-o", dest_path,
        url
    )

    local progress_timer
    if total_size and total_size > 0 and on_progress then
        progress_timer = mp.add_periodic_timer(0.5, function()
            local info = utils.file_info(dest_path)
            if info then
                on_progress(math.floor(math.min(info.size / total_size, 1) * 100))
            end
        end)
    end

    platform.run_subprocess_async(args, function(success, result, err)
        if progress_timer then
            progress_timer:kill()
            progress_timer = nil
        end
        if not success or not result or result.status ~= 0 then
            local message = result and (result.stderr or result.error_string) or (err and tostring(err)) or "download failed"
            on_done(false, message)
            return
        end
        if not utils.file_info(dest_path) then
            on_done(false, "download finished but file missing")
            return
        end
        on_done(true, nil)
    end)
end

local function replace_binary(bin_path, tmp_path)
    if utils.file_info(bin_path) then
        os.remove(bin_path)
    end

    local renamed = os.rename(tmp_path, bin_path)
    if not renamed and platform.is_windows then
        run_command({
            "powershell", "-NoProfile", "-Command",
            string.format('Move-Item -Force -Path "%s" -Destination "%s"', tmp_path, bin_path),
        })
        renamed = utils.file_info(bin_path) ~= nil
    end

    if not renamed or not utils.file_info(bin_path) then
        return false, "failed to replace binary (file may be locked)"
    end

    if not platform.is_windows then
        run_command({"chmod", "+x", bin_path})
    end

    return true, nil
end

return {
    installed_version = installed_version,
    installed_version_async = installed_version_async,
    latest_release = latest_release,
    latest_release_async = latest_release_async,
    cached_latest_release_async = cached_latest_release_async,
    download_async = download_async,
    replace_binary = replace_binary,
    default_bin_name = default_bin_name,
}