-- =============================================================================
--  panel.luau — Music (YouTube + Local)  v0.3.0
--  yt-dlp + mpv backend. Search YouTube, play/queue, favourites, playlists.
--  Layout: search always on top, tabs (Queue / Favourites / Playlists) below,
--  single ui.scroll body (multiple scroll regions break input focus — do not
--  reintroduce them).
-- =============================================================================

local SOCKET   = "/tmp/noctalia-music-mpv.sock"
local DATA_DIR = noctalia.expandPath("~/.config/noctalia-music")
local FAV_FILE = DATA_DIR .. "/favourites.json"
local PL_FILE  = DATA_DIR .. "/playlists.json"

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
local TAB_QUEUE = "queue"
local TAB_FAVS  = "favourites"
local TAB_PL    = "playlists"

local state = {
  tab        = TAB_QUEUE,
  query      = "",
  results    = {},   -- search results { {id,title,url,uploader,duration,source} }
  queue      = {},   -- { {title,url,uploader,duration} }
  queueIdx   = 0,
  favourites = {},   -- { {title,url,uploader,duration} }
  playlists  = {},   -- { name = { {track}, ... }, ... }
  plNames    = {},   -- sorted list of playlist names (for stable row indexing)
  nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false },
  position   = 0,
  duration   = 0,
  starting   = false,
  busy       = false,
  status     = "",
  loaded     = false,  -- have we loaded persisted data yet
}

-- ---------- persistence ----------
-- Load favourites + playlists from disk into state (once, on open).
local function loadData()
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR), function()
    -- favourites
    noctalia.runAsync("cat " .. sq(FAV_FILE) .. " 2>/dev/null", function(res)
      local ok, parsed = pcall(function() return noctalia.json.decode(res.stdout or "") end)
      if ok and type(parsed) == "table" then state.favourites = parsed end
      -- playlists
      noctalia.runAsync("cat " .. sq(PL_FILE) .. " 2>/dev/null", function(r2)
        local ok2, parsed2 = pcall(function() return noctalia.json.decode(r2.stdout or "") end)
        if ok2 and type(parsed2) == "table" then
          state.playlists = parsed2
          state.plNames = {}
          for name, _ in pairs(parsed2) do table.insert(state.plNames, name) end
          table.sort(state.plNames)
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
  -- refresh sorted name list
  state.plNames = {}
  for name, _ in pairs(state.playlists) do table.insert(state.plNames, name) end
  table.sort(state.plNames)
end

-- ---------- favourites helpers ----------
local function isFav(url)
  for _, t in ipairs(state.favourites) do
    if t.url == url then return true end
  end
  return false
end

local function addFav(track)
  if isFav(track.url) then return end
  table.insert(state.favourites, {
    title = track.title, url = track.url,
    uploader = track.uploader or "", duration = track.duration or 0,
  })
  saveFavourites()
end

local function removeFav(url)
  for i, t in ipairs(state.favourites) do
    if t.url == url then table.remove(state.favourites, i); break end
  end
  saveFavourites()
end

local function toggleFav(track)
  if isFav(track.url) then removeFav(track.url) else addFav(track) end
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

local function playUrl(url, title, uploader)
  if not noctalia.commandExists("mpv") then
    state.status = "mpv not found on PATH"; render(); return
  end
  if not noctalia.commandExists("socat") then
    state.status = "socat not found — add it to media.nix"; render(); return
  end
  state.status = "Loading…"
  state.starting = true
  state.nowPlaying = { title = title or url, uploader = uploader or "", url = url, playing = true, paused = false }
  render()

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
  playUrl(item.url, item.title, item.uploader)
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

local function playNext()
  if state.queueIdx > 0 and state.queueIdx < #state.queue then
    playQueueIndex(state.queueIdx + 1)
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

local function stopPlayback()
  mpvSend('{"command":["quit"]}', nil)
  state.nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false }
  state.queueIdx = 0
  state.position = 0
  state.duration = 0
  noctalia.runAsync("sleep 0.2; rm -f " .. sq(SOCKET), function() render() end)
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
      })
    end
  end
  return out
end

local function doSearch(q)
  q = q and noctalia.string.trim(q) or ""
  state.query = q
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
        local locals = {}
        for line in (lres.stdout or ""):gmatch("[^\n]+") do
          local fname = line:gsub("^.*/", ""):gsub("%.%w+$", "")
          table.insert(locals, { id = line, title = fname, url = line,
            uploader = "Local file", duration = 0, source = "Local" })
        end
        local merged = {}
        for _, r in ipairs(locals) do table.insert(merged, r) end
        for _, r in ipairs(ytResults) do table.insert(merged, r) end
        state.results = merged; state.busy = false; render()
      end)
    else
      state.results = ytResults; state.busy = false; render()
    end
  end)
end

-- ---------- YouTube playlist by URL ----------
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
    if replace then
      state.queue = {}
      state.queueIdx = 0
    end
    for _, t in ipairs(tracks) do
      table.insert(state.queue, { title = t.title, url = t.url, uploader = t.uploader, duration = t.duration })
    end
    state.status = "Loaded " .. #tracks .. " tracks"
    state.tab = TAB_QUEUE
    if replace or not state.nowPlaying.playing then
      playQueueIndex(1)
    else
      render()
    end
  end)
end

-- ---------- local playlists (save/load the queue) ----------
local function saveQueueAsPlaylist(name)
  name = noctalia.string.trim(name)
  if name == "" or #state.queue == 0 then
    state.status = "Name the playlist and have a non-empty queue"
    render(); return
  end
  local copy = {}
  for _, t in ipairs(state.queue) do
    table.insert(copy, { title = t.title, url = t.url, uploader = t.uploader, duration = t.duration })
  end
  state.playlists[name] = copy
  savePlaylists()
  state.status = "Saved playlist: " .. name
  render()
end

local function loadPlaylist(name, replace)
  local pl = state.playlists[name]
  if not pl then return end
  if replace then state.queue = {}; state.queueIdx = 0 end
  for _, t in ipairs(pl) do
    table.insert(state.queue, { title = t.title, url = t.url, uploader = t.uploader, duration = t.duration })
  end
  state.status = (replace and "Playing " or "Queued ") .. name
  state.tab = TAB_QUEUE
  if replace or not state.nowPlaying.playing then playQueueIndex(1) else render() end
end

local function deletePlaylist(name)
  state.playlists[name] = nil
  savePlaylists()
  render()
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

local function starButton(track, keyPrefix)
  local fav = isFav(track.url)
  return ui.button({
    glyph = fav and "heart-filled" or "heart",
    variant = fav and "primary" or "ghost",
    onClick = keyPrefix,
  })
end

local function nowPlayingHeader()
  local np = state.nowPlaying
  local hasTrack = np.playing and np.title ~= ""
  local titleText = hasTrack and np.title or "Nothing playing"
  local subText = hasTrack and (np.uploader ~= "" and np.uploader or "—") or ""
  local playGlyph = np.paused and "player-play" or "player-pause"
  if not hasTrack then playGlyph = "player-play" end

  local progressText = ""
  if hasTrack and state.duration > 0 then
    progressText = fmtDuration(state.position) .. " / " .. fmtDuration(state.duration)
  end

  local headerChildren = {
    ui.box({ width = 56, height = 56, radius = 8, fill = "surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = titleText, fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = subText, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
      (progressText ~= "" and ui.label({ text = progressText, fontSize = 10, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
    }),
  }
  -- star for the now-playing track
  if hasTrack then
    table.insert(headerChildren, ui.button({
      glyph = isFav(np.url) and "heart-filled" or "heart",
      variant = isFav(np.url) and "primary" or "ghost",
      onClick = "onNowFav",
    }))
  end
  table.insert(headerChildren, ui.row({ gap = 4, align = "center" }, {
    ui.button({ glyph = "player-skip-back", variant = "ghost", onClick = "onPrev" }),
    ui.button({ glyph = playGlyph, variant = "primary", onClick = "onPlayPause" }),
    ui.button({ glyph = "player-skip-forward", variant = "ghost", onClick = "onNext" }),
    ui.button({ glyph = "player-stop", variant = "ghost", onClick = "onStop" }),
  }))

  return ui.row({ gap = 12, align = "center" }, headerChildren)
end

local function searchBox()
  return ui.input({
    key = "search",
    placeholder = "Search YouTube…",
    flexGrow = 1,
    fontSize = 14,
    onChange = "onSearchChange",
    onSubmit = "onSearchSubmit",
  })
end

local function sourceBadge(src)
  local color = src == "YT" and "primary" or "secondary"
  return ui.label({ text = src, fontSize = 10, fontWeight = "bold", color = color })
end

local function resultRow(r, idx)
  local dur = fmtDuration(r.duration)
  return ui.row({ gap = 6, align = "center", key = "res-" .. idx }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = r.title, fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        sourceBadge(r.source),
        ui.label({ text = r.uploader, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
        (dur ~= "" and ui.label({ text = dur, fontSize = 10, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
      }),
    }),
    ui.button({ glyph = isFav(r.url) and "heart-filled" or "heart", variant = isFav(r.url) and "primary" or "ghost", onClick = "onResFav" .. idx }),
    ui.button({ glyph = "player-play", variant = "outline", onClick = "onResPlay" .. idx }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onResQueue" .. idx }),
  })
end

local function resultsSection()
  if state.busy then
    return ui.row({ gap = 8, align = "center", paddingV = 8 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Searching…", fontSize = 13, color = "on_surface_variant" }),
    })
  end
  if #state.results == 0 then
    return ui.label({ text = "No results.", fontSize = 13, color = "on_surface_variant", paddingV = 8 })
  end
  local children = {}
  for i, r in ipairs(state.results) do
    table.insert(children, resultRow(r, i))
    if i < #state.results then table.insert(children, ui.separator({ spacing = 4 })) end
  end
  return ui.column({ gap = 2 }, children)
end

-- ---- queue view ----
local function queueRow(item, idx)
  local isCurrent = (idx == state.queueIdx)
  return ui.row({ gap = 8, align = "center", key = "q-" .. idx }, {
    (isCurrent
      and ui.glyph({ name = "volume", size = 14, color = "primary" })
      or ui.label({ text = tostring(idx), fontSize = 11, color = "on_surface_variant", width = 20 })),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = item.title, fontSize = 13, color = isCurrent and "primary" or "on_surface", maxLines = 1 }),
      ui.label({ text = item.uploader, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({ glyph = "player-play", variant = "ghost", onClick = "onQPlay" .. idx }),
    ui.button({ glyph = "x", variant = "ghost", onClick = "onQDel" .. idx }),
  })
end

local function queueView()
  local children = {}
  table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = #state.queue .. " in queue", fontSize = 11, color = "on_surface_variant" }),
    ui.button({ text = "Clear", glyph = "trash", variant = "ghost", onClick = "onQueueClear" }),
  }))
  if #state.queue == 0 then
    table.insert(children, ui.label({ text = "Queue is empty. Search and add tracks.", fontSize = 13, color = "on_surface_variant", paddingV = 8 }))
  else
    for i, item in ipairs(state.queue) do table.insert(children, queueRow(item, i)) end
    -- save-as-playlist row
    table.insert(children, ui.separator({ spacing = 6 }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.input({ key = "save-pl", placeholder = "Save queue as playlist…", flexGrow = 1, fontSize = 12, onSubmit = "onSavePlaylist" }),
    }))
  end
  return ui.column({ gap = 2 }, children)
end

-- ---- favourites view ----
local function favRow(t, idx)
  return ui.row({ gap = 8, align = "center", key = "fav-" .. idx }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = t.title, fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.label({ text = t.uploader, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({ glyph = "player-play", variant = "outline", onClick = "onFavPlay" .. idx }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onFavQueue" .. idx }),
    ui.button({ glyph = "heart-filled", variant = "primary", onClick = "onFavDel" .. idx }),
  })
end

local function favView()
  if #state.favourites == 0 then
    return ui.label({ text = "No favourites yet. Tap the heart on a track.", fontSize = 13, color = "on_surface_variant", paddingV = 8 })
  end
  local children = {}
  for i, t in ipairs(state.favourites) do table.insert(children, favRow(t, i)) end
  return ui.column({ gap = 2 }, children)
end

-- ---- playlists view ----
local function playlistRow(name, idx)
  local count = #(state.playlists[name] or {})
  return ui.row({ gap = 8, align = "center", key = "pl-" .. idx }, {
    ui.glyph({ name = "playlist", size = 16, color = "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = name, fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.label({ text = count .. " tracks", fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.button({ glyph = "player-play", variant = "outline", onClick = "onPlPlay" .. idx }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onPlQueue" .. idx }),
    ui.button({ glyph = "trash", variant = "ghost", onClick = "onPlDel" .. idx }),
  })
end

local function playlistsView()
  local children = {}
  -- load-from-URL row
  table.insert(children, ui.row({ gap = 6, align = "center" }, {
    ui.input({ key = "yt-pl-url", placeholder = "Load YouTube playlist URL…", flexGrow = 1, fontSize = 12, onSubmit = "onLoadYtPlaylist" }),
  }))
  table.insert(children, ui.separator({ spacing = 6 }))
  if #state.plNames == 0 then
    table.insert(children, ui.label({ text = "No saved playlists. Save a queue from the Queue tab.", fontSize = 13, color = "on_surface_variant", paddingV = 6 }))
  else
    for i, name in ipairs(state.plNames) do table.insert(children, playlistRow(name, i)) end
  end
  return ui.column({ gap = 4 }, children)
end

local function bodyView()
  if state.tab == TAB_FAVS then return favView() end
  if state.tab == TAB_PL then return playlistsView() end
  return queueView()
end

-- vertical tab strip (right side)
local function tabStrip()
  local function tabBtn(id, label, glyph)
    return ui.button({
      text = label, glyph = glyph,
      variant = state.tab == id and "primary" or "ghost",
      onClick = "onTab_" .. id,
      width = 130,
    })
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    tabBtn(TAB_QUEUE, "Queue", "list"),
    tabBtn(TAB_FAVS, "Favourites", "heart"),
    tabBtn(TAB_PL, "Playlists", "playlist"),
  })
end

function render()
  -- Body: search results take over when searching, else the active tab content.
  local body
  if state.busy or #state.results > 0 then
    body = ui.column({ gap = 6 }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = "Results", fontSize = 12, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
        ui.button({ text = "Clear", glyph = "x", variant = "ghost", onClick = "onClearSearch" }),
      }),
      resultsSection(),
    })
  else
    body = bodyView()
  end

  -- Left column: header, now-playing, search, status, then the scrolling body.
  local leftColumn = ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Music", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
    }),
    nowPlayingHeader(),
    ui.separator({ spacing = 2 }),
    ui.row({ gap = 8, align = "center" }, { searchBox() }),
    (state.status ~= "" and ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
    ui.scroll({ flexGrow = 1, gap = 4 }, { body }),
  })

  -- Top-level: left content grows, right tab strip is fixed-width.
  panel.render(ui.row({ flexGrow = 1, gap = 14, align = "stretch" }, {
    leftColumn,
    ui.separator({ orientation = "vertical", spacing = 2 }),
    tabStrip(),
  }))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen(context)
  state.status = ""
  panel.setWantsSecondTicks(true)
  if not state.loaded then loadData() end
  if context and noctalia.string.trim(context) ~= "" then
    doSearch(context)
  else
    render()
  end
end

function update()
  if state.nowPlaying.playing or state.starting then refreshNowPlaying() end
end

function onClose() panel.close() end

-- search
function onSearchSubmit(text) doSearch(text) end
function onSearchChange(text) state.query = text end
function onClearSearch() state.results = {}; state.query = ""; render() end

-- transport
function onPlayPause()
  if not state.nowPlaying.playing then
    if #state.queue > 0 then playQueueIndex(1) end
    return
  end
  togglePause()
end
function onPrev() if state.queueIdx > 1 then playQueueIndex(state.queueIdx - 1) end end
function onNext() if state.queueIdx > 0 and state.queueIdx < #state.queue then playQueueIndex(state.queueIdx + 1) end end
function onStop() stopPlayback() end
function onNowFav() if state.nowPlaying.url ~= "" then toggleFav(state.nowPlaying) end end

-- tabs
function onTab_queue() state.tab = TAB_QUEUE; render() end
function onTab_favourites() state.tab = TAB_FAVS; render() end
function onTab_playlists() state.tab = TAB_PL; render() end

-- queue
function onQueueClear() state.queue = {}; state.queueIdx = 0; render() end
function onSavePlaylist(text) saveQueueAsPlaylist(text) end

-- playlists
function onLoadYtPlaylist(text) loadYoutubePlaylist(text, false) end

-- ---- dispatchers for per-row handlers ----
local function resPlay(i) local r = state.results[i]; if r then table.insert(state.queue, {title=r.title,url=r.url,uploader=r.uploader,duration=r.duration}); playQueueIndex(#state.queue) end end
local function resQueue(i) local r = state.results[i]; if r then enqueue({title=r.title,url=r.url,uploader=r.uploader,duration=r.duration}) end end
local function resFav(i) local r = state.results[i]; if r then toggleFav(r) end end
local function qPlay(i) playQueueIndex(i) end
local function qDel(i) if state.queue[i] then table.remove(state.queue,i); if i==state.queueIdx then state.queueIdx=0 elseif i<state.queueIdx then state.queueIdx=state.queueIdx-1 end; render() end end
local function favPlay(i) local t = state.favourites[i]; if t then table.insert(state.queue,{title=t.title,url=t.url,uploader=t.uploader,duration=t.duration}); playQueueIndex(#state.queue) end end
local function favQueue(i) local t = state.favourites[i]; if t then enqueue({title=t.title,url=t.url,uploader=t.uploader,duration=t.duration}) end end
local function favDel(i) local t = state.favourites[i]; if t then removeFav(t.url); render() end end
local function plPlay(i) local n = state.plNames[i]; if n then loadPlaylist(n, true) end end
local function plQueue(i) local n = state.plNames[i]; if n then loadPlaylist(n, false) end end
local function plDel(i) local n = state.plNames[i]; if n then deletePlaylist(n) end end

-- ---- explicit global handler pool (40 each; _G is read-only so declare literally) ----
function onResPlay1() resPlay(1) end
function onResQueue1() resQueue(1) end
function onResFav1() resFav(1) end
function onQPlay1() qPlay(1) end
function onQDel1() qDel(1) end
function onFavPlay1() favPlay(1) end
function onFavQueue1() favQueue(1) end
function onFavDel1() favDel(1) end
function onPlPlay1() plPlay(1) end
function onPlQueue1() plQueue(1) end
function onPlDel1() plDel(1) end
function onResPlay2() resPlay(2) end
function onResQueue2() resQueue(2) end
function onResFav2() resFav(2) end
function onQPlay2() qPlay(2) end
function onQDel2() qDel(2) end
function onFavPlay2() favPlay(2) end
function onFavQueue2() favQueue(2) end
function onFavDel2() favDel(2) end
function onPlPlay2() plPlay(2) end
function onPlQueue2() plQueue(2) end
function onPlDel2() plDel(2) end
function onResPlay3() resPlay(3) end
function onResQueue3() resQueue(3) end
function onResFav3() resFav(3) end
function onQPlay3() qPlay(3) end
function onQDel3() qDel(3) end
function onFavPlay3() favPlay(3) end
function onFavQueue3() favQueue(3) end
function onFavDel3() favDel(3) end
function onPlPlay3() plPlay(3) end
function onPlQueue3() plQueue(3) end
function onPlDel3() plDel(3) end
function onResPlay4() resPlay(4) end
function onResQueue4() resQueue(4) end
function onResFav4() resFav(4) end
function onQPlay4() qPlay(4) end
function onQDel4() qDel(4) end
function onFavPlay4() favPlay(4) end
function onFavQueue4() favQueue(4) end
function onFavDel4() favDel(4) end
function onPlPlay4() plPlay(4) end
function onPlQueue4() plQueue(4) end
function onPlDel4() plDel(4) end
function onResPlay5() resPlay(5) end
function onResQueue5() resQueue(5) end
function onResFav5() resFav(5) end
function onQPlay5() qPlay(5) end
function onQDel5() qDel(5) end
function onFavPlay5() favPlay(5) end
function onFavQueue5() favQueue(5) end
function onFavDel5() favDel(5) end
function onPlPlay5() plPlay(5) end
function onPlQueue5() plQueue(5) end
function onPlDel5() plDel(5) end
function onResPlay6() resPlay(6) end
function onResQueue6() resQueue(6) end
function onResFav6() resFav(6) end
function onQPlay6() qPlay(6) end
function onQDel6() qDel(6) end
function onFavPlay6() favPlay(6) end
function onFavQueue6() favQueue(6) end
function onFavDel6() favDel(6) end
function onPlPlay6() plPlay(6) end
function onPlQueue6() plQueue(6) end
function onPlDel6() plDel(6) end
function onResPlay7() resPlay(7) end
function onResQueue7() resQueue(7) end
function onResFav7() resFav(7) end
function onQPlay7() qPlay(7) end
function onQDel7() qDel(7) end
function onFavPlay7() favPlay(7) end
function onFavQueue7() favQueue(7) end
function onFavDel7() favDel(7) end
function onPlPlay7() plPlay(7) end
function onPlQueue7() plQueue(7) end
function onPlDel7() plDel(7) end
function onResPlay8() resPlay(8) end
function onResQueue8() resQueue(8) end
function onResFav8() resFav(8) end
function onQPlay8() qPlay(8) end
function onQDel8() qDel(8) end
function onFavPlay8() favPlay(8) end
function onFavQueue8() favQueue(8) end
function onFavDel8() favDel(8) end
function onPlPlay8() plPlay(8) end
function onPlQueue8() plQueue(8) end
function onPlDel8() plDel(8) end
function onResPlay9() resPlay(9) end
function onResQueue9() resQueue(9) end
function onResFav9() resFav(9) end
function onQPlay9() qPlay(9) end
function onQDel9() qDel(9) end
function onFavPlay9() favPlay(9) end
function onFavQueue9() favQueue(9) end
function onFavDel9() favDel(9) end
function onPlPlay9() plPlay(9) end
function onPlQueue9() plQueue(9) end
function onPlDel9() plDel(9) end
function onResPlay10() resPlay(10) end
function onResQueue10() resQueue(10) end
function onResFav10() resFav(10) end
function onQPlay10() qPlay(10) end
function onQDel10() qDel(10) end
function onFavPlay10() favPlay(10) end
function onFavQueue10() favQueue(10) end
function onFavDel10() favDel(10) end
function onPlPlay10() plPlay(10) end
function onPlQueue10() plQueue(10) end
function onPlDel10() plDel(10) end
function onResPlay11() resPlay(11) end
function onResQueue11() resQueue(11) end
function onResFav11() resFav(11) end
function onQPlay11() qPlay(11) end
function onQDel11() qDel(11) end
function onFavPlay11() favPlay(11) end
function onFavQueue11() favQueue(11) end
function onFavDel11() favDel(11) end
function onPlPlay11() plPlay(11) end
function onPlQueue11() plQueue(11) end
function onPlDel11() plDel(11) end
function onResPlay12() resPlay(12) end
function onResQueue12() resQueue(12) end
function onResFav12() resFav(12) end
function onQPlay12() qPlay(12) end
function onQDel12() qDel(12) end
function onFavPlay12() favPlay(12) end
function onFavQueue12() favQueue(12) end
function onFavDel12() favDel(12) end
function onPlPlay12() plPlay(12) end
function onPlQueue12() plQueue(12) end
function onPlDel12() plDel(12) end
function onResPlay13() resPlay(13) end
function onResQueue13() resQueue(13) end
function onResFav13() resFav(13) end
function onQPlay13() qPlay(13) end
function onQDel13() qDel(13) end
function onFavPlay13() favPlay(13) end
function onFavQueue13() favQueue(13) end
function onFavDel13() favDel(13) end
function onPlPlay13() plPlay(13) end
function onPlQueue13() plQueue(13) end
function onPlDel13() plDel(13) end
function onResPlay14() resPlay(14) end
function onResQueue14() resQueue(14) end
function onResFav14() resFav(14) end
function onQPlay14() qPlay(14) end
function onQDel14() qDel(14) end
function onFavPlay14() favPlay(14) end
function onFavQueue14() favQueue(14) end
function onFavDel14() favDel(14) end
function onPlPlay14() plPlay(14) end
function onPlQueue14() plQueue(14) end
function onPlDel14() plDel(14) end
function onResPlay15() resPlay(15) end
function onResQueue15() resQueue(15) end
function onResFav15() resFav(15) end
function onQPlay15() qPlay(15) end
function onQDel15() qDel(15) end
function onFavPlay15() favPlay(15) end
function onFavQueue15() favQueue(15) end
function onFavDel15() favDel(15) end
function onPlPlay15() plPlay(15) end
function onPlQueue15() plQueue(15) end
function onPlDel15() plDel(15) end
function onResPlay16() resPlay(16) end
function onResQueue16() resQueue(16) end
function onResFav16() resFav(16) end
function onQPlay16() qPlay(16) end
function onQDel16() qDel(16) end
function onFavPlay16() favPlay(16) end
function onFavQueue16() favQueue(16) end
function onFavDel16() favDel(16) end
function onPlPlay16() plPlay(16) end
function onPlQueue16() plQueue(16) end
function onPlDel16() plDel(16) end
function onResPlay17() resPlay(17) end
function onResQueue17() resQueue(17) end
function onResFav17() resFav(17) end
function onQPlay17() qPlay(17) end
function onQDel17() qDel(17) end
function onFavPlay17() favPlay(17) end
function onFavQueue17() favQueue(17) end
function onFavDel17() favDel(17) end
function onPlPlay17() plPlay(17) end
function onPlQueue17() plQueue(17) end
function onPlDel17() plDel(17) end
function onResPlay18() resPlay(18) end
function onResQueue18() resQueue(18) end
function onResFav18() resFav(18) end
function onQPlay18() qPlay(18) end
function onQDel18() qDel(18) end
function onFavPlay18() favPlay(18) end
function onFavQueue18() favQueue(18) end
function onFavDel18() favDel(18) end
function onPlPlay18() plPlay(18) end
function onPlQueue18() plQueue(18) end
function onPlDel18() plDel(18) end
function onResPlay19() resPlay(19) end
function onResQueue19() resQueue(19) end
function onResFav19() resFav(19) end
function onQPlay19() qPlay(19) end
function onQDel19() qDel(19) end
function onFavPlay19() favPlay(19) end
function onFavQueue19() favQueue(19) end
function onFavDel19() favDel(19) end
function onPlPlay19() plPlay(19) end
function onPlQueue19() plQueue(19) end
function onPlDel19() plDel(19) end
function onResPlay20() resPlay(20) end
function onResQueue20() resQueue(20) end
function onResFav20() resFav(20) end
function onQPlay20() qPlay(20) end
function onQDel20() qDel(20) end
function onFavPlay20() favPlay(20) end
function onFavQueue20() favQueue(20) end
function onFavDel20() favDel(20) end
function onPlPlay20() plPlay(20) end
function onPlQueue20() plQueue(20) end
function onPlDel20() plDel(20) end
function onResPlay21() resPlay(21) end
function onResQueue21() resQueue(21) end
function onResFav21() resFav(21) end
function onQPlay21() qPlay(21) end
function onQDel21() qDel(21) end
function onFavPlay21() favPlay(21) end
function onFavQueue21() favQueue(21) end
function onFavDel21() favDel(21) end
function onPlPlay21() plPlay(21) end
function onPlQueue21() plQueue(21) end
function onPlDel21() plDel(21) end
function onResPlay22() resPlay(22) end
function onResQueue22() resQueue(22) end
function onResFav22() resFav(22) end
function onQPlay22() qPlay(22) end
function onQDel22() qDel(22) end
function onFavPlay22() favPlay(22) end
function onFavQueue22() favQueue(22) end
function onFavDel22() favDel(22) end
function onPlPlay22() plPlay(22) end
function onPlQueue22() plQueue(22) end
function onPlDel22() plDel(22) end
function onResPlay23() resPlay(23) end
function onResQueue23() resQueue(23) end
function onResFav23() resFav(23) end
function onQPlay23() qPlay(23) end
function onQDel23() qDel(23) end
function onFavPlay23() favPlay(23) end
function onFavQueue23() favQueue(23) end
function onFavDel23() favDel(23) end
function onPlPlay23() plPlay(23) end
function onPlQueue23() plQueue(23) end
function onPlDel23() plDel(23) end
function onResPlay24() resPlay(24) end
function onResQueue24() resQueue(24) end
function onResFav24() resFav(24) end
function onQPlay24() qPlay(24) end
function onQDel24() qDel(24) end
function onFavPlay24() favPlay(24) end
function onFavQueue24() favQueue(24) end
function onFavDel24() favDel(24) end
function onPlPlay24() plPlay(24) end
function onPlQueue24() plQueue(24) end
function onPlDel24() plDel(24) end
function onResPlay25() resPlay(25) end
function onResQueue25() resQueue(25) end
function onResFav25() resFav(25) end
function onQPlay25() qPlay(25) end
function onQDel25() qDel(25) end
function onFavPlay25() favPlay(25) end
function onFavQueue25() favQueue(25) end
function onFavDel25() favDel(25) end
function onPlPlay25() plPlay(25) end
function onPlQueue25() plQueue(25) end
function onPlDel25() plDel(25) end
function onResPlay26() resPlay(26) end
function onResQueue26() resQueue(26) end
function onResFav26() resFav(26) end
function onQPlay26() qPlay(26) end
function onQDel26() qDel(26) end
function onFavPlay26() favPlay(26) end
function onFavQueue26() favQueue(26) end
function onFavDel26() favDel(26) end
function onPlPlay26() plPlay(26) end
function onPlQueue26() plQueue(26) end
function onPlDel26() plDel(26) end
function onResPlay27() resPlay(27) end
function onResQueue27() resQueue(27) end
function onResFav27() resFav(27) end
function onQPlay27() qPlay(27) end
function onQDel27() qDel(27) end
function onFavPlay27() favPlay(27) end
function onFavQueue27() favQueue(27) end
function onFavDel27() favDel(27) end
function onPlPlay27() plPlay(27) end
function onPlQueue27() plQueue(27) end
function onPlDel27() plDel(27) end
function onResPlay28() resPlay(28) end
function onResQueue28() resQueue(28) end
function onResFav28() resFav(28) end
function onQPlay28() qPlay(28) end
function onQDel28() qDel(28) end
function onFavPlay28() favPlay(28) end
function onFavQueue28() favQueue(28) end
function onFavDel28() favDel(28) end
function onPlPlay28() plPlay(28) end
function onPlQueue28() plQueue(28) end
function onPlDel28() plDel(28) end
function onResPlay29() resPlay(29) end
function onResQueue29() resQueue(29) end
function onResFav29() resFav(29) end
function onQPlay29() qPlay(29) end
function onQDel29() qDel(29) end
function onFavPlay29() favPlay(29) end
function onFavQueue29() favQueue(29) end
function onFavDel29() favDel(29) end
function onPlPlay29() plPlay(29) end
function onPlQueue29() plQueue(29) end
function onPlDel29() plDel(29) end
function onResPlay30() resPlay(30) end
function onResQueue30() resQueue(30) end
function onResFav30() resFav(30) end
function onQPlay30() qPlay(30) end
function onQDel30() qDel(30) end
function onFavPlay30() favPlay(30) end
function onFavQueue30() favQueue(30) end
function onFavDel30() favDel(30) end
function onPlPlay30() plPlay(30) end
function onPlQueue30() plQueue(30) end
function onPlDel30() plDel(30) end
function onResPlay31() resPlay(31) end
function onResQueue31() resQueue(31) end
function onResFav31() resFav(31) end
function onQPlay31() qPlay(31) end
function onQDel31() qDel(31) end
function onFavPlay31() favPlay(31) end
function onFavQueue31() favQueue(31) end
function onFavDel31() favDel(31) end
function onPlPlay31() plPlay(31) end
function onPlQueue31() plQueue(31) end
function onPlDel31() plDel(31) end
function onResPlay32() resPlay(32) end
function onResQueue32() resQueue(32) end
function onResFav32() resFav(32) end
function onQPlay32() qPlay(32) end
function onQDel32() qDel(32) end
function onFavPlay32() favPlay(32) end
function onFavQueue32() favQueue(32) end
function onFavDel32() favDel(32) end
function onPlPlay32() plPlay(32) end
function onPlQueue32() plQueue(32) end
function onPlDel32() plDel(32) end
function onResPlay33() resPlay(33) end
function onResQueue33() resQueue(33) end
function onResFav33() resFav(33) end
function onQPlay33() qPlay(33) end
function onQDel33() qDel(33) end
function onFavPlay33() favPlay(33) end
function onFavQueue33() favQueue(33) end
function onFavDel33() favDel(33) end
function onPlPlay33() plPlay(33) end
function onPlQueue33() plQueue(33) end
function onPlDel33() plDel(33) end
function onResPlay34() resPlay(34) end
function onResQueue34() resQueue(34) end
function onResFav34() resFav(34) end
function onQPlay34() qPlay(34) end
function onQDel34() qDel(34) end
function onFavPlay34() favPlay(34) end
function onFavQueue34() favQueue(34) end
function onFavDel34() favDel(34) end
function onPlPlay34() plPlay(34) end
function onPlQueue34() plQueue(34) end
function onPlDel34() plDel(34) end
function onResPlay35() resPlay(35) end
function onResQueue35() resQueue(35) end
function onResFav35() resFav(35) end
function onQPlay35() qPlay(35) end
function onQDel35() qDel(35) end
function onFavPlay35() favPlay(35) end
function onFavQueue35() favQueue(35) end
function onFavDel35() favDel(35) end
function onPlPlay35() plPlay(35) end
function onPlQueue35() plQueue(35) end
function onPlDel35() plDel(35) end
function onResPlay36() resPlay(36) end
function onResQueue36() resQueue(36) end
function onResFav36() resFav(36) end
function onQPlay36() qPlay(36) end
function onQDel36() qDel(36) end
function onFavPlay36() favPlay(36) end
function onFavQueue36() favQueue(36) end
function onFavDel36() favDel(36) end
function onPlPlay36() plPlay(36) end
function onPlQueue36() plQueue(36) end
function onPlDel36() plDel(36) end
function onResPlay37() resPlay(37) end
function onResQueue37() resQueue(37) end
function onResFav37() resFav(37) end
function onQPlay37() qPlay(37) end
function onQDel37() qDel(37) end
function onFavPlay37() favPlay(37) end
function onFavQueue37() favQueue(37) end
function onFavDel37() favDel(37) end
function onPlPlay37() plPlay(37) end
function onPlQueue37() plQueue(37) end
function onPlDel37() plDel(37) end
function onResPlay38() resPlay(38) end
function onResQueue38() resQueue(38) end
function onResFav38() resFav(38) end
function onQPlay38() qPlay(38) end
function onQDel38() qDel(38) end
function onFavPlay38() favPlay(38) end
function onFavQueue38() favQueue(38) end
function onFavDel38() favDel(38) end
function onPlPlay38() plPlay(38) end
function onPlQueue38() plQueue(38) end
function onPlDel38() plDel(38) end
function onResPlay39() resPlay(39) end
function onResQueue39() resQueue(39) end
function onResFav39() resFav(39) end
function onQPlay39() qPlay(39) end
function onQDel39() qDel(39) end
function onFavPlay39() favPlay(39) end
function onFavQueue39() favQueue(39) end
function onFavDel39() favDel(39) end
function onPlPlay39() plPlay(39) end
function onPlQueue39() plQueue(39) end
function onPlDel39() plDel(39) end
function onResPlay40() resPlay(40) end
function onResQueue40() resQueue(40) end
function onResFav40() resFav(40) end
function onQPlay40() qPlay(40) end
function onQDel40() qDel(40) end
function onFavPlay40() favPlay(40) end
function onFavQueue40() favQueue(40) end
function onFavDel40() favDel(40) end
function onPlPlay40() plPlay(40) end
function onPlQueue40() plQueue(40) end
function onPlDel40() plDel(40) end
