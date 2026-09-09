-- TorrServer integration for mpv.
--
-- Provides a uosc menu for searching, adding, browsing, filtering, and
-- streaming torrents through a local TorrServer instance.
--
-- Search:
--   JacRed API: Native v1.0 or Jackett v2.0.
--
-- Supporting modules:
--   modules/native-dialog.lua      Cross-platform .torrent file picker.
--   modules/platform.lua           OS and architecture detection.
--   modules/torrserver-update.lua  TorrServer release/update management.
--   modules/utils.lua              Shared cache-dir/JSON file helpers.
--
-- Configuration:
--   torrserver.conf controls TorrServer, search API, paths, retry/polling
--   settings, history, and search size filters.
--
-- Storage:
--   ~~/cache/torrserver/torrserver-history.json       Played torrent history.
--   ~~/cache/torrserver/torrserver-state.json         UI preferences (search API, etc).
--   ~~/cache/torrserver/torrserver-update-check.json  Cached update-check result.
--   ~~/bin/                                           TorrServer binary.

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local native_dialog = dofile(mp.command_native({"expand-path", "~~/modules/native-dialog.lua"}))
local updater = dofile(mp.command_native({"expand-path", "~~/modules/torrserver-update.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))

local unpack = table.unpack or unpack
local script_name = mp.get_script_name()
local menu_type = "torrserver_menu"

local opts = {
    -- TorrServer (streams/hosts the torrent locally)
    torr_server = "http://localhost:8090",
    request_timeout = 15,
    -- search (JacRed; comma-separated = fallback order)
    search_server = "https://jac.red,https://jacred.stream",
    search_api = "native",
    search_api_key = "0",
    -- paths
    bin_path = "",
    browser_path = "",
    -- history
    history_limit = 20,
    stats_interval = 3,
    -- metadata polling (see poll_metadata_async)
    metadata_retries = 5,
    metadata_retry_delay = 2,
    -- search polling (see search_torrents); 5s × 2 ≈ 10s total
    search_timeout = 5,
    search_retries = 2,
    search_retry_delay = 1,
    -- comma-separated file size ranges (GB) for search results, "min-max" or "min-" for open-ended
    size_filters = "0-10,10-20,20-30,30-50,50-100,100-",
    -- minimum seconds between passive update checks (menu opening does not
    -- force a network call more often than this); clicking "Update TorrServer"
    -- always checks live regardless of this interval
    update_check_interval = 86400,
    -- menu title truncation
    elide_titles = true,
    title_max_chars = 60,
}
options.read_options(opts, "torrserver")

-- torrserver.conf keys stay flat above (mp.options can't bind nested
-- tables), grouped here once into the shape the rest of the script uses.
local metadata = {retries = opts.metadata_retries, delay = opts.metadata_retry_delay}
local search = {timeout = opts.search_timeout, retries = opts.search_retries, delay = opts.search_retry_delay}

local search_servers = {}
for token in (opts.search_server or ""):gmatch("[^,]+") do
    local s = token:match("^%s*(.-)%s*$")
    if s and s ~= "" then search_servers[#search_servers + 1] = s end
end

local size_filters = {}
for token in (opts.size_filters or ""):gmatch("[^,]+") do
    local s = token:match("^%s*(.-)%s*$")
    local min_s, max_s = s:match("^(%d*)%-(%d*)$")
    if min_s and min_s ~= "" then
        local min_gb, max_gb = tonumber(min_s), tonumber(max_s)
        local label
        if not max_gb then label = min_gb .. "+ GB"
        elseif min_gb == 0 then label = "< " .. max_gb .. " GB"
        else label = min_gb .. "-" .. max_gb .. " GB" end
        size_filters[#size_filters + 1] = {
            label = label,
            min = min_gb * 1024 ^ 3,
            max = max_gb and (max_gb * 1024 ^ 3) or math.huge,
        }
    end
end

local quality_filters = {
    {label = "480p", value = 480},
    {label = "720p", value = 720},
    {label = "1080p", value = 1080},
    {label = "4K", value = 2160},
}
local videotype_filters = {
    {label = "SDR", value = "sdr"},
    {label = "HDR", value = "hdr"},
}
-- value is matched against info.types; some UI labels cover several API values
local type_filters = {
    {label = "Movie", value = "movie", match = {"movie"}},
    {label = "Serial", value = "serial", match = {"serial"}},
    {label = "TV show", value = "tvshow", match = {"tvshow"}},
    {label = "Documentary", value = "documentary", match = {"documovie", "docuserial"}},
    {label = "Anime", value = "anime", match = {"anime", "ova", "ona"}},
    {label = "Cartoon", value = "multfilm", match = {"multfilm"}},
    {label = "Animated series", value = "multserial", match = {"multserial"}},
}

local torrserver_pid = nil
local history = {}
local stats = {}
local stats_timer = nil
local menu_view = nil -- "root" | "search" | "files" | "filters"
local playing = { hash = nil, index = nil } -- currently loaded stream in mpv
local available_update = nil -- { installed = "...", latest = "..." } when update is available
local last_search = nil -- { query, items, urls }
local filter_keys = {"text", "size", "seeds", "quality", "videotype", "type", "year", "lang", "dub"}
local empty_filters = {seeds = false, dub = false}
local filters = {}
for _, k in ipairs(filter_keys) do filters[k] = empty_filters[k] end
local last_opened_magnet = nil
-- torrent added to TorrServer but not yet committed to history; a torrent is
-- only worth remembering once a file from it actually gets played, so this
-- stays uncommitted (and gets removed from TorrServer) if the user backs out
-- of the file list instead.
local pending_entry = nil
local files_back = nil -- "back" | "back_search" while in files menu
local files_items = nil -- items currently shown in the files menu
local metadata_poll = nil -- {cancelled, hash} while poll_metadata_async is in flight

--- paths / cache -------------------------------------------------------

local function expand_path(path)
    return mp.command_native({"expand-path", path})
end

-- All of this script's own cache files live under their own subfolder, so
-- ~~/cache doesn't end up a flat pile shared with every other script.
local cache_dir = expand_path("~~/cache/torrserver")
local history_path = utils.join_path(cache_dir, "torrserver-history.json")
local state_path = utils.join_path(cache_dir, "torrserver-state.json")
local update_cache_path = utils.join_path(cache_dir, "torrserver-update-check.json")

-- Small persisted state (currently just the last-picked search API), distinct
-- from history: this is UI preference, not played-torrent history.
local function load_state()
    return shared.read_json_file(state_path) or {}
end

local function save_state(state)
    shared.write_json_file(state_path, state, true)
end

local trim = platform.trim

local function trim_base_url(url)
    return (url or ""):gsub("/$", "")
end

-- Cached once: opts.torr_server doesn't change at runtime. request_json still
-- accepts a `base` override (used for opts.search_server) via trim_base_url.
local torr_server_base = trim_base_url(opts.torr_server)

-- torrserver.conf's search_api is only the fallback for a fresh install (no
-- saved state yet); once the user switches via "Search API: ... (Click to
-- switch)" in the menu, that choice is remembered here across restarts.
local state = load_state()
local search_api = state.search_api or (opts.search_api == "jackett" and "jackett" or "native")

local function load_history()
    local data = shared.read_json_file(history_path)
    if data then history = data end
end

local function save_history()
    while #history > opts.history_limit do
        table.remove(history)
    end
    shared.write_json_file(history_path, history, true)
end

local function find_history(hash)
    for i, entry in ipairs(history) do
        if entry.hash == hash then return entry, i end
    end
    return nil, nil
end

local function remember_history(entry)
    local _, i = find_history(entry.hash)
    if i then table.remove(history, i) end
    table.insert(history, 1, entry)
    save_history()
end

local function forget_history(hash)
    local _, i = find_history(hash)
    if i then
        table.remove(history, i)
        save_history()
    end
    stats[hash] = nil
end

local function commit_pending()
    if pending_entry then
        remember_history(pending_entry)
        pending_entry = nil
    end
end

load_history()

--- torrent helpers ------------------------------------------------------

-- Returns obj[key] for the first key that isn't nil. TorrServer and the two
-- JacRed search APIs (native v1.0, Jackett v2.0) disagree on field-name
-- casing/spelling for the same data, so this is the one place that decides
-- which alias wins.
local function field(obj, ...)
    for i = 1, select("#", ...) do
        local v = obj[(select(i, ...))]
        if v ~= nil then return v end
    end
    return nil
end

-- Same idea as field(), but for picking between two already-fetched values
-- (e.g. a nested info.* table vs. a flat top-level one) rather than keys on
-- a single object.
local function first(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil then return v end
    end
    return nil
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
-- hard-cut fallback in elide()).
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
local function elide(str, max_chars)
    if not opts.elide_titles or utf8_len(str) <= max_chars then return str end
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

local function torrent_hash(torrent)
    return field(torrent, "hash", "infohash", "id")
end

local function torrent_title(torrent)
    local title = field(torrent, "title", "Title", "name")
    if title then return title end

    if type(torrent.data) == "string" then
        local ok, parsed = pcall(utils.parse_json, torrent.data)
        if ok and type(parsed) == "table" then
            return field(parsed, "Title") or (parsed.TorrServer and field(parsed.TorrServer, "Title"))
        end
    end
    return nil
end

local function torrent_files(torrent)
    local files = field(torrent, "file_stats", "files", "filelist")
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

local function response_list(response)
    local list = response and (response.Results or response.torrents or response.data or response)
    return type(list) == "table" and list or nil
end

local function find_added_torrent(response, hash)
    if type(response) == "table" and torrent_hash(response) then
        return response
    end
    local list = response_list(response)
    if not list then return nil end
    for _, torrent in pairs(list) do
        if type(torrent) == "table" and torrent_hash(torrent) == hash then
            return torrent
        end
    end
    return nil
end

local function format_size(bytes)
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

local function format_speed(bytes_per_sec)
    bytes_per_sec = tonumber(bytes_per_sec) or 0
    if bytes_per_sec <= 0 then return "--" end
    return format_size(bytes_per_sec) .. "/s"
end

local function torrent_stat_hint(torrent)
    local size = torrent.torrent_size or torrent.TorrentSize
    if not size then return nil end
    local speed = torrent.download_speed or torrent.DownloadSpeed
    local peers = torrent.active_peers or torrent.ActivePeers or 0
    local seeds = torrent.connected_seeders or torrent.ConnectedSeeders or 0
    return format_size(size) .. " · " .. format_speed(speed) .. " · " .. peers .. "/" .. seeds
end

local function encode_path(path)
    local encoded = {}
    for part in path:gmatch("[^/]+") do
        encoded[#encoded + 1] = part:gsub("([^%w%._%-~])", function(char)
            return string.format("%%%02X", char:byte())
        end)
    end
    return table.concat(encoded, "/")
end

local function file_title(file)
    return file.path or file.name or file.title or ("File " .. tostring(file.id or "?"))
end

local function stream_url(file, hash)
    local index = file.id or file.index or file.num or 0
    return torr_server_base .. "/stream/" .. encode_path(file_title(file))
        .. "?link=" .. hash .. "&index=" .. tostring(index) .. "&play"
end

local function file_items(torrent)
    local hash = torrent_hash(torrent)
    local items = {}
    for _, file in pairs(torrent_files(torrent)) do
        if type(file) == "table" then
            local size = tonumber(field(file, "length", "Length"))
            items[#items + 1] = {
                title = file_title(file),
                hint = size and size > 0 and format_size(size) or nil,
                icon = "movie",
                value = {"loadfile", stream_url(file, hash), "replace"},
            }
        end
    end
    table.sort(items, function(a, b) return a.title < b.title end)
    return items
end

local function is_magnet(value)
    return type(value) == "string" and value:match("^magnet:%?") ~= nil
end

local function magnet_hash(magnet)
    local hash = magnet:match("[?&]xt=urn:btih:([^&]+)")
    return hash and hash:lower()
end

--- process management ---------------------------------------------------

local function show_error(message)
    mp.osd_message("TorrServer: " .. message, 5)
    mp.msg.error(message)
end

local function default_bin_path()
    return expand_path("~~/bin/" .. updater.default_bin_name(native_dialog.platform))
end

local function resolved_bin_path()
    return opts.bin_path ~= "" and opts.bin_path or default_bin_path()
end

local function start_torrserver(silent)
    if torrserver_pid then return true end

    local bin_path = resolved_bin_path()
    if not utils.file_info(bin_path) then
        if not silent then
            show_error("TorrServer not found at: " .. bin_path)
        end
        return false
    end

    local ps_cmd = string.format(
        'Start-Process -FilePath "%s" -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id',
        bin_path
    )
    local result = platform.run_subprocess({"powershell.exe", "-NoProfile", "-Command", ps_cmd})

    if result and result.status == 0 and result.stdout then
        torrserver_pid = tonumber(result.stdout:match("%d+"))
        if torrserver_pid then
            mp.msg.info("TorrServer started (PID: " .. torrserver_pid .. ")")
            return true
        end
    end

    show_error("Failed to start TorrServer: " .. (result and result.stderr or "unknown error"))
    return false
end

local function stop_torrserver()
    if not torrserver_pid then return end
    platform.run_subprocess({"taskkill.exe", "/PID", tostring(torrserver_pid), "/T", "/F"})
    mp.msg.info("TorrServer stopped (PID: " .. torrserver_pid .. ")")
    torrserver_pid = nil
end

local function open_url(url)
    platform.open_url(url, opts.browser_path)
end

local function open_torrserver_ui()
    open_url(opts.torr_server)
end

-- "Open source" pauses playback instead of touching the stream, so leaving
-- the browser tab and hitting pause/play again just resumes where it was.
local function pause_if_playing(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        mp.set_property_bool("pause", true)
    end
end

local function run_curl(args)
    local result = platform.run_subprocess(args)
    if not result or result.status ~= 0 then
        return nil, result and (result.stderr or result.error_string) or "no response"
    end
    return result.stdout or "", nil
end

-- Calls attempt() up to `retries` times, pausing `delay` seconds between
-- tries. Before each try, render(attempt, retries) can show progress.
-- Stops as soon as attempt() returns true; attempt() reports its result
-- through the caller's own variables, not a return value.
local function with_retries(retries, delay, render, attempt)
    for i = 1, retries do
        render(i, retries)
        if attempt() then return true end
        if i < retries then platform.sleep(delay) end
    end
    return false
end

local function torr_server_request_args(method, path, body, timeout, retries, base)
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
    args[#args + 1] = (base and trim_base_url(base) or torr_server_base) .. path
    return args
end

local function request_json(method, path, body, timeout, retries, base)
    local args = torr_server_request_args(method, path, body, timeout, retries, base)
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

local function request_upload(filepath)
    local args = {
        "curl", "--silent", "--show-error", "--fail",
        "--max-time", tostring(opts.request_timeout),
        "--retry", "5", "--retry-delay", "1", "--retry-connrefused",
        "-F", "file=@" .. curl_form_path(filepath),
        "-F", "save_to_db=true",
        torr_server_base .. "/torrent/upload",
    }
    local output, error_text = run_curl(args)
    if not output then return nil, error_text end
    local ok, data = pcall(utils.parse_json, output)
    if not ok or not data then return nil, "invalid JSON response" end
    return data, nil
end

local function read_clipboard()
    return platform.read_clipboard()
end

local function browse_torrent_file()
    local files, err = native_dialog.choose_files({
        title = "Select .torrent file",
        filters = {{label = "Torrent files", patterns = {"torrent"}}},
        multiselect = false,
    })
    if not files then
        if err then mp.msg.error("file dialog failed: " .. err) end
        return nil
    end
    return files[1]
end

--- menu -------------------------------------------------------------

local function send_menu(command, data)
    mp.commandv("script-message-to", "uosc", command, utils.format_json(data))
end

local function clear_search()
    mp.commandv("script-message-to", "uosc", "menu-action", "search-cancel")
end

local function close_menu()
    send_menu("close-menu", {type = menu_type})
end

local function menu_data(title, items)
    return {
        type = menu_type,
        id = menu_type,
        title = title,
        items = items,
        keep_open = true,
        search_debounce = "submit",
        on_search = "callback",
        on_paste = "callback",
        on_close = "callback",
        callback = {script_name, "torrserver-menu-event"},
    }
end

local function back_item(target)
    return {title = "Back", icon = "arrow_back", value = target or "back", keep_open = true}
end

local function stop_resume_action(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        return {name = "drop", icon = "stop", label = "Stop streaming"}
    end
    return {name = "resume", icon = "play_arrow", label = "Resume streaming"}
end

local function history_actions(entry)
    local actions = {stop_resume_action(entry.hash)}
    if entry.source then
        actions[#actions + 1] = {name = "open_source", icon = "open_in_new", label = "Open source"}
    end
    actions[#actions + 1] = {name = "delete", icon = "delete", label = "Remove from history"}
    return actions
end

local function root_menu()
    local items = {
        {title = "Add magnet", icon = "content_paste", value = "add_magnet", keep_open = true},
        {title = "Add torrent file", icon = "folder_open", value = "add_torrent_file", keep_open = true},
        {
            title = "Open TorrServer",
            icon = "dns",
            value = "open_torrserver",
            keep_open = true,
            separator = not available_update,
        },
    }
    if available_update then
        local installed = available_update.installed
        local latest = available_update.latest
        items[#items + 1] = {
            title = installed and "Update TorrServer" or "Download TorrServer",
            icon = "cloud_download",
            hint = installed and (installed .. " → " .. latest) or latest,
            value = "update_torrserver",
            keep_open = true,
            separator = true,
        }
    end
    if last_search and last_search.query ~= "" then
        items[#items + 1] = {
            title = "Search: " .. elide(last_search.query, opts.title_max_chars),
            icon = "search",
            value = "show_search",
            keep_open = true,
            separator = true,
        }
    end
    for _, entry in ipairs(history) do
        local is_playing = playing.hash and entry.hash and entry.hash:lower() == playing.hash
        items[#items + 1] = {
            title = elide(entry.title, opts.title_max_chars),
            hint = stats[entry.hash],
            icon = is_playing and "play_arrow" or "movie",
            value = "history:" .. entry.hash,
            keep_open = true,
            actions = history_actions(entry),
        }
    end
    return menu_data("Add torrent", items)
end

local function is_playing_file(item)
    if not playing.hash or type(item.value) ~= "table" then return false end
    local url = item.value[2]
    if type(url) ~= "string" then return false end
    local h = url:match("[?&]link=([^&]+)")
    if not h or h:lower() ~= playing.hash then return false end
    if not playing.index then return true end
    local i = url:match("[?&]index=([^&]+)")
    return i == playing.index
end

local function show_files(items, back)
    files_items = items
    files_back = back or files_back or "back"
    menu_view = "files"
    clear_search()
    local menu_items = {back_item(files_back)}
    for _, item in ipairs(items) do
        menu_items[#menu_items + 1] = {
            title = elide(item.title, opts.title_max_chars),
            hint = item.hint,
            icon = is_playing_file(item) and "play_arrow" or "movie",
            value = item.value,
        }
    end
    if #menu_items == 1 then
        menu_items[#menu_items + 1] = {title = "No files returned by TorrServer", selectable = false}
    end
    send_menu("update-menu", menu_data("Files", menu_items))
end

--- search -----------------------------------------------------------

-- item.Tracker can list several trackers for one release, comma-separated
-- (e.g. "rutracker, torrentby, bitru, rutor"); this is the one Details links to.
local function raw_tracker(item)
    return field(item, "Tracker", "tracker")
end

local function first_tracker(item)
    local tracker = raw_tracker(item)
    return tracker and tracker:match("^%s*([^,]+)")
end

local function tracker_count(item)
    local tracker = raw_tracker(item)
    if not tracker then return 0 end
    local _, commas = tracker:gsub(",", "")
    return commas + 1
end

-- Everything in item.Tracker after the first one (which Details already
-- points to) — shown on hover so the rest of the list isn't just "+N".
local function other_trackers(item)
    local tracker = raw_tracker(item)
    if not tracker then return nil end
    local rest, first = {}, true
    for name in tracker:gmatch("[^,]+") do
        if first then
            first = false
        else
            rest[#rest + 1] = name:match("^%s*(.-)%s*$")
        end
    end
    return #rest > 0 and table.concat(rest, ", ") or nil
end

local function search_source_url(item)
    local url = field(item, "Details", "Link", "url")
    return url and url:match("^https?://") and url or nil
end

local function list_has(list, value)
    if not list or value == nil then return false end
    local lv = type(value) == "string" and value:lower() or value
    for _, v in ipairs(list) do
        if type(v) == "string" and type(lv) == "string" then
            if v:lower() == lv then return true end
        elseif v == value then
            return true
        end
    end
    return false
end

local function has_dub(item)
    if not item.voices then return false end
    for _, v in ipairs(item.voices) do
        -- API always sends "Дубляж"; Lua lower() does not fold Cyrillic
        if v == "Дубляж" then return true end
    end
    return false
end

local function item_matches(item, f)
    if f.text then
        local title = (item.title or ""):lower()
        for word in f.text:lower():gmatch("%S+") do
            if not title:find(word, 1, true) then return false end
        end
    end
    if f.size then
        local size = item.size or 0
        if size < f.size.min or size > f.size.max then return false end
    end
    if f.seeds and (item.seeders or 0) == 0 and (item.peers or 0) == 0 then
        return false
    end
    if f.quality and item.quality ~= f.quality then return false end
    if f.videotype and (not item.videotype or item.videotype:lower() ~= f.videotype) then return false end
    if f.type then
        local matched = false
        for _, tf in ipairs(type_filters) do
            if tf.value == f.type then
                for _, m in ipairs(tf.match) do
                    if list_has(item.types, m) then matched = true break end
                end
                break
            end
        end
        if not matched then return false end
    end
    if f.year and item.released ~= f.year then return false end
    if f.lang and not list_has(item.languages, f.lang) then return false end
    if f.dub and not has_dub(item) then return false end
    return true
end

local function count_matches(f)
    if not last_search or not last_search.items then return 0 end
    local n = 0
    for _, item in ipairs(last_search.items) do
        if item_matches(item, f) then n = n + 1 end
    end
    return n
end

-- Snapshot of filter fields; nils mean "not constrained". Used for independent
-- per-option counters and for the active selection.
local function filter_state(overrides)
    local state = {}
    for _, k in ipairs(filter_keys) do state[k] = empty_filters[k] end
    for k, v in pairs(overrides or {}) do state[k] = v end
    return state
end

local function current_filter_state()
    return filter_state(filters)
end

local function has_active_filters()
    for _, k in ipairs(filter_keys) do
        if filters[k] ~= empty_filters[k] then return true end
    end
    return false
end

local function reset_filters()
    for _, k in ipairs(filter_keys) do filters[k] = empty_filters[k] end
end

-- Single source of truth for "how many results match right now" and its
-- wording, shared by the filters-menu header and the search-menu Filters row.
local function results_count()
    if not last_search or not last_search.items then return 0 end
    if has_active_filters() then return count_matches(current_filter_state()) end
    return #last_search.items
end

local function results_hint()
    return tostring(results_count()) .. (has_active_filters() and " filtered" or " found")
end

local function filters_clear_item()
    local active = has_active_filters()
    return {
        title = active and "Clear filters" or "All results",
        hint = results_hint(),
        icon = active and "close" or "filter_list",
        value = active and "clear_filters" or nil,
        selectable = active,
        keep_open = true,
        separator = true,
    }
end

local function collect_result_values(field)
    if not last_search or not last_search.items then return {} end
    local seen, values = {}, {}
    for _, item in ipairs(last_search.items) do
        local v = item[field]
        if type(v) == "table" then
            for _, entry in ipairs(v) do
                if entry ~= nil and not seen[entry] then
                    seen[entry] = true
                    values[#values + 1] = entry
                end
            end
        elseif v ~= nil and not seen[v] then
            seen[v] = true
            values[#values + 1] = v
        end
    end
    table.sort(values, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a > b end
        return tostring(a) < tostring(b)
    end)
    return values
end

local function append_toggle_items(menu_items, options, selected, field, icon, value_prefix)
    for i, opt in ipairs(options) do
        local active = selected == opt.value
        menu_items[#menu_items + 1] = {
            title = opt.label,
            hint = tostring(count_matches(filter_state({[field] = opt.value}))),
            icon = active and "check" or icon,
            value = value_prefix .. tostring(opt.value),
            keep_open = true,
            separator = i == #options,
        }
    end
end

local function filters_menu()
    menu_view = "filters"
    local menu_items = {back_item("back_search")}
    menu_items[#menu_items + 1] = filters_clear_item()

    append_toggle_items(menu_items, quality_filters, filters.quality, "quality", "hd", "quality:")
    append_toggle_items(menu_items, videotype_filters, filters.videotype, "videotype", "tonality", "videotype:")
    append_toggle_items(menu_items, type_filters, filters.type, "type", "category", "type:")

    menu_items[#menu_items + 1] = {
        title = "Dub",
        hint = tostring(count_matches(filter_state({dub = true}))),
        icon = filters.dub and "check" or "record_voice_over",
        value = "dub_filter",
        keep_open = true,
        separator = true,
    }

    local langs = collect_result_values("languages")
    for i, lang in ipairs(langs) do
        menu_items[#menu_items + 1] = {
            title = lang,
            hint = tostring(count_matches(filter_state({lang = lang}))),
            icon = filters.lang == lang and "check" or "translate",
            value = "lang:" .. lang,
            keep_open = true,
            separator = i == #langs,
        }
    end

    local years = collect_result_values("released")
    for i, year in ipairs(years) do
        menu_items[#menu_items + 1] = {
            title = tostring(year),
            hint = tostring(count_matches(filter_state({year = year}))),
            icon = filters.year == year and "check" or "event",
            value = "year:" .. tostring(year),
            keep_open = true,
            separator = i == #years,
        }
    end

    for i, sf in ipairs(size_filters) do
        local active = filters.size and filters.size.min == sf.min and filters.size.max == sf.max
        menu_items[#menu_items + 1] = {
            title = sf.label,
            hint = tostring(count_matches(filter_state({size = sf}))),
            icon = active and "check" or "straighten",
            value = "size_filter:" .. i,
            keep_open = true,
            separator = i == #size_filters,
        }
    end

    menu_items[#menu_items + 1] = {
        title = "Seeds/Peers",
        hint = tostring(count_matches(filter_state({seeds = true}))),
        icon = filters.seeds and "check" or "wifi",
        value = "seeds_filter",
        keep_open = true,
    }

    return menu_data("Filters", menu_items)
end

local function filters_label()
    local parts = {}
    if filters.text then parts[#parts + 1] = filters.text end
    if filters.quality then
        for _, q in ipairs(quality_filters) do
            if q.value == filters.quality then parts[#parts + 1] = q.label break end
        end
    end
    if filters.videotype then parts[#parts + 1] = filters.videotype:upper() end
    if filters.type then
        for _, t in ipairs(type_filters) do
            if t.value == filters.type then parts[#parts + 1] = t.label break end
        end
    end
    if filters.dub then parts[#parts + 1] = "Dub" end
    if filters.lang then parts[#parts + 1] = filters.lang end
    if filters.year then parts[#parts + 1] = tostring(filters.year) end
    if filters.size then parts[#parts + 1] = filters.size.label end
    if filters.seeds then parts[#parts + 1] = "seeds/peers" end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

local function search_api_label()
    return search_api == "native" and "Native" or "Jackett"
end

-- Forward-declared: cycle_sort (below) needs to call these, but they're
-- defined further down where the rest of the search-results pipeline lives.
local apply_filters, render_search_menu

local function search_api_item()
    return {
        title = "Search API: " .. search_api_label(),
        hint = "Click to switch",
        icon = "swap_horiz",
        value = "toggle_search_api",
        keep_open = true,
        separator = true,
    }
end

-- Compact, single-row cycling control (same pattern as search_api_item)
-- rather than a submenu, so sorting doesn't add height to the results list.
local sort_options = {
    {key = "none", label = "Default order", icon = "sort"},
    {key = "seeders_desc", label = "Seeds", icon = "arrow_downward"},
    {key = "size_desc", label = "Size", icon = "arrow_downward"},
    {key = "size_asc", label = "Size", icon = "arrow_upward"},
}
local sort_index = 1

local function sort_item()
    local opt = sort_options[sort_index]
    return {
        title = "Sort: " .. opt.label,
        hint = "Click to cycle",
        icon = opt.icon,
        value = "cycle_sort",
        keep_open = true,
    }
end

local function sort_items(items)
    local key = sort_options[sort_index].key
    if key == "none" then return items end
    local sorted = {}
    for i, it in ipairs(items) do sorted[i] = it end
    if key == "seeders_desc" then
        table.sort(sorted, function(a, b) return (a.seeders or 0) > (b.seeders or 0) end)
    elseif key == "size_desc" then
        table.sort(sorted, function(a, b) return (a.size or 0) > (b.size or 0) end)
    elseif key == "size_asc" then
        table.sort(sorted, function(a, b) return (a.size or 0) < (b.size or 0) end)
    end
    return sorted
end

local function cycle_sort()
    sort_index = sort_index % #sort_options + 1
    if has_active_filters() then
        apply_filters()
    else
        render_search_menu(true)
    end
end

local function search_menu(items)
    local menu_items = {back_item(), search_api_item()}

    if last_search and last_search.items and #last_search.items > 0 then
        local label = filters_label()
        local filters_item = {
            title = label and ("Filter: " .. elide(label, opts.title_max_chars)) or "Filters",
            hint = results_hint(),
            icon = "filter_list",
            value = "show_filters",
            keep_open = true,
        }
        if label then
            filters_item.actions = {{name = "clear_filter", icon = "close", label = "Clear filter"}}
        end
        menu_items[#menu_items + 1] = filters_item
        menu_items[#menu_items + 1] = sort_item()
    end

    for _, item in ipairs(items) do menu_items[#menu_items + 1] = item end
    return menu_data("Search torrents", menu_items)
end

-- Redraws the cached search results (or a placeholder) without hitting the
-- network, so returning to a previous search is instant.
local function apply_opened_icons(items)
    for _, item in ipairs(items) do
        item.icon = (item.value == last_opened_magnet) and "visibility" or "movie"
    end
end

function apply_filters()
    apply_opened_icons(last_search.items)
    local filtered = {}
    if has_active_filters() then
        for _, item in ipairs(last_search.items) do
            if item_matches(item, current_filter_state()) then filtered[#filtered + 1] = item end
        end
    else
        filtered = last_search.items
    end
    if #filtered == 0 then
        filtered = {{title = "No matches", selectable = false}}
    else
        filtered = sort_items(filtered)
    end
    menu_view = "search"
    send_menu("update-menu", search_menu(filtered))
end

local function clear_filters(to_search)
    reset_filters()

    if to_search then
        apply_filters()
    else
        send_menu("update-menu", filters_menu())
    end
end

local function set_text_filter(query)
    query = trim(query)
    filters.text = query ~= "" and query or nil
    apply_filters()
end

local function toggle_field(filter_field, value)
    if value == nil then
        filters[filter_field] = not filters[filter_field]
    elseif filters[filter_field] == value then
        filters[filter_field] = nil
    else
        filters[filter_field] = value
    end
    send_menu("update-menu", filters_menu())
end

local function toggle_size_filter(index)
    index = tonumber(index)
    if not index then return end
    local sf = size_filters[index]
    if not sf then return end
    if filters.size and filters.size.min == sf.min and filters.size.max == sf.max then
        filters.size = nil
    else
        filters.size = sf
    end
    send_menu("update-menu", filters_menu())
end

-- "prefix:value" filter toggles from filters_menu's item values. Length is
-- always computed from the prefix string itself, never hardcoded, so a
-- prefix can change length without silently breaking its offset.
local filter_value_prefixes = {
    {prefix = "quality:", filter_field = "quality", cast = tonumber},
    {prefix = "videotype:", filter_field = "videotype"},
    {prefix = "type:", filter_field = "type"},
    {prefix = "lang:", filter_field = "lang"},
    {prefix = "year:", filter_field = "year", cast = tonumber},
}

-- Returns true and applies the toggle if event.value matched one of the
-- prefixes above, so the event handler's elseif chain can fall through
-- to size_filter:/other cases otherwise.
local function try_toggle_prefixed_filter(value)
    if type(value) ~= "string" then return false end
    for _, p in ipairs(filter_value_prefixes) do
        if value:sub(1, #p.prefix) == p.prefix then
            local raw = value:sub(#p.prefix + 1)
            toggle_field(p.filter_field, p.cast and p.cast(raw) or raw)
            return true
        end
    end
    return false
end

local function quality_label(quality)
    for _, q in ipairs(quality_filters) do
        if q.value == quality then return q.label end
    end
    return quality and tostring(quality) or nil
end

local function search_hint(item)
    local parts = {}
    local tracker = first_tracker(item)
    if tracker then
        local count = tracker_count(item)
        parts[#parts + 1] = count > 1 and (tracker .. " +" .. (count - 1)) or tracker
    end
    local q = quality_label(item.quality)
    if q then parts[#parts + 1] = q end
    if item.Size then parts[#parts + 1] = format_size(item.Size) end
    parts[#parts + 1] = "S:" .. tostring(item.Seeders or 0) .. " P:" .. tostring(item.Peers or 0)
    return table.concat(parts, " · ")
end

local function build_search_items(response)
    local items, urls = {}, {}
    for _, item in ipairs(response_list(response) or {}) do
        local magnet = field(item, "MagnetUri", "Magnet", "magnet")
        if magnet then
            local url = search_source_url(item)
            local actions = {{name = "copy_magnet", icon = "content_copy", label = "Copy magnet link"}}
            if url then
                local label = "Open on " .. (first_tracker(item) or "site")
                local others = other_trackers(item)
                if others then label = label .. " (also on: " .. others .. ")" end
                table.insert(actions, 1, {name = "open_source", icon = "open_in_new", label = label})
                urls[magnet] = url
            end

            local info = type(item.info) == "table" and item.info or {}
            local tracker = raw_tracker(item)
            local title = field(item, "Title", "title")
            local size = field(item, "Size", "size")
            local seeders = field(item, "Seeders", "Seed", "sid")
            local peers = field(item, "Peers", "Peer", "pir")
            local quality = first(info.quality, item.quality)
            local videotype = first(info.videotype, item.videotype)
            local types = first(info.types, item.types)
            local released = first(info.relased, item.relased)
            local languages = item.languages
            local voices = first(info.voices, item.voices)

            items[#items + 1] = {
                title = elide(title or "Untitled", opts.title_max_chars),
                hint = search_hint({
                    Tracker = tracker,
                    quality = quality,
                    Size = size,
                    Seeders = seeders,
                    Peers = peers,
                }),
                icon = "movie",
                value = magnet,
                keep_open = true,
                actions = actions,
                size = tonumber(size) or 0,
                seeders = tonumber(seeders) or 0,
                peers = tonumber(peers) or 0,
                quality = tonumber(quality),
                videotype = videotype and tostring(videotype):lower() or nil,
                types = types,
                released = tonumber(released),
                languages = languages,
                voices = voices,
            }
        end
    end
    return items, urls
end

-- Re-renders search results against the current filter state (text + size + seeds).
function render_search_menu(preserve_filter)
    files_back = nil
    menu_view = "search"
    clear_search()
    if not preserve_filter then reset_filters() end
    if last_search and last_search.items and #last_search.items > 0 and has_active_filters() then
        apply_filters()
        return
    end
    local items = last_search and last_search.items or {}
    if #items == 0 then
        items = {{title = (last_search and last_search.query ~= "") and "No results" or "Type to search...", selectable = false}}
    else
        apply_opened_icons(items)
        items = sort_items(items)
    end
    send_menu("update-menu", search_menu(items))
end

local function search_torrents(query)
    query = trim(query)
    if query == "" then
        last_search = nil
        last_opened_magnet = nil
        menu_view = nil
        render_search_menu()
        return
    end
    last_opened_magnet = nil
    if not start_torrserver() then return end

    menu_view = "search"
    local path
    if search_api == "native" then
        path = "/api/v1.0/torrents?apikey=" .. opts.search_api_key
            .. "&search=" .. encode_path(query)
    else
        path = "/api/v2.0/indexers/all/results?apikey=" .. opts.search_api_key
            .. "&t=search&q=" .. encode_path(query)
    end
    local response, error_text, items, urls
    with_retries(search.retries, search.delay,
        function(attempt, total)
            local label = "Searching..."
            if total > 1 then label = label .. " (" .. attempt .. "/" .. total .. ")" end
            send_menu("update-menu", search_menu({{title = label, icon = "spinner", selectable = false}}))
        end,
        function()
            for _, server in ipairs(search_servers) do
                response, error_text = request_json("GET", path, nil, search.timeout, 1, server)
                items, urls = build_search_items(response)
                if #items > 0 then return true end
            end
            return false
        end)
    if not response or not items or #items == 0 then
        show_error(error_text or "search failed")
        render_search_menu()
        return
    end

    last_search = {query = query, items = items, urls = urls}
    render_search_menu(true) -- preserve filters if already set
end

--- flows ------------------------------------------------------------

-- Async metadata poll: retries up to `retries` times, `delay` seconds apart,
-- using a timer + non-blocking subprocess (unlike with_retries) so the menu
-- stays responsive and the wait can be cancelled (see cancel_pending_add)
-- instead of blocking mpv while retrying. on_progress(attempt, total) fires
-- before each try; on_done(torrent, items, error_text) fires once, or never
-- if cancelled first.
local function poll_metadata_async(hash, retries, delay, back, on_progress, on_done)
    local poll = {cancelled = false, hash = hash, back = back}
    metadata_poll = poll
    local attempt = 0

    local function step()
        if poll.cancelled then return end
        attempt = attempt + 1
        on_progress(attempt, retries)
        local args = torr_server_request_args("POST", "/torrents", {action = "list"})
        platform.run_subprocess_async(args, function(success, result, err)
            if poll.cancelled then return end
            local torrent, items, error_text
            if success and result and result.status == 0 then
                local ok, list_response = pcall(utils.parse_json, result.stdout or "")
                if ok and list_response then
                    torrent = find_added_torrent(list_response, hash)
                    if not torrent and not hash and type(list_response[1]) == "table" then
                        torrent = list_response[1]
                    end
                    items = torrent and file_items(torrent) or {}
                else
                    error_text = "invalid JSON response"
                end
            else
                error_text = result and (result.stderr or result.error_string) or (err and tostring(err)) or "no response"
            end

            if items and #items > 0 then
                metadata_poll = nil
                on_done(torrent, items, nil)
            elseif attempt >= retries then
                metadata_poll = nil
                on_done(torrent, items or {}, error_text)
            else
                mp.add_timeout(delay, step)
            end
        end)
    end
    step()
end

local function begin_add(back)
    if not start_torrserver() then return false end
    send_menu("update-menu", menu_data("Add torrent", {
        back_item(back),
        {title = "Adding torrent...", icon = "spinner", selectable = false},
    }))
    return true
end

-- Forward-declared: remove_torrent and return_to_root (below) are needed
-- here to clean up an orphaned add and leave the menu somewhere sane when
-- retries run out — otherwise the last "Waiting for metadata..." spinner
-- frame stays on screen forever with nothing left to update it.
local remove_torrent, return_to_root

-- Goes back to wherever the add was started from: the search results if it
-- came from there, the root menu otherwise.
local function back_to_previous(back)
    if back == "back_search" then
        render_search_menu(true)
    else
        return_to_root()
    end
end

-- Shared tail for both add flows: resolve, show files. Not committed to
-- history yet — see pending_entry / commit_pending.
local function finish_add(response, error_text, hash, fallback_title, source, back)
    if not response then
        show_error(error_text or "could not add torrent")
        back_to_previous(back)
        return
    end

    -- Completes the flow once a torrent (with files) is known, whether that
    -- came back immediately or after polling for metadata.
    local function complete(torrent, items, poll_error)
        if not torrent or #items == 0 then
            -- Torrent was already added to TorrServer (save_to_db=true); with no
            -- files to show there's nothing pending to discard it later, so it
            -- would otherwise sit there orphaned. Clean it up now instead.
            local orphan_hash = (torrent and torrent_hash(torrent)) or hash
            if orphan_hash then remove_torrent(orphan_hash) end
            show_error(poll_error or "no files found")
            back_to_previous(back)
            return
        end
        local title = torrent_title(torrent) or fallback_title
        pending_entry = {hash = torrent_hash(torrent) or hash, title = title, items = items, source = source}
        show_files(items, back)
    end

    local torrent = find_added_torrent(response, hash)
    if not torrent and not hash and type(response[1]) == "table" then
        torrent = response[1]
    end
    local items = torrent and file_items(torrent) or {}
    if #items > 0 then
        complete(torrent, items)
        return
    end

    -- Metadata (file list) can take a few seconds to arrive after adding, so
    -- poll for it; cancel_pending_add() can abort this while it's running.
    poll_metadata_async(hash, metadata.retries, metadata.delay, back, function(attempt, total)
        send_menu("update-menu", menu_data("Add torrent", {
            back_item(back),
            {title = "Waiting for metadata (" .. attempt .. "/" .. total .. ")...", icon = "spinner", selectable = false},
        }))
    end, complete)
end

local function add_magnet(magnet, source, back)
    if not is_magnet(magnet) then
        show_error("clipboard does not contain a magnet link")
        return
    end
    if not begin_add(back) then return end

    local hash = magnet_hash(magnet)
    local response, error_text = request_json("POST", "/torrents", {
        action = "add",
        link = magnet,
        save_to_db = true,
    })
    finish_add(response, error_text, hash, "Untitled torrent", source, back)
end

local function stop_stats_polling()
    if stats_timer then
        stats_timer:kill()
        stats_timer = nil
    end
end

local stats_refresh_in_flight = false

local function apply_stats_response(list_response)
    local changed = false
    for _, entry in ipairs(history) do
        local torrent = find_added_torrent(list_response, entry.hash)
        local hint = torrent and torrent_stat_hint(torrent) or nil
        if hint ~= stats[entry.hash] then
            changed = true
        end
        stats[entry.hash] = hint
    end
    if changed and menu_view == "root" then
        send_menu("update-menu", root_menu())
    end
end

-- Non-blocking: this used to run synchronously on the main thread, which
-- meant a slow or unresponsive TorrServer froze the whole mpv UI for up to
-- several seconds on every single poll. in_flight guards against a slow
-- response overlapping the next timer tick. The timer itself keeps running
-- for as long as the menu is open (any view), but the request only matters
-- while root is showing, so skip it otherwise instead of hitting the network
-- every tick for nothing.
local function refresh_stats()
    if menu_view ~= "root" then return end
    if stats_refresh_in_flight then return end
    stats_refresh_in_flight = true
    local args = torr_server_request_args("POST", "/torrents", {action = "list"})
    platform.run_subprocess_async(args, function(success, result, err)
        stats_refresh_in_flight = false
        if not success or not result or result.status ~= 0 then return end
        local ok, list_response = pcall(utils.parse_json, result.stdout or "")
        if not ok or not list_response then return end
        apply_stats_response(list_response)
    end)
end

local function check_for_update()
    local bin_path = resolved_bin_path()
    local installed = updater.installed_version(bin_path)
    local release = updater.cached_latest_release(native_dialog.platform, update_cache_path, opts.update_check_interval)
    if not release then
        return
    end
    if not installed or installed ~= release.version then
        local prev = available_update
        if not prev or prev.latest ~= release.version or prev.installed ~= installed then
            available_update = {
                installed = installed,
                latest = release.version,
            }
            if menu_view == "root" then
                send_menu("update-menu", root_menu())
            end
        end
    elseif available_update then
        available_update = nil
        if menu_view == "root" then
            send_menu("update-menu", root_menu())
        end
    end
end

-- Kicks off a stats refresh (now async, see refresh_stats) so the root menu's
-- seeds/speed/history update shortly after it opens, then keeps polling.
-- check_for_update() is passive and TTL-cached (see opts.update_check_interval)
-- so repeatedly returning to the root menu doesn't hit the release API every time.
local function show_root_menu(command)
    if start_torrserver(true) then refresh_stats() end
    files_back = nil
    menu_view = "root"
    clear_search()
    send_menu(command, root_menu())
    if not stats_timer then
        stats_timer = mp.add_periodic_timer(opts.stats_interval, refresh_stats)
    end
    mp.add_timeout(0.05, check_for_update)
end

-- Leaving search back to the root menu drops the active filter, so
-- reopening search via "Search: ..." starts unfiltered.
function return_to_root()
    if menu_view == "search" then
        reset_filters()
    end
    show_root_menu("update-menu")
end

local function torrent_action(action, hash, error_prefix)
    if not start_torrserver() then return false end
    local _, error_text = request_json("POST", "/torrents", {action = action, hash = hash})
    if error_text then
        show_error(error_prefix .. ": " .. error_text)
        return false
    end
    return true
end

local function stop_if_playing(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        mp.commandv("stop")
    end
end

local function drop_torrent(hash)
    local ok = torrent_action("drop", hash, "could not stop torrent")
    if ok then stop_if_playing(hash) end
    return ok
end

-- TorrServer refuses to "rem" a torrent that's still actively streaming, so
-- drop it first to release the reader.
function remove_torrent(hash)
    drop_torrent(hash)
    return torrent_action("rem", hash, "could not remove torrent from TorrServer")
end

-- Leaving the file list without playing anything means the user didn't want
-- that torrent after all, so undo what save_to_db=true persisted in TorrServer.
local function discard_pending()
    if pending_entry then
        remove_torrent(pending_entry.hash)
        pending_entry = nil
    end
end

-- Undoes an add that hasn't been committed to history yet, whichever stage
-- it's at: an in-flight metadata poll (see poll_metadata_async) or an
-- already-resolved pending_entry. Returns the poll's back target, if any,
-- so callers don't need to inspect metadata_poll themselves.
local function cancel_pending_add()
    local back
    if metadata_poll then
        metadata_poll.cancelled = true
        back = metadata_poll.back
        if metadata_poll.hash then remove_torrent(metadata_poll.hash) end
        metadata_poll = nil
    end
    discard_pending()
    return back
end

local function open_history_entry(hash)
    local entry = find_history(hash)
    if not entry then
        show_error("history entry no longer available")
        return
    end
    if not start_torrserver() then return end
    show_files(entry.items)
end

-- "Resume streaming" plays straight away instead of opening the file list;
-- opening the file list is reserved for clicking the history row itself.
local function play_history_entry(hash)
    local entry = find_history(hash)
    if not entry or not entry.items or #entry.items == 0 then
        show_error("history entry no longer available")
        return
    end
    if not start_torrserver() then return end
    if not mp.commandv(unpack(entry.items[1].value)) then
        show_error("failed to start playback")
    end
end

local function add_torrent_from_file(filepath)
    filepath = trim(filepath)
    if filepath == "" then
        show_error("file path is empty")
        return
    end

    if not utils.file_info(filepath) then
        show_error("file not found: " .. filepath)
        return
    end

    if not filepath:match("%.torrent$") then
        show_error("file must have .torrent extension")
        return
    end

    if not begin_add() then return end

    local _, filename = utils.split_path(filepath)
    local response, error_text = request_upload(filepath)
    finish_add(response, error_text, nil, filename)
end

local function finalize_update(bin_path, tmp_path, installed, version)
    stop_torrserver()
    platform.sleep(1)

    local replaced, replace_error = updater.replace_binary(bin_path, tmp_path)
    if not replaced then
        os.remove(tmp_path)
        show_error(replace_error or "failed to replace TorrServer binary")
        send_menu("update-menu", root_menu())
        return
    end

    available_update = nil
    start_torrserver()
    mp.osd_message("TorrServer " .. (installed and "updated to" or "installed:") .. " " .. version, 3)
    send_menu("update-menu", root_menu())
end

local function update_torrserver()
    local bin_path = resolved_bin_path()
    local installed = updater.installed_version(bin_path)

    send_menu("update-menu", menu_data("Add torrent", {
        back_item(),
        {title = "Checking for TorrServer updates...", icon = "spinner", selectable = false},
    }))
    -- Bypasses the passive TTL cache: an explicit click should always check live.
    local release, error_text = updater.latest_release(native_dialog.platform)
    if not release then
        show_error(error_text or "could not check for updates")
        send_menu("update-menu", root_menu())
        return
    end
    if installed and installed == release.version then
        available_update = nil
        mp.osd_message("TorrServer: already up to date (" .. installed .. ")", 3)
        send_menu("update-menu", root_menu())
        return
    end

    local tmp_path = bin_path .. ".new"
    updater.download_async(release.url, tmp_path, release.size, function(percent)
        local label = "Downloading TorrServer " .. release.version .. "..."
        if percent then label = label .. " " .. percent .. "%" end
        send_menu("update-menu", menu_data("Add torrent", {
            back_item(),
            {title = label, icon = "spinner", selectable = false},
        }))
    end, function(ok, download_error)
        if not ok then
            os.remove(tmp_path)
            show_error("update download failed: " .. (download_error or "unknown error"))
            send_menu("update-menu", root_menu())
            return
        end
        finalize_update(bin_path, tmp_path, installed, release.version)
    end)
end

--- events -------------------------------------------------------------

local history_prefix = "history:"

local function history_hash(value)
    if type(value) == "string" and value:sub(1, #history_prefix) == history_prefix then
        return value:sub(#history_prefix + 1)
    end
    return nil
end

-- Playing state reflects what's actually loaded in mpv, not TorrServer's
-- download activity (which can stay nonzero briefly after a stream is dropped).
mp.observe_property("path", "string", function(_, path)
    local hash = path and path:match("[?&]link=([^&]+)")
    local index = path and path:match("[?&]index=([^&]+)")
    if hash then hash = hash:lower() end
    if hash ~= playing.hash or index ~= playing.index then
        playing.hash = hash
        playing.index = index
        if menu_view == "root" then
            send_menu("update-menu", root_menu())
        elseif menu_view == "files" and files_items then
            show_files(files_items)
        end
    end
end)

mp.register_script_message("torrserver-menu-event", function(json)
    local event = utils.parse_json(json)

    if event.type == "search" then
        if menu_view == "search" and last_search and last_search.items and #last_search.items > 0 then
            set_text_filter(event.query)
        else
            search_torrents(event.query)
        end
        return
    end
    if event.type == "paste" then
        add_magnet(event.value)
        return
    end
    if event.type == "close" then
        discard_pending()
        stop_stats_polling()
        files_back = nil
        menu_view = nil
        return
    end
    if event.type == "back" then
        -- menu_view hasn't switched to "files" yet while a metadata poll is
        -- in flight, so its own back target decides where to land instead.
        local poll_back = cancel_pending_add()
        if poll_back then
            back_to_previous(poll_back)
        elseif menu_view == "filters" or (menu_view == "files" and files_back == "back_search") then
            render_search_menu(true)
        else
            return_to_root()
        end
        return
    end
    if event.type ~= "activate" then return end

    if event.action == "delete" then
        local hash = history_hash(event.value)
        if hash then
            send_menu("update-menu", menu_data("Add torrent", {
                back_item(),
                {title = "Removing torrent...", icon = "spinner", selectable = false},
            }))
            if remove_torrent(hash) then
                forget_history(hash)
            end
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "drop" then
        local hash = history_hash(event.value)
        if hash then
            drop_torrent(hash)
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "resume" then
        local hash = history_hash(event.value)
        if hash then
            play_history_entry(hash)
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "clear_filter" then
        clear_filters(true) -- Stay in search menu
        return
    end
    if event.action == "open_source" then
        local hash = history_hash(event.value)
        if hash then
            local entry = find_history(hash)
            if entry and entry.source then
                pause_if_playing(hash)
                open_url(entry.source)
            end
            return
        end
        local url = last_search and last_search.urls and last_search.urls[event.value]
        if url then
            pause_if_playing(magnet_hash(event.value))
            open_url(url)
            last_opened_magnet = event.value
            if has_active_filters() then
                apply_filters()
            else
                render_search_menu()
            end
        end
        return
    end
    if event.action == "copy_magnet" then
        -- Search results only: event.value is the magnet URI itself here,
        -- unlike history items (see history_hash usage above).
        if not history_hash(event.value) then
            platform.write_clipboard(event.value)
            mp.osd_message("Magnet link copied", 2)
        end
        return
    end
    if type(event.value) == "table" then
        if mp.commandv(unpack(event.value)) then
            commit_pending()
        else
            show_error("failed to start playback")
        end
    elseif event.value == "add_magnet" then
        add_magnet(read_clipboard())
    elseif event.value == "open_torrserver" then
        if start_torrserver() then open_torrserver_ui() end
    elseif event.value == "update_torrserver" then
        update_torrserver()
    elseif event.value == "add_torrent_file" then
        local filepath = browse_torrent_file()
        if filepath then
            add_torrent_from_file(filepath)
        else
            mp.msg.info("No file selected")
        end
    elseif event.value == "toggle_search_api" then
        if not last_search or last_search.query == "" then return end
        search_api = search_api == "native" and "jackett" or "native"
        state.search_api = search_api
        save_state(state)
        search_torrents(last_search.query)
    elseif event.value == "cycle_sort" then
        cycle_sort()
    elseif event.value == "show_search" or event.value == "back_search" then
        cancel_pending_add()
        render_search_menu(true)
    elseif event.value == "show_filters" then
        clear_search()
        menu_view = "filters"
        send_menu("update-menu", filters_menu())
    elseif event.value == "clear_filters" then
        clear_filters(false) -- Stay in filters menu
    elseif event.value == "seeds_filter" then
        toggle_field("seeds")
    elseif event.value == "dub_filter" then
        toggle_field("dub")
    elseif try_toggle_prefixed_filter(event.value) then
        -- handled inside try_toggle_prefixed_filter
    elseif type(event.value) == "string" and event.value:match("^size_filter:") then
        toggle_size_filter(event.value:sub(#"size_filter:" + 1))
    elseif is_magnet(event.value) then
        add_magnet(event.value, last_search and last_search.urls and last_search.urls[event.value], "back_search")
    elseif event.value == "back" then
        cancel_pending_add()
        return_to_root()
    else
        local hash = history_hash(event.value)
        if hash then
            open_history_entry(hash)
        end
    end
end)

mp.add_key_binding(nil, "torrserver", function()
    show_root_menu("open-menu")
end)

mp.register_event("shutdown", stop_torrserver)