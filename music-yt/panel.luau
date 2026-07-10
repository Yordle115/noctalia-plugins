-- =============================================================================
--  panel.luau — Music (YouTube + Local)  v0.4.0
--  yt-dlp + mpv backend. Search YouTube, play/queue, favourites, playlists.
--
--  Layout: a single column — tab bar (Search / Queue / Favourites / Playlists),
--  ONE ui.scroll body, and a now-playing bar pinned at the bottom. Keep it to
--  a single scroll region: multiple scroll regions break input focus.
--
--  Every list row shows the same actions (play / add-to-queue / extra), wired
--  to a fixed pool of literal global handlers (onRowPlayN / onRowAddN /
--  onRowXN) that dispatch through rowAct() based on the active tab. _G is
--  read-only in this sandbox, so the pool MUST stay declared literally — see
--  the end of this file. Lists cap their clickable rows at POOL.
-- =============================================================================

local SOCKET   = "/tmp/noctalia-music-mpv.sock"
local DATA_DIR = noctalia.expandPath("~/.config/noctalia-music")
local FAV_FILE = DATA_DIR .. "/favourites.json"
local PL_FILE  = DATA_DIR .. "/playlists.json"
local POOL     = 80   -- size of the literal per-row handler pool below

-- ---------- config ----------
local function cfg()
  return {
    results  = noctalia.getConfig("search_results") or 15,
    localDir = noctalia.expandPath(noctalia.getConfig("local_music_dir") or ""),
    localOn  = noctalia.getConfig("search_local") == true,
    ytClient = noctalia.getConfig("yt_player_client") or "android",
  }
end

-- ---------- shell quoting ----------
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- view state ----------
local TAB_SEARCH = "search"
local TAB_QUEUE  = "queue"
local TAB_FAVS   = "favourites"
local TAB_PL     = "playlists"

local state = {
  tab         = TAB_SEARCH,
  query       = "",
  results     = {},   -- search results { {id,title,url,uploader,duration,source,thumbnail} }
  queue       = {},   -- { {title,url,uploader,duration,thumbnail} }
  queueIdx    = 0,
  favourites  = {},   -- { {title,url,uploader,duration} }
  playlists   = {},   -- name -> { track, ... }
  plNames     = {},   -- sorted playlist names (stable row indexing)
  nowPlaying  = { title = "", uploader = "", url = "", thumbnail = "", playing = false, paused = false },
  position    = 0,
  duration    = 0,
  artPath     = nil,   -- downloaded album-art file for now-playing
  starting    = false,
  shuffle     = false,  -- when on, upcoming queue items are shuffled
  repeatQueue = false,  -- when on, queue loops back to start after the last track
  busy        = false,
  status      = "",
  loaded      = false,  -- have we loaded persisted data yet
}

-- forward declarations (callbacks near the bottom close over these)
local render
local refreshNowPlaying

-- shallow copy of the track fields we keep in queue/favourites/playlists
local function asTrack(t)
  return {
    title = t.title, url = t.url,
    uploader = t.uploader or "", duration = t.duration or 0,
    thumbnail = t.thumbnail,
  }
end

-- ---------- persistence ----------
local function refreshPlNames()
  state.plNames = {}
  for name in pairs(state.playlists) do table.insert(state.plNames, name) end
  table.sort(state.plNames)
end

-- Load favourites + playlists from disk into state (once, on open).
local function loadData()
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR), function()
    noctalia.runAsync("cat " .. sq(FAV_FILE) .. " 2>/dev/null", function(res)
      local ok, parsed = pcall(function() return noctalia.json.decode(res.stdout or "") end)
      if ok and type(parsed) == "table" then state.favourites = parsed end
      noctalia.runAsync("cat " .. sq(PL_FILE) .. " 2>/dev/null", function(r2)
        local ok2, parsed2 = pcall(function() return noctalia.json.decode(r2.stdout or "") end)
        if ok2 and type(parsed2) == "table" then
          state.playlists = parsed2
          refreshPlNames()
        end
        state.loaded = true
        render()
      end)
    end)
  end)
end

local function saveFavourites()
  local json = noctalia.json.encode(state.favourites)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(FAV_FILE), nil)
end

local function savePlaylists()
  local json = noctalia.json.encode(state.playlists)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(PL_FILE), nil)
  refreshPlNames()
end

-- ---------- favourites helpers ----------
local function isFav(url)
  for _, t in ipairs(state.favourites) do
    if t.url == url then return true end
  end
  return false
end

local function removeFav(url)
  for i, t in ipairs(state.favourites) do
    if t.url == url then table.remove(state.favourites, i); break end
  end
  saveFavourites()
end

local function toggleFav(track)
  if isFav(track.url) then
    removeFav(track.url)
  else
    table.insert(state.favourites, asTrack(track))
    saveFavourites()
  end
  render()
end

-- ---------- mpv IPC (via socat) ----------
local function mpvSend(jsonCmd, cb)
  local cmd = "printf '%s\\n' " .. sq(jsonCmd)
            .. " | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null | head -1"
  noctalia.runAsync(cmd, function(res)
    if cb then cb((res.stdout or ""):gsub("\n$", "")) end
  end)
end

local function mpvGet(prop, cb)
  mpvSend('{"command":["get_property","' .. prop .. '"]}', function(reply)
    if reply == "" then cb(nil); return end
    local ok, parsed = pcall(function() return noctalia.json.decode(reply) end)
    if ok and parsed then cb(parsed.data) else cb(nil) end
  end)
end

local function mpvSet(prop, value)
  mpvSend('{"command":["set_property","' .. prop .. '",' .. value .. ']}', nil)
end

-- ---------- playback ----------
local function socketExists(cb)
  noctalia.runAsync("test -S " .. sq(SOCKET) .. " && echo yes || echo no", function(res)
    cb((res.stdout or ""):match("yes") ~= nil)
  end)
end

local function playUrl(url, title, uploader, thumbnail)
  if not noctalia.commandExists("mpv") then
    state.status = "mpv not found on PATH"; render(); return
  end
  if not noctalia.commandExists("socat") then
    state.status = "socat not found — add it to media.nix"; render(); return
  end
  state.status = "Loading…"
  state.starting = true
  state.artPath = nil
  state.nowPlaying = { title = title or url, uploader = uploader or "", url = url, thumbnail = thumbnail or "", playing = true, paused = false }
  render()

  -- download album art (if we have a thumbnail URL) for the now-playing display
  if thumbnail and thumbnail ~= "" and noctalia.download then
    local dest = DATA_DIR .. "/nowart.jpg"
    noctalia.runAsync("mkdir -p " .. sq(DATA_DIR), function()
      noctalia.download(thumbnail, dest, function(ok)
        if ok then state.artPath = dest; render() end
      end)
    end)
  end

  local c = cfg()
  local quit = "printf '%s\\n' '{\"command\":[\"quit\"]}' | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null; "
  local ytdlRaw = "--ytdl-raw-options=extractor-args=youtube:player_client=" .. c.ytClient
  local mpvCmd = "setsid mpv --no-video --force-window=no --audio-display=no"
    .. " --ytdl-format=bestaudio/best --demuxer-max-bytes=256K"
    .. " --idle=once --input-ipc-server=" .. sq(SOCKET)
    .. " " .. sq(ytdlRaw)
    .. " --title=" .. sq("Noctalia Music")
    .. " " .. sq(url) .. " >/dev/null 2>&1 &"

  noctalia.runAsync(quit .. "sleep 0.2; rm -f " .. sq(SOCKET) .. "; " .. mpvCmd, function()
    state.status = "Playing"
    noctalia.runAsync("sleep 1.5", function()
      state.starting = false
      refreshNowPlaying()
    end)
  end)
end

local function playQueueIndex(i)
  local item = state.queue[i]
  if not item then return end
  state.queueIdx = i
  playUrl(item.url, item.title, item.uploader, item.thumbnail)
end

local function enqueue(track)
  table.insert(state.queue, track)
  state.status = "Added to queue"
  if not state.nowPlaying.playing then
    playQueueIndex(#state.queue)
  else
    render()
  end
end

-- Fisher-Yates shuffle of the queue, keeping the currently-playing track where
-- it is (shuffle only the items after the current one).
local function shuffleQueue()
  if #state.queue < 2 then return end
  local startI = (state.queueIdx > 0) and (state.queueIdx + 1) or 1
  for i = #state.queue, startI + 1, -1 do
    local j = math.random(startI, i)
    state.queue[i], state.queue[j] = state.queue[j], state.queue[i]
  end
end

local function playNext()
  if state.queueIdx > 0 and state.queueIdx < #state.queue then
    playQueueIndex(state.queueIdx + 1)
  elseif state.repeatQueue and #state.queue > 0 then
    -- loop back to the start; reshuffle first if shuffle is on
    if state.shuffle then shuffleQueue() end
    playQueueIndex(1)
  else
    state.nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false }
    state.queueIdx = 0
    state.position = 0
    state.duration = 0
    render()
  end
end

function refreshNowPlaying()
  socketExists(function(exists)
    if not exists then
      if state.starting then render(); return end
      if state.nowPlaying.playing then playNext() else render() end
      return
    end
    mpvGet("pause", function(paused)
      state.nowPlaying.paused = (paused == true)
      state.nowPlaying.playing = true
      mpvGet("playback-time", function(pt)
        state.position = tonumber(pt) or 0
        mpvGet("duration", function(dur)
          state.duration = tonumber(dur) or 0
          mpvGet("eof-reached", function(eof)
            if eof == true then playNext() else render() end
          end)
        end)
      end)
    end)
  end)
end

local function togglePause()
  if state.nowPlaying.paused then mpvSet("pause", "false") else mpvSet("pause", "true") end
  noctalia.runAsync("sleep 0.15", function() refreshNowPlaying() end)
end

-- relative seek within the current track (seconds; negative = back)
local function seekRelative(delta)
  if not state.nowPlaying.playing then return end
  mpvSend('{"command":["seek",' .. tostring(delta) .. ',"relative"]}', nil)
  noctalia.runAsync("sleep 0.15", function() refreshNowPlaying() end)
end

local function stopPlayback()
  mpvSend('{"command":["quit"]}', nil)
  state.nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false }
  state.queueIdx = 0
  state.position = 0
  state.duration = 0
  noctalia.runAsync("sleep 0.2; rm -f " .. sq(SOCKET), function() render() end)
end

local function removeQueueIndex(i)
  if not state.queue[i] then return end
  table.remove(state.queue, i)
  if i == state.queueIdx then
    state.queueIdx = 0
  elseif i < state.queueIdx then
    state.queueIdx = state.queueIdx - 1
  end
  render()
end

-- ---------- search ----------
local function parseSearchJson(raw)
  local out = {}
  if not raw or raw == "" then return out end
  local ok, parsed = pcall(function() return noctalia.json.decode(raw) end)
  if not ok or not parsed then return out end
  for _, e in ipairs(parsed.entries or {}) do
    local id = e.id or ""
    if id ~= "" then
      local url = e.url
      if not url or url == "" then url = "https://www.youtube.com/watch?v=" .. id end
      table.insert(out, {
        id = id, title = e.title or "Untitled", url = url,
        uploader = e.channel or e.uploader or "",
        duration = tonumber(e.duration) or 0, source = "YT",
        thumbnail = e.thumbnail or ("https://i.ytimg.com/vi/" .. id .. "/mqdefault.jpg"),
      })
    end
  end
  return out
end

local function doSearch(q)
  q = q and noctalia.string.trim(q) or ""
  state.query = q
  state.tab = TAB_SEARCH
  if q == "" then state.results = {}; render(); return end
  if not noctalia.commandExists("yt-dlp") then
    state.status = "yt-dlp not found on PATH"; state.results = {}; render(); return
  end
  state.busy = true
  render()

  local c = cfg()
  local ytCmd = "yt-dlp --ignore-config --flat-playlist --dump-single-json"
    .. " --extractor-args " .. sq("youtube:player_client=" .. c.ytClient)
    .. " " .. sq("ytsearch" .. tostring(c.results) .. ":" .. q) .. " 2>/dev/null"

  noctalia.runAsync(ytCmd, function(res)
    local ytResults = parseSearchJson(res.stdout)
    if c.localOn and c.localDir ~= "" then
      local findCmd = "find " .. sq(c.localDir) .. " -maxdepth 4 -type f "
        .. "\\( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.opus' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' \\) "
        .. "2>/dev/null | grep -i -F " .. sq(q) .. " | head -n " .. tostring(c.results)
      noctalia.runAsync(findCmd, function(lres)
        local merged = {}
        for line in (lres.stdout or ""):gmatch("[^\n]+") do
          local fname = line:gsub("^.*/", ""):gsub("%.%w+$", "")
          table.insert(merged, { id = line, title = fname, url = line,
            uploader = "Local file", duration = 0, source = "Local" })
        end
        for _, r in ipairs(ytResults) do table.insert(merged, r) end
        state.results = merged; state.busy = false; render()
      end)
    else
      state.results = ytResults; state.busy = false; render()
    end
  end)
end

-- ---------- playlists (queue <-> disk, plus YouTube playlist URLs) ----------
-- Append tracks to the queue; optionally replace it and start from the top.
local function addTracksToQueue(tracks, replace, statusText)
  if replace then
    state.queue = {}
    state.queueIdx = 0
  end
  for _, t in ipairs(tracks) do
    table.insert(state.queue, asTrack(t))
  end
  state.status = statusText
  state.tab = TAB_QUEUE
  if replace or not state.nowPlaying.playing then
    playQueueIndex(1)
  else
    render()
  end
end

local function loadYoutubePlaylist(url, replace)
  url = noctalia.string.trim(url)
  if url == "" then return end
  if not noctalia.commandExists("yt-dlp") then
    state.status = "yt-dlp not found"; render(); return
  end
  state.status = "Loading playlist…"
  render()
  local c = cfg()
  local cmd = "yt-dlp --ignore-config --flat-playlist --dump-single-json"
    .. " --extractor-args " .. sq("youtube:player_client=" .. c.ytClient)
    .. " " .. sq(url) .. " 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    local tracks = parseSearchJson(res.stdout)
    if #tracks == 0 then state.status = "Playlist empty or failed"; render(); return end
    addTracksToQueue(tracks, replace, "Loaded " .. #tracks .. " tracks")
  end)
end

local function saveQueueAsPlaylist(name)
  name = noctalia.string.trim(name)
  if name == "" or #state.queue == 0 then
    state.status = "Name the playlist and have a non-empty queue"
    render(); return
  end
  local copy = {}
  for _, t in ipairs(state.queue) do table.insert(copy, asTrack(t)) end
  state.playlists[name] = copy
  savePlaylists()
  state.status = "Saved playlist: " .. name
  render()
end

local function loadPlaylist(name, replace)
  local pl = state.playlists[name]
  if not pl then return end
  addTracksToQueue(pl, replace, (replace and "Playing " or "Queued ") .. name)
end

local function deletePlaylist(name)
  state.playlists[name] = nil
  savePlaylists()
  render()
end

-- ---------- launcher bridge ----------
-- The /music-yt launcher provider publishes play/queue requests on the shared
-- state channel ("launcher_request"). Poll it on open + every tick and act on
-- fresh requests (the nonce starts with the epoch the request was sent).
local lastLauncherNonce = nil

local function checkLauncherRequest()
  local ok, req = pcall(function()
    return noctalia.state and noctalia.state.get and noctalia.state.get("launcher_request")
  end)
  if not ok or type(req) ~= "table" or not req.url then return end
  local nonce = tostring(req.nonce or "")
  if nonce == "" or nonce == lastLauncherNonce then return end
  lastLauncherNonce = nonce
  local sent = tonumber(nonce:match("^(%d+)"))
  local now = tonumber(noctalia.formatTime("%s"))
  if sent and now and (now - sent) > 60 then return end
  local track = { title = req.title or req.url, url = req.url, uploader = "", duration = 0 }
  if req.action == "play" then
    table.insert(state.queue, track)
    playQueueIndex(#state.queue)
  else
    enqueue(track)
  end
end

-- ---------- format helpers ----------
local function fmtDuration(sec)
  sec = tonumber(sec) or 0
  if sec <= 0 then return "" end
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = math.floor(sec % 60)
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- =====================================================================
--  RENDER
-- =====================================================================

-- One list row: [lead?] [title / subtitle] [play] [+queue?] [extra?].
-- Buttons dispatch through the shared handler pool (rowAct at the bottom).
local function listRow(i, r)
  local kids = {}
  if r.lead then kids[#kids + 1] = r.lead end
  local textCol = {
    ui.label({ text = r.title, fontSize = 13, color = r.titleColor or "on_surface", maxLines = 1 }),
  }
  if r.sub and r.sub ~= "" then
    textCol[#textCol + 1] = ui.label({ text = r.sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
  end
  kids[#kids + 1] = ui.column({ gap = 1, flexGrow = 1 }, textCol)
  kids[#kids + 1] = ui.button({ glyph = "player-play", variant = "ghost", onClick = "onRowPlay" .. i })
  if r.add then
    kids[#kids + 1] = ui.button({ glyph = "plus", variant = "ghost", onClick = "onRowAdd" .. i })
  end
  if r.x then
    kids[#kids + 1] = ui.button({ glyph = r.x, variant = r.xVariant or "ghost", onClick = "onRowX" .. i })
  end
  return ui.row({ gap = 6, align = "center", key = state.tab .. "-" .. i }, kids)
end

local function emptyNote(text)
  return ui.label({ text = text, fontSize = 13, color = "on_surface_variant", paddingV = 8 })
end

local function overflowNote(total, extra)
  return ui.label({
    text = "…and " .. (total - POOL) .. " more" .. (extra or ""),
    fontSize = 11, color = "on_surface_variant", paddingV = 4,
  })
end

local function searchView()
  if state.busy then
    return ui.row({ gap = 8, align = "center", paddingV = 8 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Searching…", fontSize = 13, color = "on_surface_variant" }),
    })
  end
  if #state.results == 0 then
    return emptyNote(state.query == "" and "Type a search and press Enter." or "No results.")
  end
  local kids = {}
  for i, r in ipairs(state.results) do
    if i > POOL then kids[#kids + 1] = overflowNote(#state.results); break end
    local sub = r.uploader
    local dur = fmtDuration(r.duration)
    if dur ~= "" then sub = (sub ~= "" and sub .. " · " or "") .. dur end
    local fav = isFav(r.url)
    kids[#kids + 1] = listRow(i, {
      title = r.title, sub = sub, add = true,
      x = fav and "heart-filled" or "heart",
      xVariant = fav and "primary" or "ghost",
    })
  end
  return ui.column({ gap = 2 }, kids)
end

local function queueView()
  if #state.queue == 0 then
    return emptyNote("Queue is empty — search and add tracks.")
  end
  local kids = {}
  kids[#kids + 1] = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = #state.queue .. " in queue", fontSize = 11, color = "on_surface_variant" }),
    ui.button({ text = "Clear", glyph = "trash", variant = "ghost", onClick = "onQueueClear" }),
  })
  for i, item in ipairs(state.queue) do
    if i > POOL then kids[#kids + 1] = overflowNote(#state.queue, " (they still auto-play)"); break end
    local isCurrent = (i == state.queueIdx)
    kids[#kids + 1] = listRow(i, {
      lead = isCurrent
        and ui.glyph({ name = "volume", size = 14, color = "primary" })
        or ui.label({ text = tostring(i), fontSize = 11, color = "on_surface_variant", width = 20 }),
      title = item.title, sub = item.uploader,
      titleColor = isCurrent and "primary" or nil,
      x = "x",
    })
  end
  kids[#kids + 1] = ui.separator({ spacing = 6 })
  kids[#kids + 1] = ui.row({ gap = 6, align = "center" }, {
    ui.input({ key = "save-pl", placeholder = "Save queue as playlist…", flexGrow = 1, fontSize = 12, onSubmit = "onSavePlaylist" }),
  })
  return ui.column({ gap = 2 }, kids)
end

local function favView()
  if #state.favourites == 0 then
    return emptyNote("No favourites yet — tap the heart on a track.")
  end
  local kids = {}
  for i, t in ipairs(state.favourites) do
    if i > POOL then kids[#kids + 1] = overflowNote(#state.favourites); break end
    kids[#kids + 1] = listRow(i, {
      title = t.title, sub = t.uploader, add = true,
      x = "heart-filled", xVariant = "primary",
    })
  end
  return ui.column({ gap = 2 }, kids)
end

local function playlistsView()
  local kids = {}
  kids[#kids + 1] = ui.row({ gap = 6, align = "center" }, {
    ui.input({ key = "yt-pl-url", placeholder = "Load YouTube playlist URL…", flexGrow = 1, fontSize = 12, onSubmit = "onLoadYtPlaylist" }),
  })
  kids[#kids + 1] = ui.separator({ spacing = 6 })
  if #state.plNames == 0 then
    kids[#kids + 1] = emptyNote("No saved playlists — save a queue from the Queue tab.")
  else
    for i, name in ipairs(state.plNames) do
      if i > POOL then kids[#kids + 1] = overflowNote(#state.plNames); break end
      kids[#kids + 1] = listRow(i, {
        lead = ui.glyph({ name = "playlist", size = 16, color = "on_surface_variant" }),
        title = name, sub = #(state.playlists[name] or {}) .. " tracks",
        add = true, x = "trash",
      })
    end
  end
  return ui.column({ gap = 4 }, kids)
end

local function bodyView()
  if state.tab == TAB_QUEUE then return queueView() end
  if state.tab == TAB_FAVS then return favView() end
  if state.tab == TAB_PL then return playlistsView() end
  return searchView()
end

local function tabBar()
  local function tabBtn(id, label)
    return ui.button({
      text = label,
      variant = state.tab == id and "primary" or "ghost",
      onClick = "onTab_" .. id, flexGrow = 1,
    })
  end
  return ui.row({ gap = 4, align = "center" }, {
    tabBtn(TAB_SEARCH, "Search"),
    tabBtn(TAB_QUEUE, "Queue"),
    tabBtn(TAB_FAVS, "Favourites"),
    tabBtn(TAB_PL, "Playlists"),
    ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
  })
end

local function nowPlayingBar()
  local np = state.nowPlaying
  local hasTrack = np.playing and np.title ~= ""

  -- idle: one slim row (play starts the queue, if any)
  if not hasTrack then
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "music", size = 16, color = "on_surface_variant" }),
      ui.label({ text = "Nothing playing", fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ glyph = "player-play", variant = "ghost", onClick = "onPlayPause" }),
    })
  end

  local art
  if state.artPath then
    art = ui.image({ path = state.artPath, width = 48, height = 48, radius = 6, fit = "cover" })
  else
    art = ui.column({ width = 48, height = 48, align = "center", justify = "center", fill = "surface_variant", radius = 6 }, {
      ui.glyph({ name = "music", size = 22, color = "on_surface_variant" }),
    })
  end

  local frac = 0
  local infoKids = { art }
  local textKids = {
    ui.label({ text = np.title, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
    ui.label({ text = np.uploader ~= "" and np.uploader or "—", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
  }
  if state.duration > 0 then
    frac = state.position / state.duration
    textKids[#textKids + 1] = ui.progress({ progress = frac, fill = "primary", track = "surface_variant", radius = 2, height = 3 })
  end
  infoKids[#infoKids + 1] = ui.column({ gap = 2, flexGrow = 1 }, textKids)
  if state.duration > 0 then
    infoKids[#infoKids + 1] = ui.label({
      text = fmtDuration(state.position) .. " / " .. fmtDuration(state.duration),
      fontSize = 10, color = "on_surface_variant",
    })
  end

  local fav = isFav(np.url)
  local controls = ui.row({ gap = 4, align = "center", justify = "center" }, {
    ui.button({ glyph = "rewind-backward-10", variant = "ghost", onClick = "onSeekBack" }),
    ui.button({ glyph = "player-skip-back", variant = "ghost", onClick = "onPrev" }),
    ui.button({ glyph = np.paused and "player-play" or "player-pause", variant = "primary", onClick = "onPlayPause" }),
    ui.button({ glyph = "player-skip-forward", variant = "ghost", onClick = "onNext" }),
    ui.button({ glyph = "rewind-forward-10", variant = "ghost", onClick = "onSeekFwd" }),
    ui.button({ glyph = "player-stop", variant = "ghost", onClick = "onStop" }),
    ui.button({ glyph = "arrows-shuffle", variant = state.shuffle and "primary" or "ghost", onClick = "onShuffle" }),
    ui.button({ glyph = "repeat", variant = state.repeatQueue and "primary" or "ghost", onClick = "onRepeat" }),
    ui.button({ glyph = fav and "heart-filled" or "heart", variant = fav and "primary" or "ghost", onClick = "onNowFav" }),
  })

  return ui.column({ gap = 6 }, {
    ui.row({ gap = 10, align = "center" }, infoKids),
    controls,
  })
end

function render()
  local kids = { tabBar() }
  if state.tab == TAB_SEARCH then
    kids[#kids + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "search", placeholder = "Search YouTube…", flexGrow = 1, fontSize = 14,
        onChange = "onSearchChange", onSubmit = "onSearchSubmit",
      }),
    })
  end
  kids[#kids + 1] = ui.scroll({ flexGrow = 1, gap = 4 }, { bodyView() })
  if state.status ~= "" then
    kids[#kids + 1] = ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
  end
  kids[#kids + 1] = ui.separator({ spacing = 2 })
  kids[#kids + 1] = nowPlayingBar()
  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, kids))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen(context)
  state.status = ""
  panel.setWantsSecondTicks(true)
  if not state.loaded then loadData() end
  checkLauncherRequest()
  if context and noctalia.string.trim(context) ~= "" then
    doSearch(context)
  else
    render()
  end
end

function update()
  checkLauncherRequest()
  if state.nowPlaying.playing or state.starting then refreshNowPlaying() end
end

function onClose() panel.close() end

-- search
function onSearchSubmit(text) doSearch(text) end
function onSearchChange(text) state.query = text end

-- transport
function onPlayPause()
  if not state.nowPlaying.playing then
    if #state.queue > 0 then playQueueIndex(1) end
    return
  end
  togglePause()
end
function onPrev()
  -- a few seconds in, "previous" restarts the current track (like most players)
  if state.nowPlaying.playing and state.position > 5 then
    mpvSend('{"command":["seek",0,"absolute"]}', nil)
    noctalia.runAsync("sleep 0.15", function() refreshNowPlaying() end)
  elseif state.queueIdx > 1 then
    playQueueIndex(state.queueIdx - 1)
  end
end
function onNext() if state.nowPlaying.playing then playNext() end end
function onStop() stopPlayback() end
function onSeekBack() seekRelative(-10) end
function onSeekFwd() seekRelative(10) end
function onShuffle()
  state.shuffle = not state.shuffle
  if state.shuffle then shuffleQueue() end
  state.status = state.shuffle and "Shuffle on" or "Shuffle off"
  render()
end
function onRepeat()
  state.repeatQueue = not state.repeatQueue
  state.status = state.repeatQueue and "Repeat on" or "Repeat off"
  render()
end
function onNowFav() if state.nowPlaying.url ~= "" then toggleFav(state.nowPlaying) end end

-- tabs
function onTab_search() state.tab = TAB_SEARCH; render() end
function onTab_queue() state.tab = TAB_QUEUE; render() end
function onTab_favourites() state.tab = TAB_FAVS; render() end
function onTab_playlists() state.tab = TAB_PL; render() end

-- queue / playlists
function onQueueClear() state.queue = {}; state.queueIdx = 0; render() end
function onSavePlaylist(text) saveQueueAsPlaylist(text) end
function onLoadYtPlaylist(text) loadYoutubePlaylist(text, false) end

-- ---------------------------------------------------------------------
--  Per-row dispatch. Only one list is visible at a time, so every row
--  shares the same three slots: 1 = play, 2 = add to queue, 3 = extra
--  (heart on search, remove on queue/favourites, delete on playlists).
-- ---------------------------------------------------------------------
local function rowAct(i, slot)
  if state.tab == TAB_SEARCH then
    local r = state.results[i]
    if not r then return end
    if slot == 1 then
      table.insert(state.queue, asTrack(r))
      playQueueIndex(#state.queue)
    elseif slot == 2 then
      enqueue(asTrack(r))
    else
      toggleFav(r)
    end
  elseif state.tab == TAB_QUEUE then
    if slot == 1 then
      playQueueIndex(i)
    elseif slot == 3 then
      removeQueueIndex(i)
    end
  elseif state.tab == TAB_FAVS then
    local t = state.favourites[i]
    if not t then return end
    if slot == 1 then
      table.insert(state.queue, asTrack(t))
      playQueueIndex(#state.queue)
    elseif slot == 2 then
      enqueue(asTrack(t))
    else
      removeFav(t.url); render()
    end
  else -- playlists
    local name = state.plNames[i]
    if not name then return end
    if slot == 1 then
      loadPlaylist(name, true)
    elseif slot == 2 then
      loadPlaylist(name, false)
    else
      deletePlaylist(name)
    end
  end
end

-- ---------------------------------------------------------------------
--  Literal handler pool (POOL rows × 3 slots). _G is read-only in this
--  sandbox, so these cannot be generated in a loop — keep them literal
--  and keep the count in sync with POOL above.
-- ---------------------------------------------------------------------
function onRowPlay1() rowAct(1, 1) end function onRowAdd1() rowAct(1, 2) end function onRowX1() rowAct(1, 3) end
function onRowPlay2() rowAct(2, 1) end function onRowAdd2() rowAct(2, 2) end function onRowX2() rowAct(2, 3) end
function onRowPlay3() rowAct(3, 1) end function onRowAdd3() rowAct(3, 2) end function onRowX3() rowAct(3, 3) end
function onRowPlay4() rowAct(4, 1) end function onRowAdd4() rowAct(4, 2) end function onRowX4() rowAct(4, 3) end
function onRowPlay5() rowAct(5, 1) end function onRowAdd5() rowAct(5, 2) end function onRowX5() rowAct(5, 3) end
function onRowPlay6() rowAct(6, 1) end function onRowAdd6() rowAct(6, 2) end function onRowX6() rowAct(6, 3) end
function onRowPlay7() rowAct(7, 1) end function onRowAdd7() rowAct(7, 2) end function onRowX7() rowAct(7, 3) end
function onRowPlay8() rowAct(8, 1) end function onRowAdd8() rowAct(8, 2) end function onRowX8() rowAct(8, 3) end
function onRowPlay9() rowAct(9, 1) end function onRowAdd9() rowAct(9, 2) end function onRowX9() rowAct(9, 3) end
function onRowPlay10() rowAct(10, 1) end function onRowAdd10() rowAct(10, 2) end function onRowX10() rowAct(10, 3) end
function onRowPlay11() rowAct(11, 1) end function onRowAdd11() rowAct(11, 2) end function onRowX11() rowAct(11, 3) end
function onRowPlay12() rowAct(12, 1) end function onRowAdd12() rowAct(12, 2) end function onRowX12() rowAct(12, 3) end
function onRowPlay13() rowAct(13, 1) end function onRowAdd13() rowAct(13, 2) end function onRowX13() rowAct(13, 3) end
function onRowPlay14() rowAct(14, 1) end function onRowAdd14() rowAct(14, 2) end function onRowX14() rowAct(14, 3) end
function onRowPlay15() rowAct(15, 1) end function onRowAdd15() rowAct(15, 2) end function onRowX15() rowAct(15, 3) end
function onRowPlay16() rowAct(16, 1) end function onRowAdd16() rowAct(16, 2) end function onRowX16() rowAct(16, 3) end
function onRowPlay17() rowAct(17, 1) end function onRowAdd17() rowAct(17, 2) end function onRowX17() rowAct(17, 3) end
function onRowPlay18() rowAct(18, 1) end function onRowAdd18() rowAct(18, 2) end function onRowX18() rowAct(18, 3) end
function onRowPlay19() rowAct(19, 1) end function onRowAdd19() rowAct(19, 2) end function onRowX19() rowAct(19, 3) end
function onRowPlay20() rowAct(20, 1) end function onRowAdd20() rowAct(20, 2) end function onRowX20() rowAct(20, 3) end
function onRowPlay21() rowAct(21, 1) end function onRowAdd21() rowAct(21, 2) end function onRowX21() rowAct(21, 3) end
function onRowPlay22() rowAct(22, 1) end function onRowAdd22() rowAct(22, 2) end function onRowX22() rowAct(22, 3) end
function onRowPlay23() rowAct(23, 1) end function onRowAdd23() rowAct(23, 2) end function onRowX23() rowAct(23, 3) end
function onRowPlay24() rowAct(24, 1) end function onRowAdd24() rowAct(24, 2) end function onRowX24() rowAct(24, 3) end
function onRowPlay25() rowAct(25, 1) end function onRowAdd25() rowAct(25, 2) end function onRowX25() rowAct(25, 3) end
function onRowPlay26() rowAct(26, 1) end function onRowAdd26() rowAct(26, 2) end function onRowX26() rowAct(26, 3) end
function onRowPlay27() rowAct(27, 1) end function onRowAdd27() rowAct(27, 2) end function onRowX27() rowAct(27, 3) end
function onRowPlay28() rowAct(28, 1) end function onRowAdd28() rowAct(28, 2) end function onRowX28() rowAct(28, 3) end
function onRowPlay29() rowAct(29, 1) end function onRowAdd29() rowAct(29, 2) end function onRowX29() rowAct(29, 3) end
function onRowPlay30() rowAct(30, 1) end function onRowAdd30() rowAct(30, 2) end function onRowX30() rowAct(30, 3) end
function onRowPlay31() rowAct(31, 1) end function onRowAdd31() rowAct(31, 2) end function onRowX31() rowAct(31, 3) end
function onRowPlay32() rowAct(32, 1) end function onRowAdd32() rowAct(32, 2) end function onRowX32() rowAct(32, 3) end
function onRowPlay33() rowAct(33, 1) end function onRowAdd33() rowAct(33, 2) end function onRowX33() rowAct(33, 3) end
function onRowPlay34() rowAct(34, 1) end function onRowAdd34() rowAct(34, 2) end function onRowX34() rowAct(34, 3) end
function onRowPlay35() rowAct(35, 1) end function onRowAdd35() rowAct(35, 2) end function onRowX35() rowAct(35, 3) end
function onRowPlay36() rowAct(36, 1) end function onRowAdd36() rowAct(36, 2) end function onRowX36() rowAct(36, 3) end
function onRowPlay37() rowAct(37, 1) end function onRowAdd37() rowAct(37, 2) end function onRowX37() rowAct(37, 3) end
function onRowPlay38() rowAct(38, 1) end function onRowAdd38() rowAct(38, 2) end function onRowX38() rowAct(38, 3) end
function onRowPlay39() rowAct(39, 1) end function onRowAdd39() rowAct(39, 2) end function onRowX39() rowAct(39, 3) end
function onRowPlay40() rowAct(40, 1) end function onRowAdd40() rowAct(40, 2) end function onRowX40() rowAct(40, 3) end
function onRowPlay41() rowAct(41, 1) end function onRowAdd41() rowAct(41, 2) end function onRowX41() rowAct(41, 3) end
function onRowPlay42() rowAct(42, 1) end function onRowAdd42() rowAct(42, 2) end function onRowX42() rowAct(42, 3) end
function onRowPlay43() rowAct(43, 1) end function onRowAdd43() rowAct(43, 2) end function onRowX43() rowAct(43, 3) end
function onRowPlay44() rowAct(44, 1) end function onRowAdd44() rowAct(44, 2) end function onRowX44() rowAct(44, 3) end
function onRowPlay45() rowAct(45, 1) end function onRowAdd45() rowAct(45, 2) end function onRowX45() rowAct(45, 3) end
function onRowPlay46() rowAct(46, 1) end function onRowAdd46() rowAct(46, 2) end function onRowX46() rowAct(46, 3) end
function onRowPlay47() rowAct(47, 1) end function onRowAdd47() rowAct(47, 2) end function onRowX47() rowAct(47, 3) end
function onRowPlay48() rowAct(48, 1) end function onRowAdd48() rowAct(48, 2) end function onRowX48() rowAct(48, 3) end
function onRowPlay49() rowAct(49, 1) end function onRowAdd49() rowAct(49, 2) end function onRowX49() rowAct(49, 3) end
function onRowPlay50() rowAct(50, 1) end function onRowAdd50() rowAct(50, 2) end function onRowX50() rowAct(50, 3) end
function onRowPlay51() rowAct(51, 1) end function onRowAdd51() rowAct(51, 2) end function onRowX51() rowAct(51, 3) end
function onRowPlay52() rowAct(52, 1) end function onRowAdd52() rowAct(52, 2) end function onRowX52() rowAct(52, 3) end
function onRowPlay53() rowAct(53, 1) end function onRowAdd53() rowAct(53, 2) end function onRowX53() rowAct(53, 3) end
function onRowPlay54() rowAct(54, 1) end function onRowAdd54() rowAct(54, 2) end function onRowX54() rowAct(54, 3) end
function onRowPlay55() rowAct(55, 1) end function onRowAdd55() rowAct(55, 2) end function onRowX55() rowAct(55, 3) end
function onRowPlay56() rowAct(56, 1) end function onRowAdd56() rowAct(56, 2) end function onRowX56() rowAct(56, 3) end
function onRowPlay57() rowAct(57, 1) end function onRowAdd57() rowAct(57, 2) end function onRowX57() rowAct(57, 3) end
function onRowPlay58() rowAct(58, 1) end function onRowAdd58() rowAct(58, 2) end function onRowX58() rowAct(58, 3) end
function onRowPlay59() rowAct(59, 1) end function onRowAdd59() rowAct(59, 2) end function onRowX59() rowAct(59, 3) end
function onRowPlay60() rowAct(60, 1) end function onRowAdd60() rowAct(60, 2) end function onRowX60() rowAct(60, 3) end
function onRowPlay61() rowAct(61, 1) end function onRowAdd61() rowAct(61, 2) end function onRowX61() rowAct(61, 3) end
function onRowPlay62() rowAct(62, 1) end function onRowAdd62() rowAct(62, 2) end function onRowX62() rowAct(62, 3) end
function onRowPlay63() rowAct(63, 1) end function onRowAdd63() rowAct(63, 2) end function onRowX63() rowAct(63, 3) end
function onRowPlay64() rowAct(64, 1) end function onRowAdd64() rowAct(64, 2) end function onRowX64() rowAct(64, 3) end
function onRowPlay65() rowAct(65, 1) end function onRowAdd65() rowAct(65, 2) end function onRowX65() rowAct(65, 3) end
function onRowPlay66() rowAct(66, 1) end function onRowAdd66() rowAct(66, 2) end function onRowX66() rowAct(66, 3) end
function onRowPlay67() rowAct(67, 1) end function onRowAdd67() rowAct(67, 2) end function onRowX67() rowAct(67, 3) end
function onRowPlay68() rowAct(68, 1) end function onRowAdd68() rowAct(68, 2) end function onRowX68() rowAct(68, 3) end
function onRowPlay69() rowAct(69, 1) end function onRowAdd69() rowAct(69, 2) end function onRowX69() rowAct(69, 3) end
function onRowPlay70() rowAct(70, 1) end function onRowAdd70() rowAct(70, 2) end function onRowX70() rowAct(70, 3) end
function onRowPlay71() rowAct(71, 1) end function onRowAdd71() rowAct(71, 2) end function onRowX71() rowAct(71, 3) end
function onRowPlay72() rowAct(72, 1) end function onRowAdd72() rowAct(72, 2) end function onRowX72() rowAct(72, 3) end
function onRowPlay73() rowAct(73, 1) end function onRowAdd73() rowAct(73, 2) end function onRowX73() rowAct(73, 3) end
function onRowPlay74() rowAct(74, 1) end function onRowAdd74() rowAct(74, 2) end function onRowX74() rowAct(74, 3) end
function onRowPlay75() rowAct(75, 1) end function onRowAdd75() rowAct(75, 2) end function onRowX75() rowAct(75, 3) end
function onRowPlay76() rowAct(76, 1) end function onRowAdd76() rowAct(76, 2) end function onRowX76() rowAct(76, 3) end
function onRowPlay77() rowAct(77, 1) end function onRowAdd77() rowAct(77, 2) end function onRowX77() rowAct(77, 3) end
function onRowPlay78() rowAct(78, 1) end function onRowAdd78() rowAct(78, 2) end function onRowX78() rowAct(78, 3) end
function onRowPlay79() rowAct(79, 1) end function onRowAdd79() rowAct(79, 2) end function onRowX79() rowAct(79, 3) end
function onRowPlay80() rowAct(80, 1) end function onRowAdd80() rowAct(80, 2) end function onRowX80() rowAct(80, 3) end
