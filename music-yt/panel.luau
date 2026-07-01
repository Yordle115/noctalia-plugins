-- =============================================================================
--  panel.luau — Music (YouTube + Local) GUI panel
--  Native yt-dlp + mpv backend. No Mopidy, no MPD.
--    search   : yt-dlp --flat-playlist --dump-single-json ytsearch15:<query>
--    play     : mpv --no-video --ytdl-format=bestaudio/best --input-ipc-server=<sock>
--    control  : JSON commands piped to the mpv IPC socket via socat
--  All JSON parsed in Luau; only external deps are yt-dlp, mpv, socat.
-- =============================================================================

local SOCKET = "/tmp/noctalia-music-mpv.sock"

-- ---------- config ----------
local function cfg()
  return {
    results   = noctalia.getConfig("search_results") or 15,
    localDir  = noctalia.expandPath(noctalia.getConfig("local_music_dir") or ""),
    localOn   = noctalia.getConfig("search_local") == true,
    ytClient  = noctalia.getConfig("yt_player_client") or "android",
  }
end

-- ---------- shell quoting ----------
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- view state ----------
local TAB_QUEUE = "queue"
local TAB_LIB   = "library"   -- reserved for phase 2 (favorites); shows queue for now

local state = {
  tab        = TAB_QUEUE,
  query      = "",
  results    = {},   -- { {id,title,url,uploader,duration,source}, ... }
  queue      = {},   -- { {title,url,uploader,duration}, ... }  (Luau-managed)
  queueIdx   = 0,    -- index of currently-playing queue item (0 = none)
  nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false },
  position   = 0,
  duration   = 0,
  busy       = false,
  status     = "",
}

-- ---------- mpv IPC (via socat) ----------
-- Send a JSON command to mpv's socket, invoke cb with the raw reply string.
local function mpvSend(jsonCmd, cb)
  local cmd = "printf '%s\\n' " .. sq(jsonCmd)
            .. " | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null | head -1"
  noctalia.runAsync(cmd, function(res)
    if cb then cb((res.stdout or ""):gsub("\n$", "")) end
  end)
end

-- Get a single mpv property (returns parsed .data via cb)
local function mpvGet(prop, cb)
  mpvSend('{"command":["get_property","' .. prop .. '"]}', function(reply)
    if reply == "" then cb(nil); return end
    local ok, parsed = pcall(function() return noctalia.json.decode(reply) end)
    if ok and parsed then cb(parsed.data) else cb(nil) end
  end)
end

-- Set an mpv property (fire-and-forget)
local function mpvSet(prop, value)
  mpvSend('{"command":["set_property","' .. prop .. '",' .. value .. ']}', nil)
end

-- ---------- playback ----------
local function socketExists(cb)
  noctalia.runAsync("test -S " .. sq(SOCKET) .. " && echo yes || echo no", function(res)
    cb((res.stdout or ""):match("yes") ~= nil)
  end)
end

-- Launch mpv on a URL. Replaces any current playback (kills old mpv via socket quit).
local function playUrl(url, title, uploader)
  if not noctalia.commandExists("mpv") then
    state.status = "mpv not found on PATH"
    render()
    return
  end
  if not noctalia.commandExists("socat") then
    state.status = "socat not found — add it to media.nix"
    render()
    return
  end
  state.status = "Loading…"
  state.nowPlaying = { title = title or url, uploader = uploader or "", url = url, playing = true, paused = false }
  render()

  local c = cfg()
  -- Tell any existing mpv to quit, then start a fresh one on the same socket.
  local quit = "printf '%s\\n' '{\"command\":[\"quit\"]}' | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null; "
  local ytdlRaw = "--ytdl-raw-options=extractor-args=youtube:player_client=" .. c.ytClient
  local mpvCmd = "setsid mpv --no-video --force-window=no --audio-display=no"
    .. " --ytdl-format=bestaudio/best --demuxer-max-bytes=256K"
    .. " --idle=once --input-ipc-server=" .. sq(SOCKET)
    .. " " .. sq(ytdlRaw)
    .. " --title=" .. sq("Noctalia Music")
    .. " " .. sq(url)
    .. " >/dev/null 2>&1 &"

  noctalia.runAsync(quit .. "sleep 0.2; rm -f " .. sq(SOCKET) .. "; " .. mpvCmd, function()
    state.status = "Playing"
    -- give mpv a moment to create the socket + start, then refresh
    noctalia.runAsync("sleep 1", function()
      refreshNowPlaying()
    end)
  end)
end

-- Play the queue item at index i
local function playQueueIndex(i)
  local item = state.queue[i]
  if not item then return end
  state.queueIdx = i
  playUrl(item.url, item.title, item.uploader)
end

-- Enqueue a track (append). If nothing playing, start it.
local function enqueue(track)
  table.insert(state.queue, track)
  state.status = "Added to queue"
  if not state.nowPlaying.playing then
    playQueueIndex(#state.queue)
  else
    render()
  end
end

-- Advance to next queue item (called when current ends)
local function playNext()
  if state.queueIdx > 0 and state.queueIdx < #state.queue then
    playQueueIndex(state.queueIdx + 1)
  else
    -- queue exhausted
    state.nowPlaying = { title = "", uploader = "", url = "", playing = false, paused = false }
    state.queueIdx = 0
    state.position = 0
    state.duration = 0
    render()
  end
end

-- ---------- now-playing refresh (polls mpv over IPC) ----------
function refreshNowPlaying()
  socketExists(function(exists)
    if not exists then
      -- no socket = mpv not running; if we thought we were playing, advance queue
      if state.nowPlaying.playing then
        playNext()
      else
        render()
      end
      return
    end
    -- socket exists; gather pause, playback-time, duration, media-title
    mpvGet("pause", function(paused)
      state.nowPlaying.paused = (paused == true)
      state.nowPlaying.playing = true
      mpvGet("playback-time", function(pt)
        state.position = tonumber(pt) or 0
        mpvGet("duration", function(dur)
          state.duration = tonumber(dur) or 0
          -- if eof reached (position at/near duration and not paused), advance
          mpvGet("eof-reached", function(eof)
            if eof == true then
              playNext()
            else
              render()
            end
          end)
        end)
      end)
    end)
  end)
end

-- ---------- transport ----------
local function togglePause()
  if state.nowPlaying.paused then
    mpvSet("pause", "false")
  else
    mpvSet("pause", "true")
  end
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

local function seekTo(seconds)
  mpvSend('{"command":["seek",' .. tostring(seconds) .. ',"absolute+exact"]}', nil)
  noctalia.runAsync("sleep 0.15", function() refreshNowPlaying() end)
end

-- ---------- search ----------
local function sourceOf(url)
  if url:match("youtube%.com") or url:match("youtu%.be") then return "YT" end
  if url:match("^/") or url:match("^file:") then return "Local" end
  return "YT"
end

local function parseSearchJson(raw)
  local out = {}
  if not raw or raw == "" then return out end
  local ok, parsed = pcall(function() return noctalia.json.decode(raw) end)
  if not ok or not parsed then return out end
  local entries = parsed.entries or {}
  for _, e in ipairs(entries) do
    local id = e.id or ""
    if id ~= "" then
      local url = e.url
      if not url or url == "" then
        url = "https://www.youtube.com/watch?v=" .. id
      end
      table.insert(out, {
        id = id,
        title = e.title or "Untitled",
        url = url,
        uploader = e.channel or e.uploader or "",
        duration = tonumber(e.duration) or 0,
        source = "YT",
      })
    end
  end
  return out
end

local function doSearch(q)
  q = q and noctalia.string.trim(q) or ""
  state.query = q
  if q == "" then
    state.results = {}
    render()
    return
  end
  if not noctalia.commandExists("yt-dlp") then
    state.status = "yt-dlp not found on PATH"
    state.results = {}
    render()
    return
  end
  state.busy = true
  render()

  local c = cfg()
  local ytCmd = "yt-dlp --ignore-config --flat-playlist --dump-single-json"
    .. " --extractor-args " .. sq("youtube:player_client=" .. c.ytClient)
    .. " " .. sq("ytsearch" .. tostring(c.results) .. ":" .. q)
    .. " 2>/dev/null"

  noctalia.runAsync(ytCmd, function(res)
    local ytResults = parseSearchJson(res.stdout)

    -- optional local search merged in
    if c.localOn and c.localDir ~= "" then
      local findCmd = "find " .. sq(c.localDir) .. " -maxdepth 4 -type f "
        .. "\\( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.opus' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' \\) "
        .. "2>/dev/null | grep -i -F " .. sq(q) .. " | head -n " .. tostring(c.results)
      noctalia.runAsync(findCmd, function(lres)
        local locals = {}
        for line in (lres.stdout or ""):gmatch("[^\n]+") do
          local fname = line:gsub("^.*/", ""):gsub("%.%w+$", "")
          table.insert(locals, {
            id = line, title = fname, url = line,
            uploader = "Local file", duration = 0, source = "Local",
          })
        end
        -- locals first, then YT
        local merged = {}
        for _, r in ipairs(locals) do table.insert(merged, r) end
        for _, r in ipairs(ytResults) do table.insert(merged, r) end
        state.results = merged
        state.busy = false
        render()
      end)
    else
      state.results = ytResults
      state.busy = false
      render()
    end
  end)
end

-- ---------- format helpers ----------
local function fmtDuration(sec)
  sec = tonumber(sec) or 0
  if sec <= 0 then return "" end
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = math.floor(sec % 60)
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

-- =====================================================================
--  RENDER
-- =====================================================================

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

  return ui.column({ gap = 6 }, {
    ui.row({ gap = 12, align = "center" }, {
      ui.box({ width = 56, height = 56, radius = 8, fill = "surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = titleText, fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
        ui.label({ text = subText, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
        (progressText ~= "" and ui.label({ text = progressText, fontSize = 10, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({ glyph = "player-skip-back", variant = "ghost", onClick = "onPrev" }),
        ui.button({ glyph = playGlyph, variant = "primary", onClick = "onPlayPause" }),
        ui.button({ glyph = "player-skip-forward", variant = "ghost", onClick = "onNext" }),
        ui.button({ glyph = "player-stop", variant = "ghost", onClick = "onStop" }),
      }),
    }),
  })
end

local function searchBox()
  return ui.input({
    key = "search-input",
    value = "",
    placeholder = "Search YouTube…",
    fontSize = 14,
    onSubmit = "onSearchSubmit",
  })
end

local function sourceBadge(src)
  local color = src == "YT" and "primary" or "secondary"
  return ui.label({ text = src, fontSize = 10, fontWeight = "bold", color = color })
end

local function resultRow(r, idx)
  local dur = fmtDuration(r.duration)
  return ui.row({ gap = 8, align = "center", key = "res-" .. idx }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = r.title, fontSize = 13, color = "on_surface", maxLines = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        sourceBadge(r.source),
        ui.label({ text = r.uploader, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
        (dur ~= "" and ui.label({ text = dur, fontSize = 10, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
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
    return ui.spacer({ height = 0 })
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

local function queueRow(item, idx)
  local isCurrent = (idx == state.queueIdx)
  return ui.row({ gap = 8, align = "center", key = "q-" .. idx }, {
    (isCurrent
      and ui.glyph({ name = "volume", size = 14, color = "primary" })
      or ui.label({ text = tostring(idx), fontSize = 11, color = "on_surface_variant", width = 20 })),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = item.title, fontSize = 13,
                 color = isCurrent and "primary" or "on_surface", maxLines = 1 }),
      ui.label({ text = item.uploader, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({ glyph = "player-play", variant = "ghost", onClick = "onQPlay" .. idx }),
    ui.button({ glyph = "x", variant = "ghost", onClick = "onQDel" .. idx }),
  })
end

local function queueView()
  if #state.queue == 0 then
    return ui.label({ text = "Queue is empty. Search and add tracks.", fontSize = 13, color = "on_surface_variant", paddingV = 8 })
  end
  local children = {}
  for i, item in ipairs(state.queue) do
    table.insert(children, queueRow(item, i))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = #state.queue .. " in queue", fontSize = 11, color = "on_surface_variant" }),
      ui.button({ text = "Clear", glyph = "trash", variant = "ghost", onClick = "onQueueClear" }),
    }),
    ui.scroll({ gap = 2, flexGrow = 1 }, children),
  })
end

function render()
  panel.render(ui.column({ gap = 12, padding = 14 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Music", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
    }),
    nowPlayingHeader(),
    ui.separator({ spacing = 2 }),
    searchBox(),
    resultsList(),
    ui.separator({ spacing = 2 }),
    queueView(),
    (state.status ~= "" and ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" }) or ui.spacer({ height = 0 })),
  }))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen(context)
  state.status = ""
  refreshNowPlaying()
  if context and noctalia.string.trim(context) ~= "" then
    doSearch(context)
  else
    render()
  end
end

function onClose() panel.close() end

function onSearchSubmit(text) doSearch(text) end

function onPlayPause()
  if not state.nowPlaying.playing then
    -- nothing loaded: start queue from top if it exists
    if #state.queue > 0 then playQueueIndex(1) end
    return
  end
  togglePause()
end

function onPrev()
  if state.queueIdx > 1 then playQueueIndex(state.queueIdx - 1) end
end

function onNext()
  if state.queueIdx > 0 and state.queueIdx < #state.queue then
    playQueueIndex(state.queueIdx + 1)
  end
end

function onStop() stopPlayback() end

function onQueueClear()
  state.queue = {}
  state.queueIdx = 0
  render()
end

-- Per-row handlers: fixed pool of literal-named globals (host resolves by name)
local POOL = 80
for i = 1, POOL do
  _G["onResPlay" .. i] = function()
    local r = state.results[i]
    if r then
      -- play now: clear queue context, play this, set as a 1-item context
      table.insert(state.queue, { title = r.title, url = r.url, uploader = r.uploader, duration = r.duration })
      playQueueIndex(#state.queue)
    end
  end
  _G["onResQueue" .. i] = function()
    local r = state.results[i]
    if r then enqueue({ title = r.title, url = r.url, uploader = r.uploader, duration = r.duration }) end
  end
  _G["onQPlay" .. i] = function() playQueueIndex(i) end
  _G["onQDel" .. i] = function()
    if state.queue[i] then
      table.remove(state.queue, i)
      if i == state.queueIdx then
        state.queueIdx = 0
      elseif i < state.queueIdx then
        state.queueIdx = state.queueIdx - 1
      end
      render()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Watch for requests published by the launcher entry (/music-yt). Runs at the
-- top level (per Noctalia docs: register watchers here). When the launcher
-- publishes a play/queue request, handle it with the panel's live mpv state.
-- ---------------------------------------------------------------------------
local lastNonce = nil
noctalia.state.watch("launcher_request", function(req)
  if type(req) ~= "table" then return end
  if req.nonce and req.nonce == lastNonce then return end
  lastNonce = req.nonce
  local track = { title = req.title or req.url, url = req.url, uploader = "", duration = 0 }
  if req.action == "play" then
    table.insert(state.queue, track)
    playQueueIndex(#state.queue)
  elseif req.action == "queue" then
    enqueue(track)
  end
end)
