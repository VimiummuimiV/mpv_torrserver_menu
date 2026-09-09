-- TorrServer's own HTTP API (distinct from the JacRed search APIs in search-api.lua).
-- Full reference: https://github.com/YouROK/TorrServer/wiki
--
-- POST /torrents  { action, link, hash, title, poster, data, save_to_db }
--   action  "add" | "get" | "set" | "rem" | "list" | "drop" | "wipe"
--     add   adds a torrent (link = magnet/hash/URL); returns the torrent object
--     list  returns every torrent as a JSON array
--     rem   removes a torrent permanently
--     drop  stops a torrent's downloads without removing it (used before rem,
--           since TorrServer refuses to rem a torrent that's still streaming)
--     get/set/wipe are not used by this script
--   link, hash, title, poster, data, save_to_db are the other request fields;
--   only link (add), hash (rem/drop), and save_to_db (add) are used here.
--
--   Torrent object fields actually read by this script:
--     hash / infohash / id             string  info hash
--     title / Title / name             string  torrent title
--     data                             string  custom JSON, may embed a
--                                               nested TorrServer.Title
--     file_stats / files / filelist    array   files in the torrent
--   File object fields actually read by this script:
--     length / Length                  number  file size in bytes
--     path / name / title              string  file path/name within torrent
--     id / index / num                 number  file index (defaults to 0)
--
-- POST /torrent/upload  (multipart form)
--   file          the .torrent file
--   save_to_db    true/false
--
-- GET /stream/{path}?link={hash}&index={index}&play
--   Streams a single file from an added torrent.

local mp = require("mp")
local utils = require("mp.utils")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))

local unpack = table.unpack or unpack

local M = {}

local paths = {
    torrents = "/torrents",
    upload = "/torrent/upload",
    stream = "/stream/",
}
M.actions = {
    list = "list",
    add = "add",
    remove = "rem",
    drop = "drop",
}
local torrent_fields = {
    hash = {"hash", "infohash", "id"},
    title = {"title", "Title", "name"},
    files = {"file_stats", "files", "filelist"},
}
local file_fields = {
    length = {"length", "Length"},
    path = {"path", "name", "title"},
    index = {"id", "index", "num"},
}

-- Returns obj[key] for the first key that isn't nil. TorrServer disagrees
-- with itself on field-name casing/spelling for the same data depending on
-- version/endpoint, so this is the one place that decides which alias wins.
local function field(obj, ...)
    for i = 1, select("#", ...) do
        local v = obj[(select(i, ...))]
        if v ~= nil then return v end
    end
    return nil
end

local function torrent_field(torrent, key)
    return field(torrent, unpack(torrent_fields[key]))
end

local function file_field(file, key)
    return field(file, unpack(file_fields[key]))
end

function M.torrent_hash(torrent)
    return torrent_field(torrent, "hash")
end

function M.torrent_title(torrent)
    local title = torrent_field(torrent, "title")
    if title then return title end

    if type(torrent.data) == "string" then
        local ok, parsed = pcall(utils.parse_json, torrent.data)
        if ok and type(parsed) == "table" then
            return field(parsed, "Title") or (parsed.TorrServer and field(parsed.TorrServer, "Title"))
        end
    end
    return nil
end

function M.torrent_files(torrent)
    local files = torrent_field(torrent, "files")
    if type(files) == "table" then return files end

    local data = torrent.data
    if type(data) == "string" then
        local ok, parsed = pcall(utils.parse_json, data)
        data = ok and parsed or nil
    end
    if type(data) ~= "table" then return {} end
    if data.TorrServer and type(data.TorrServer.Files) == "table" then
        return data.TorrServer.Files
    end
    return field(data, "Files", "files") or data
end

function M.response_list(response)
    local list = response and (response.Results or response.torrents or response.data or response)
    return type(list) == "table" and list or nil
end

function M.find_added_torrent(response, hash)
    if type(response) == "table" and M.torrent_hash(response) then
        return response
    end
    local list = M.response_list(response)
    if not list then return nil end
    for _, torrent in pairs(list) do
        if type(torrent) == "table" and M.torrent_hash(torrent) == hash then
            return torrent
        end
    end
    return nil
end

function M.torrent_stat_hint(torrent)
    local size = torrent.torrent_size or torrent.TorrentSize
    if not size then return nil end
    local speed = torrent.download_speed or torrent.DownloadSpeed
    local peers = torrent.active_peers or torrent.ActivePeers or 0
    local seeds = torrent.connected_seeders or torrent.ConnectedSeeders or 0
    return shared.format_size(size) .. " · " .. shared.format_speed(speed) .. " · " .. peers .. "/" .. seeds
end

local function file_title(file)
    return file_field(file, "path") or ("File " .. tostring(file_field(file, "index") or "?"))
end
M.file_title = file_title

-- opts: {torr_server, request_timeout, bin_path, browser_path} (see torrserver.conf)
function M.new(opts)
    local api = {}
    local base_url = (opts.torr_server or ""):gsub("/$", "")
    local pid = nil

    function api.stream_url(file, hash)
        local index = file_field(file, "index") or 0
        return base_url .. paths.stream .. shared.encode_path(file_title(file))
            .. "?link=" .. hash .. "&index=" .. tostring(index) .. "&play"
    end

    function api.file_items(torrent)
        local hash = M.torrent_hash(torrent)
        local items = {}
        for _, file in pairs(M.torrent_files(torrent)) do
            if type(file) == "table" then
                local size = tonumber(file_field(file, "length"))
                items[#items + 1] = {
                    title = file_title(file),
                    hint = size and size > 0 and shared.format_size(size) or nil,
                    icon = "movie",
                    value = {"loadfile", api.stream_url(file, hash), "replace"},
                }
            end
        end
        table.sort(items, function(a, b) return a.title < b.title end)
        return items
    end

    local function run_curl(args)
        local result = platform.run_subprocess(args)
        if not result or result.status ~= 0 then
            return nil, result and (result.stderr or result.error_string) or "no response"
        end
        return result.stdout or "", nil
    end

    local function request_args(method, path, body, timeout, retries)
        local args = {
            "curl", "--silent", "--show-error", "--fail", "--ssl-revoke-best-effort",
            "--max-time", tostring(timeout or opts.request_timeout),
            -- TorrServer's HTTP socket isn't open the instant the process starts.
            "--retry", tostring(retries or 5), "--retry-delay", "1", "--retry-connrefused",
        }
        if method == "POST" then
            args[#args + 1] = "-X"
            args[#args + 1] = "POST"
            args[#args + 1] = "-H"
            args[#args + 1] = "Content-Type: application/json"
            args[#args + 1] = "--data-binary"
            args[#args + 1] = utils.format_json(body)
        end
        args[#args + 1] = base_url .. path
        return args
    end
    api.request_args = request_args

    function api.request_json(method, path, body, timeout, retries)
        local args = request_args(method, path, body, timeout, retries)
        local output, error_text = run_curl(args)
        if not output then return nil, error_text end
        if output == "" then return true, nil end
        local ok, data = pcall(utils.parse_json, output)
        if not ok or not data then return nil, "invalid JSON response" end
        return data, nil
    end

    local function curl_form_path(path)
        local escaped = path:gsub("\\", "\\\\"):gsub('"', '\\"')
        return '"' .. escaped .. '"'
    end

    function api.request_upload(filepath)
        local args = {
            "curl", "--silent", "--show-error", "--fail", "--ssl-revoke-best-effort",
            "--max-time", tostring(opts.request_timeout),
            "--retry", "5", "--retry-delay", "1", "--retry-connrefused",
            "-F", "file=@" .. curl_form_path(filepath),
            "-F", "save_to_db=true",
            base_url .. paths.upload,
        }
        local output, error_text = run_curl(args)
        if not output then return nil, error_text end
        local ok, data = pcall(utils.parse_json, output)
        if not ok or not data then return nil, "invalid JSON response" end
        return data, nil
    end

    -- Starts the local TorrServer process if it isn't already running.
    -- Returns true/false, error_message (error_message is nil when already running).
    function api.start(bin_path)
        if pid then return true end
        if not utils.file_info(bin_path) then
            return false, "TorrServer not found at: " .. bin_path
        end

        local ps_cmd = string.format(
            'Start-Process -FilePath "%s" -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id',
            bin_path
        )
        local result = platform.run_subprocess({"powershell.exe", "-NoProfile", "-Command", ps_cmd})

        if result and result.status == 0 and result.stdout then
            pid = tonumber(result.stdout:match("%d+"))
            if pid then
                mp.msg.info("TorrServer started (PID: " .. pid .. ")")
                return true
            end
        end

        return false, "Failed to start TorrServer: " .. (result and result.stderr or "unknown error")
    end

    function api.stop()
        if not pid then return end
        platform.run_subprocess({"taskkill.exe", "/PID", tostring(pid), "/T", "/F"})
        mp.msg.info("TorrServer stopped (PID: " .. pid .. ")")
        pid = nil
    end

    function api.open_ui()
        platform.open_url(opts.torr_server, opts.browser_path)
    end

    -- Async metadata poll: retries up to `retries` times, `delay` seconds apart,
    -- using a timer + non-blocking subprocess so the menu stays responsive and
    -- the wait can be cancelled by the caller (poll.cancelled = true) instead of
    -- blocking mpv while retrying. on_progress(attempt, total) fires before each
    -- try; on_done(torrent, items, error_text) fires once, or never if cancelled
    -- first. Returns the poll handle so the caller can cancel it.
    function api.poll_metadata_async(hash, retries, delay, on_progress, on_done)
        local poll = {cancelled = false, hash = hash}
        local attempt = 0

        local function step()
            if poll.cancelled then return end
            attempt = attempt + 1
            on_progress(attempt, retries)
            local args = request_args("POST", paths.torrents, {action = M.actions.list})
            platform.run_subprocess_async(args, function(success, result, err)
                if poll.cancelled then return end
                local torrent, items, error_text
                if success and result and result.status == 0 then
                    local ok, list_response = pcall(utils.parse_json, result.stdout or "")
                    if ok and list_response then
                        torrent = M.find_added_torrent(list_response, hash)
                        if not torrent and not hash and type(list_response[1]) == "table" then
                            torrent = list_response[1]
                        end
                        items = torrent and api.file_items(torrent) or {}
                    else
                        error_text = "invalid JSON response"
                    end
                else
                    error_text = result and (result.stderr or result.error_string) or (err and tostring(err)) or "no response"
                end

                if items and #items > 0 then
                    on_done(torrent, items, nil)
                elseif attempt >= retries then
                    on_done(torrent, items or {}, error_text)
                else
                    mp.add_timeout(delay, step)
                end
            end)
        end
        step()
        return poll
    end

    function api.list(on_done)
        local args = request_args("POST", paths.torrents, {action = M.actions.list})
        platform.run_subprocess_async(args, function(success, result, err)
            if not success or not result or result.status ~= 0 then
                on_done(nil)
                return
            end
            local ok, list_response = pcall(utils.parse_json, result.stdout or "")
            on_done(ok and list_response or nil)
        end)
    end

    local function torrent_action(action, hash)
        local _, error_text = api.request_json("POST", paths.torrents, {action = action, hash = hash})
        return error_text == nil, error_text
    end

    function api.drop(hash)
        return torrent_action(M.actions.drop, hash)
    end

    -- Caller is expected to api.drop(hash) first: TorrServer refuses to "rem"
    -- a torrent that's still actively streaming.
    function api.remove(hash)
        return torrent_action(M.actions.remove, hash)
    end

    function api.add(link)
        return api.request_json("POST", paths.torrents, {action = M.actions.add, link = link, save_to_db = true})
    end

    return api
end

return M
