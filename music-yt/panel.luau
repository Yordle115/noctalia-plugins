-- =============================================================================
--  panel.luau — Music (YTM + Local) GUI panel
--  Now-playing header + search box + Queue / Playlists tabs.
--  Drives Mopidy through `mpc` against its MPD frontend.
-- =============================================================================

-- ---------- config (read once at load, re-read on open) ----------
local function cfg()
  return {
    host  = noctalia.getConfig("mpc_host") or "127.0.0.1",
    port  = tostring(noctalia.getConfig("mpc_port") or 6600),
    limit = noctalia.getConfig("search_limit") or 8,
    cache = noctalia.expandPath(noctalia.getConfig("art_cache") or "~/.cache/noctalia-music-yt"),
  }
end

-- ---------- mpc command builder ----------
-- Returns a shell string: `mpc -h HOST -p PORT <args>`
local function mpc(args)
  local c = cfg()
  return string.format("mpc -h %s -p %s %s", c.host, c.port, args)
end

-- shell-quote a single argument safely (single quotes, escape embedded ')
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- view state ----------
local TAB_QUEUE     = "queue"
local TAB_PLAYLISTS = "playlists"

local state = {
  tab        = TAB_QUEUE,
  query      = "",
  results    = {},   -- { {uri, title, artist, source}, ... }
  queue      = {},   -- { {pos, title, artist, playing}, ... }
  playlists  = {},   -- { name, ... }
  nowPlaying = { title = "", artist = "", state = "stop", file = "" },
  artPath    = nil,  -- local cached thumbnail path for now-playing
  busy       = false,
  status     = "",   -- transient status line
}

-- ---------- parsing helpers ----------
-- mpc search output with our format: URI \t TITLE \t ARTIST
-- We request a custom format so parsing is deterministic.
local FMT = "%file%\\t%title%\\t%artist%"

local function sourceOf(uri)
  if uri:match("^ytmusic:") or uri:match("^yt:") then return "YTM" end
  if uri:match("^local:") or uri:match("^file:") then return "Local" end
  -- mopidy ytmusic uris can look like 'ytmusic:track:...'
  if uri:match("ytmusic") then return "YTM" end
  return "Local"
end

local function parseRows(stdout)
  local rows = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local uri, title, artist = line:match("^(.-)\t(.-)\t(.*)$")
    if uri and uri ~= "" then
      if title == "" then title = uri:gsub("^.*/", "") end
      table.insert(rows, {
        uri = uri,
        title = title,
        artist = artist or "",
        source = sourceOf(uri),
      })
    end
  end
  return rows
end

-- ---------- album art ----------
-- mpc can dump embedded/remote art as binary. We can't capture binary safely
-- through text stdout, so we have mpc write it straight to a cache file via a
-- shell redirect, then point ui.image at that path. `readpicture` covers
-- embedded art; `albumart` covers separate art files — try readpicture first,
-- fall back to albumart.
local function refreshArt(file)
  if not file or file == "" then state.artPath = nil; render(); return end
  local c = cfg()
  -- ensure cache dir
  noctalia.runAsync("mkdir -p " .. sq(c.cache), function()
    -- sweep old stamped art (keep dir from growing unbounded)
    noctalia.runAsync("find " .. sq(c.cache) .. " -name 'now_*.art' -mmin +5 -delete 2>/dev/null")
    local dest = c.cache .. "/now.art"
    -- readpicture writes raw bytes to stdout; redirect to file. If empty,
    -- try albumart. We pick a stable filename so ui.image can load it.
    local cmd = mpc("readpicture " .. sq(file)) .. " > " .. sq(dest)
              .. " 2>/dev/null; "
              .. "if [ ! -s " .. sq(dest) .. " ]; then "
              .. mpc("albumart " .. sq(file)) .. " > " .. sq(dest) .. " 2>/dev/null; fi; "
              -- detect type and rename to an extension ui.image accepts
              .. "if [ -s " .. sq(dest) .. " ]; then "
              .. "echo ok; else echo none; fi"
    noctalia.runAsync(cmd, function(res)
      if (res.stdout or ""):match("ok") then
        -- ui.image loads by path regardless of extension content; use as-is.
        -- Add a cache-busting copy so the diff sees a changed path when song
        -- changes (same filename would be treated as unchanged).
        local stamp = c.cache .. "/now_" .. tostring(os.time()) .. ".art"
        noctalia.runAsync("cp -f " .. sq(dest) .. " " .. sq(stamp), function()
          state.artPath = stamp
          render()
        end)
      else
        state.artPath = nil
        render()
      end
    end)
  end)
end

-- ---------- now-playing refresh ----------
local function refreshNowPlaying()
  -- `mpc -f` current with status; we parse two calls cheaply via one status fetch
  noctalia.runAsync(mpc("-f " .. sq("%title%\\t%artist%\\t%file%") .. " current"), function(res)
    local line = (res.stdout or ""):gsub("\n$", "")
    local title, artist, file = line:match("^(.-)\t(.-)\t(.*)$")
    state.nowPlaying.title  = title or ""
    state.nowPlaying.artist = artist or ""
    state.nowPlaying.file   = file or ""
    refreshArt(file)
    -- playback state
    noctalia.runAsync(mpc("status"), function(r2)
      local s = r2.stdout or ""
      if s:match("%[playing%]") then state.nowPlaying.state = "play"
      elseif s:match("%[paused%]") then state.nowPlaying.state = "pause"
      else state.nowPlaying.state = "stop" end
      render()
    end)
  end)
end

-- ---------- queue refresh ----------
local function refreshQueue()
  noctalia.runAsync(mpc("-f " .. sq("%position%\\t%title%\\t%artist%") .. " playlist"), function(res)
    local q = {}
    -- find current position to mark the playing row
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local pos, title, artist = line:match("^(%d+)\t(.-)\t(.*)$")
      if pos then
        table.insert(q, { pos = tonumber(pos), title = title, artist = artist or "" })
      end
    end
    state.queue = q
    if state.tab == TAB_QUEUE then render() end
  end)
end

-- ---------- playlists refresh ----------
local function refreshPlaylists()
  noctalia.runAsync(mpc("lsplaylists"), function(res)
    local pls = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local name = noctalia.string.trim(line)
      if name ~= "" then table.insert(pls, name) end
    end
    state.playlists = pls
    if state.tab == TAB_PLAYLISTS then render() end
  end)
end

-- ---------- search ----------
local function doSearch(q)
  state.query = q
  if q == nil or noctalia.string.trim(q) == "" then
    state.results = {}
    render()
    return
  end
  state.busy = true
  render()
  -- search across title + artist; mopidy federates YTM + local backends.
  -- `mpc search any <q>` then format. We cap with head via a second pipe.
  local c = cfg()
  local cmd = mpc("-f " .. sq(FMT) .. " search any " .. sq(q))
            .. " | head -n " .. tostring(c.limit * 2)
  noctalia.runAsync(cmd, function(res)
    state.busy = false
    state.results = parseRows(res.stdout)
    render()
  end)
end

-- ---------- actions ----------
-- play a uri NOW: clear, add, play  (replace queue & play)
local function playNow(uri)
  state.status = "Playing…"
  render()
  local seq = mpc("clear") .. " && " .. mpc("add " .. sq(uri)) .. " && " .. mpc("play")
  noctalia.runAsync(seq, function()
    refreshNowPlaying(); refreshQueue()
  end)
end

-- queue a uri at the end (don't interrupt)
local function queueUri(uri)
  state.status = "Added to queue"
  render()
  noctalia.runAsync(mpc("add " .. sq(uri)), function()
    refreshQueue()
    -- if nothing is playing, start it so the add is audible eventually? No —
    -- "add to queue" should not interrupt. Leave playback as-is.
  end)
end

-- transport
local function transport(cmd)
  noctalia.runAsync(mpc(cmd), function() refreshNowPlaying(); refreshQueue() end)
end

-- play a specific queue position
local function playPos(pos)
  noctalia.runAsync(mpc("play " .. tostring(pos)), function()
    refreshNowPlaying(); refreshQueue()
  end)
end

-- remove a queue position
local function removePos(pos)
  noctalia.runAsync(mpc("del " .. tostring(pos)), function() refreshQueue() end)
end

-- load a playlist (append) or replace+play
local function loadPlaylist(name, replace)
  local seq
  if replace then
    seq = mpc("clear") .. " && " .. mpc("load " .. sq(name)) .. " && " .. mpc("play")
  else
    seq = mpc("load " .. sq(name))
  end
  state.status = replace and ("Playing " .. name) or ("Queued " .. name)
  render()
  noctalia.runAsync(seq, function() refreshNowPlaying(); refreshQueue() end)
end

-- add a playlist/track from a pasted URL (ytmusic playlist or track link).
-- mopidy-ytmusic resolves ytmusic: URIs; for a raw youtube/ytm URL we hand it
-- to `mpc add` which mopidy may resolve, else we try `mpc findadd`.
local function addFromUrl(url, replace)
  url = noctalia.string.trim(url)
  if url == "" then return end
  state.status = "Resolving link…"
  render()
  local addcmd = mpc("add " .. sq(url))
  local seq = replace
    and (mpc("clear") .. " && " .. addcmd .. " && " .. mpc("play"))
    or  addcmd
  noctalia.runAsync(seq, function(res)
    if (res.exitCode or 0) ~= 0 then
      state.status = "Could not resolve link"
    else
      state.status = replace and "Playing link" or "Queued link"
    end
    refreshQueue(); refreshNowPlaying()
  end)
end

-- =====================================================================
--  RENDER
-- =====================================================================

local function stateGlyph()
  local s = state.nowPlaying.state
  if s == "play" then return "player-pause" end
  return "player-play"
end

local function nowPlayingHeader()
  local np = state.nowPlaying
  local hasTrack = (np.title ~= "" or np.file ~= "")
  local titleText = hasTrack and (np.title ~= "" and np.title or np.file) or "Nothing playing"
  local artistText = np.artist ~= "" and np.artist or (hasTrack and "—" or "")

  local thumb
  if state.artPath and noctalia.fileExists(state.artPath) then
    thumb = ui.image({ path = state.artPath, width = 64, height = 64, radius = 8, fit = "cover" })
  else
    thumb = ui.box({ width = 64, height = 64, radius = 8, fill = "surface_variant" })
  end

  return ui.row({ gap = 12, align = "center" }, {
    thumb,
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = titleText, fontSize = 15, fontWeight = "bold",
                 color = "on_surface", maxLines = 1 }),
      ui.label({ text = artistText, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({ glyph = "player-skip-back", variant = "ghost", onClick = "onPrev" }),
      ui.button({ glyph = stateGlyph(), variant = "primary", onClick = "onPlayPause" }),
      ui.button({ glyph = "player-skip-forward", variant = "ghost", onClick = "onNext" }),
    }),
  })
end

local function searchBox()
  return ui.column({ gap = 6 }, {
    ui.input({
      key = "search-input",
      value = "",
      placeholder = "Search YouTube Music + local…",
      fontSize = 14,
      onSubmit = "onSearchSubmit",
      onChange = "onSearchChange",
    }),
  })
end

local function sourceBadge(src)
  local color = src == "YTM" and "primary" or "secondary"
  return ui.label({ text = src, fontSize = 10, fontWeight = "bold", color = color })
end

local function resultRow(r, idx)
  return ui.row({ gap = 8, align = "center", key = "res-" .. idx }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = r.title, fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        sourceBadge(r.source),
        ui.label({ text = r.artist, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      }),
    }),
    ui.button({ glyph = "player-play", variant = "outline", onClick = "onResPlay" .. idx }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onResQueue" .. idx }),
  })
end

local function resultsList()
  if state.busy then
    return ui.row({ gap = 8, align = "center", paddingV = 8 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Searching…", fontSize = 13, color = "on_surface_variant" }),
    })
  end
  if #state.results == 0 then
    if state.query ~= "" then
      return ui.label({ text = "No results.", fontSize = 13, color = "on_surface_variant", paddingV = 8 })
    end
    return ui.spacer({})
  end
  local children = {}
  for i, r in ipairs(state.results) do
    table.insert(children, resultRow(r, i))
    if i < #state.results then
      table.insert(children, ui.separator({ spacing = 4 }))
    end
  end
  return ui.scroll({ gap = 2, flexGrow = 1 }, children)
end

local function tabBar()
  return ui.row({ gap = 6 }, {
    ui.button({
      text = "Queue", glyph = "list",
      variant = state.tab == TAB_QUEUE and "primary" or "ghost",
      onClick = "onTabQueue", flexGrow = 1,
    }),
    ui.button({
      text = "Playlists", glyph = "playlist",
      variant = state.tab == TAB_PLAYLISTS and "primary" or "ghost",
      onClick = "onTabPlaylists", flexGrow = 1,
    }),
  })
end

local function queueRow(item, idx)
  return ui.row({ gap = 8, align = "center", key = "q-" .. idx }, {
    ui.label({ text = tostring(item.pos + 1), fontSize = 11, color = "on_surface_variant", width = 22 }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = item.title ~= "" and item.title or "(unknown)", fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.label({ text = item.artist, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({ glyph = "player-play", variant = "ghost", onClick = "onQPlay" .. idx }),
    ui.button({ glyph = "x", variant = "ghost", onClick = "onQDel" .. idx }),
  })
end

local function queueView()
  if #state.queue == 0 then
    return ui.label({ text = "Queue is empty.", fontSize = 13, color = "on_surface_variant", paddingV = 8 })
  end
  local children = {}
  for i, item in ipairs(state.queue) do
    table.insert(children, queueRow(item, i))
  end
  return ui.scroll({ gap = 2, flexGrow = 1 }, children)
end

local function playlistRow(name, idx)
  return ui.row({ gap = 8, align = "center", key = "pl-" .. idx }, {
    ui.glyph({ name = "playlist", size = 16, color = "on_surface_variant" }),
    ui.label({ text = name, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
    ui.button({ glyph = "player-play", variant = "outline", onClick = "onPlPlay" .. idx }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onPlQueue" .. idx }),
  })
end

local function playlistsView()
  local children = {}
  -- paste-a-link row
  table.insert(children, ui.row({ gap = 6, align = "center", key = "pl-url" }, {
    ui.input({
      key = "url-input",
      value = "",
      placeholder = "Paste YTM / playlist link…",
      fontSize = 13,
      onSubmit = "onAddUrl",
      flexGrow = 1,
    }),
  }))
  table.insert(children, ui.separator({ spacing = 6 }))
  if #state.playlists == 0 then
    table.insert(children, ui.label({ text = "No saved playlists.", fontSize = 13, color = "on_surface_variant", paddingV = 6 }))
  else
    for i, name in ipairs(state.playlists) do
      table.insert(children, playlistRow(name, i))
    end
  end
  return ui.scroll({ gap = 4, flexGrow = 1 }, children)
end

local function bodyView()
  if state.tab == TAB_PLAYLISTS then return playlistsView() end
  return queueView()
end

function render()
  panel.render(ui.column({ gap = 12, padding = 14 }, {
    -- header row with title + close
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Music", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
    }),
    nowPlayingHeader(),
    ui.separator({ spacing = 2 }),
    searchBox(),
    resultsList(),
    ui.separator({ spacing = 2 }),
    tabBar(),
    bodyView(),
    -- transient status
    (state.status ~= "" and ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
  }))
end

-- =====================================================================
--  CALLBACKS  (named globals — UI references them by string)
-- =====================================================================

function onOpen(context)
  state.status = ""
  refreshNowPlaying()
  refreshQueue()
  refreshPlaylists()
  -- if opened with a context string (e.g. from launcher), prefill search
  if context and noctalia.string.trim(context) ~= "" then
    doSearch(context)
  else
    render()
  end
end

function onClose() panel.close() end

-- search
function onSearchSubmit(text) doSearch(text) end
function onSearchChange(text)
  -- live-ish: only fire on submit to avoid hammering; keep last text
  state.query = text
end

-- transport
function onPlayPause()
  if state.nowPlaying.state == "play" then transport("pause")
  else transport("play") end
end
function onPrev() transport("prev") end
function onNext() transport("next") end

-- tabs
function onTabQueue() state.tab = TAB_QUEUE; refreshQueue(); render() end
function onTabPlaylists() state.tab = TAB_PLAYLISTS; refreshPlaylists(); render() end

-- result actions use "name:idx" — Noctalia passes the whole string as the fn
-- name, so we register a dispatcher pattern via individual wrappers. Because
-- callbacks must be exact global names, we instead encode the index in the
-- name and parse it here through a metatable-free lookup shim below.

-- url
function onAddUrl(text) addFromUrl(text, false) end

-- ---------------------------------------------------------------------------
-- Per-row handlers. Callbacks must be *real, literally-named* globals so the
-- host resolves them directly (no metatable indexing assumptions). We generate
-- a fixed pool large enough for any result/queue/playlist list, each reading
-- the live item out of state by its index.
-- ---------------------------------------------------------------------------
local POOL = 80  -- max rows we'll ever render in any one list

for i = 1, POOL do
  _G["onResPlay" .. i]  = function() local r = state.results[i];   if r then playNow(r.uri) end end
  _G["onResQueue" .. i] = function() local r = state.results[i];   if r then queueUri(r.uri) end end
  _G["onPlPlay" .. i]   = function() local n = state.playlists[i]; if n then loadPlaylist(n, true) end end
  _G["onPlQueue" .. i]  = function() local n = state.playlists[i]; if n then loadPlaylist(n, false) end end
end

-- Queue handlers are keyed by the *queue position*, which equals (index-1)
-- because mpc positions are what we stored in item.pos. We index the pool by
-- the 1-based render index and look up the item to get its real position.
for i = 1, POOL do
  _G["onQPlay" .. i] = function() local it = state.queue[i]; if it then playPos(it.pos) end end
  _G["onQDel" .. i]  = function() local it = state.queue[i]; if it then removePos(it.pos) end end
end
