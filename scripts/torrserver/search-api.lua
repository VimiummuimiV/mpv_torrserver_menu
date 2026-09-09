-- JacRed search API client (distinct from TorrServer's own HTTP API in
-- torrserver-api.lua). Two API versions are supported, selected at runtime:
--   Native v1.0   GET /api/v1.0/torrents?search=...&apikey=...
--   Jackett v2.0  GET /api/v2.0/indexers/all/results?query=...&apikey=...
--
-- Field maps below list every property actually read from real responses;
-- the comment blocks also note properties observed but unused, so they're
-- visible when extending. Field aliases are ordered: preferred key first,
-- then fallbacks.

local mp = require("mp")
local utils = require("mp.utils")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))

local M = {}

local search_api_fields = {
    -- Native v1.0  Response: JSON array of objects (empty object {} when no results).
    --   tracker      string    tracker slug (e.g. "korsars", "rutor", "bitru")
    --   url          string    details page URL
    --   title        string    full release title
    --   size         number    size in bytes
    --   sizeName     string    human-readable size (e.g. "11.9 GB")
    --   createTime   string    ISO timestamp first seen
    --   updateTime   string    ISO timestamp last updated
    --   sid          number    seeders
    --   pir          number    peers/leechers
    --   magnet       string    magnet URI
    --   name         string    normalized title (localized)
    --   originalname string    original (usually English) title
    --   released     number    release year
    --   videotype    string    "sdr" | "hdr" | ...
    --   quality      number    resolution: 480, 720, 1080, 2160
    --   voices       string[]  dubbing/voice tags (e.g. "Дубляж", studio names)
    --   seasons      number[]  season numbers (empty for movies)
    --   types        string[]  content tags: "movie", "serial", "tvshow",
    --                          "documovie", "docuserial", "anime", "ova", "ona",
    --                          "multfilm", "multserial"
    -- Not present on v1.0: languages, ffprobe, Category, nested info.
    native = {
        list = nil, -- direct array
        tracker   = {"tracker"},
        url       = {"url"},
        title     = {"title"},
        size      = {"size"},
        seeders   = {"sid"},
        peers     = {"pir"},
        magnet    = {"magnet"},
        quality   = {"quality"},
        videotype = {"videotype"},
        types     = {"types"},
        released  = {"relased", "released"}, -- API typo: sometimes "relased" instead of "released"
        languages = nil, -- not present on v1.0
        voices    = {"voices"},
    },
    -- Jackett v2.0  Response: { Results = [ ... ], Error = null|string }.
    --   Tracker      string    tracker slug(s), comma-separated when merged
    --   Details      string    details page URL (primary)
    --   Title        string    full release title
    --   Size         number    size in bytes
    --   PublishDate  string    ISO publication timestamp
    --   Category     number[]  Jackett category IDs (2000=Movies, 5000=TV, ...)
    --   CategoryDesc string    human-readable category
    --   Seeders      number    seeders
    --   Peers        number    peers/leechers
    --   MagnetUri    string    magnet URI
    --   ffprobe      object[]  optional media stream metadata (codec, width,
    --                          height, language, bit_rate, tags, ...)
    --   languages    string[]  audio/subtitle language codes (e.g. "rus", "eng")
    --   info         object    enriched JacRed metadata (may be absent):
    --     info.quality      number    resolution: 480, 720, 1080, 2160
    --     info.videotype    string    "sdr" | "hdr" | ...
    --     info.voices       string[]  dubbing/voice tags
    --     info.types        string[]  content tags (same set as native)
    --     info.released     number    release year (API typo; 0 when unknown)
    --     info.name         string    normalized title (localized)
    --     info.originalname string    original title
    --     info.sizeName     string    human-readable size
    --     info.seasons      number[]  season numbers
    -- Occasional aliases seen in the wild: Link (url), Magnet (magnet),
    -- quality/videotype/types/released/voices at top level when info is missing.
    jackett = {
        list      = "Results",
        tracker   = {"Tracker"},
        url       = {"Details"},
        title     = {"Title"},
        size      = {"Size"},
        seeders   = {"Seeders"},
        peers     = {"Peers"},
        magnet    = {"MagnetUri"},
        quality   = {"info.quality"},
        videotype = {"info.videotype"},
        types     = {"info.types"},
        released  = {"info.relased", "info.released"}, -- API typo: sometimes "info.relased" instead of "info.released"
        languages = {"languages"},
        voices    = {"info.voices"},
    },
}

local function field_path(obj, path)
    local cur = obj
    for part in path:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
        if cur == nil then return nil end
    end
    return cur
end

-- Prefer the requested API's map, fall back to the other so mixed responses still work.
local function api_field(item, api_name, key)
    local primary = api_name == "jackett" and search_api_fields.jackett or search_api_fields.native
    local secondary = api_name == "jackett" and search_api_fields.native or search_api_fields.jackett
    for _, map in ipairs({primary, secondary}) do
        local aliases = map[key]
        if type(aliases) == "table" then
            for _, alias in ipairs(aliases) do
                local v = alias:find("%.") and field_path(item, alias) or item[alias]
                if v ~= nil then return v end
            end
        end
    end
    return nil
end

local function response_list(response, api_name)
    local map = api_name == "jackett" and search_api_fields.jackett or search_api_fields.native
    local list = map.list and response and response[map.list] or response
    return type(list) == "table" and list or nil
end

-- Tracker string may list several trackers for one release, comma-separated
-- (e.g. "rutracker, torrentby, bitru, rutor"); Details links to the first.
local function raw_tracker(item, api_name)
    return api_field(item, api_name, "tracker")
end

local function first_tracker(tracker)
    return tracker and tracker:match("^%s*([^,]+)")
end

local function tracker_count(tracker)
    if not tracker then return 0 end
    local _, commas = tracker:gsub(",", "")
    return commas + 1
end

-- Everything in the tracker string after the first one (which the details
-- link already points to) — shown on hover so the rest isn't just "+N".
local function other_trackers(tracker)
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

local function search_source_url(item, api_name)
    local url = api_field(item, api_name, "url")
    return url and url:match("^https?://") and url or nil
end

-- Normalizes one raw API item into the shape used by filters/sort/menu
-- (see main.lua). All API-specific field names stay local to this module.
local function normalize_search_item(item, api_name, title_max_chars, elide_titles, quality_label)
    local magnet = api_field(item, api_name, "magnet")
    if not magnet then return nil end

    local tracker = raw_tracker(item, api_name)
    local title = api_field(item, api_name, "title")
    local size = tonumber(api_field(item, api_name, "size")) or 0
    local seeders = tonumber(api_field(item, api_name, "seeders")) or 0
    local peers = tonumber(api_field(item, api_name, "peers")) or 0
    local quality = tonumber(api_field(item, api_name, "quality"))
    local videotype = api_field(item, api_name, "videotype")
    local types = api_field(item, api_name, "types")
    local released = tonumber(api_field(item, api_name, "released"))
    local languages = api_field(item, api_name, "languages")
    local voices = api_field(item, api_name, "voices")
    local url = search_source_url(item, api_name)

    local actions = {{name = "copy_magnet", icon = "content_copy", label = "Copy magnet link"}}
    if url then
        local label = "Open on " .. (first_tracker(tracker) or "site")
        local others = other_trackers(tracker)
        if others then label = label .. " (also on: " .. others .. ")" end
        table.insert(actions, 1, {name = "open_source", icon = "open_in_new", label = label})
    end

    local hint_parts = {}
    local first = first_tracker(tracker)
    if first then
        local count = tracker_count(tracker)
        hint_parts[#hint_parts + 1] = count > 1 and (first .. " +" .. (count - 1)) or first
    end
    local q_label = quality_label(quality)
    if q_label then hint_parts[#hint_parts + 1] = q_label end
    if size > 0 then hint_parts[#hint_parts + 1] = shared.format_size(size) end
    hint_parts[#hint_parts + 1] = "S:" .. tostring(seeders) .. " P:" .. tostring(peers)

    return {
        title = shared.elide(title or "Untitled", title_max_chars, elide_titles),
        hint = table.concat(hint_parts, " · "),
        icon = "movie",
        value = magnet,
        keep_open = true,
        actions = actions,
        size = size,
        seeders = seeders,
        peers = peers,
        quality = quality,
        videotype = videotype and tostring(videotype):lower() or nil,
        types = types,
        released = released,
        languages = languages,
        voices = voices,
        source_url = url,
    }
end

-- config: {servers, api_key, timeout, retries, delay, title_max_chars,
--          elide_titles, quality_label}
-- quality_label(quality) formats a numeric quality (e.g. 1080) into a menu
-- label (e.g. "1080p"); supplied by main.lua, which owns the filter labels.
function M.new(config)
    local api = {}

    local function fetch(path, server)
        local args = {
            "curl", "--silent", "--show-error", "--fail", "--ssl-revoke-best-effort",
            "--max-time", tostring(config.timeout),
            server .. path,
        }
        local result = platform.run_subprocess(args)
        if not result or result.status ~= 0 then
            return nil, result and (result.stderr or result.error_string) or "no response"
        end
        local ok, data = pcall(utils.parse_json, result.stdout or "")
        if not ok or not data then return nil, "invalid JSON response" end
        return data, nil
    end

    local function build_items(response, api_name)
        local items, urls = {}, {}
        for _, item in ipairs(response_list(response, api_name) or {}) do
            local normalized = normalize_search_item(item, api_name, config.title_max_chars, config.elide_titles, config.quality_label)
            if normalized then
                if normalized.source_url then
                    urls[normalized.value] = normalized.source_url
                end
                normalized.source_url = nil
                items[#items + 1] = normalized
            end
        end
        return items, urls
    end

    -- Retries up to config.retries times across all configured servers,
    -- config.delay seconds apart. on_attempt(attempt, total) fires before
    -- each try so the caller can show progress. Returns items, urls, error.
    function api.search(api_name, query, on_attempt)
        local path
        if api_name == "native" then
            path = "/api/v1.0/torrents?apikey=" .. config.api_key .. "&search=" .. shared.encode_path(query)
        else
            path = "/api/v2.0/indexers/all/results?apikey=" .. config.api_key .. "&t=search&q=" .. shared.encode_path(query)
        end

        local error_text
        for attempt = 1, config.retries do
            if on_attempt then on_attempt(attempt, config.retries) end
            for _, server in ipairs(config.servers) do
                local response, err = fetch(path, server)
                if response then
                    local items, urls = build_items(response, api_name)
                    if #items > 0 then return items, urls, nil end
                else
                    error_text = err
                end
            end
            if attempt < config.retries then platform.sleep(config.delay) end
        end
        return {}, {}, error_text or "search failed"
    end

    return api
end

return M
