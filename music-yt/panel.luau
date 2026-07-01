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
  starting   = false,  -- true while mpv is launching (socket not up yet) — guards update() race
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
  noctalia.log("playUrl called: " .. tostring(url))
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
  state.starting = true
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
    -- give mpv a moment to create the socket + start, then clear the guard
    noctalia.runAsync("sleep 1.5", function()
      state.starting = false
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
      -- socket gone. If mpv is still launching, don't touch the queue — just wait.
      if state.starting then
        render()
        return
      end
      -- genuinely not running; if we thought we were playing, advance queue
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
  -- enable second-boundary ticks so update() refreshes now-playing while playing
  panel.setWantsSecondTicks(true)
  if context and noctalia.string.trim(context) ~= "" then
    doSearch(context)
  else
    render()
  end
end

-- Panels tick update() on second boundaries when second-ticks are enabled.
-- We enable it once in onOpen. Only refresh now-playing when something is
-- actually playing/starting — polling while idle is pointless and re-rendering
-- on the idle path can disrupt the visible search results.
function update()
  if state.nowPlaying.playing or state.starting then
    refreshNowPlaying()
  end
end

function onClose() panel.close() end

function onSearchSubmit(text) doSearch(text) end
function onSearchChange(text) state.query = text end

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

-- ---------------------------------------------------------------------------
-- Per-row handlers. Noctalia requires onClick to name a GLOBAL function, and
-- the sandbox makes _G read-only (so no dynamic _G[...] assignment). We instead
-- declare a fixed pool of real named globals (legal at parse time), each
-- delegating to a dispatcher that reads the row by index.
-- ---------------------------------------------------------------------------
local function rowPlay(i)
  local r = state.results[i]
  if r then
    table.insert(state.queue, { title = r.title, url = r.url, uploader = r.uploader, duration = r.duration })
    playQueueIndex(#state.queue)
  end
end
local function rowQueue(i)
  local r = state.results[i]
  if r then enqueue({ title = r.title, url = r.url, uploader = r.uploader, duration = r.duration }) end
end
local function qPlay(i) playQueueIndex(i) end
local function qDel(i)
  if state.queue[i] then
    table.remove(state.queue, i)
    if i == state.queueIdx then state.queueIdx = 0
    elseif i < state.queueIdx then state.queueIdx = state.queueIdx - 1 end
    render()
  end
end

function onResPlay1() rowPlay(1) end
function onResQueue1() rowQueue(1) end
function onQPlay1() qPlay(1) end
function onQDel1() qDel(1) end
function onResPlay2() rowPlay(2) end
function onResQueue2() rowQueue(2) end
function onQPlay2() qPlay(2) end
function onQDel2() qDel(2) end
function onResPlay3() rowPlay(3) end
function onResQueue3() rowQueue(3) end
function onQPlay3() qPlay(3) end
function onQDel3() qDel(3) end
function onResPlay4() rowPlay(4) end
function onResQueue4() rowQueue(4) end
function onQPlay4() qPlay(4) end
function onQDel4() qDel(4) end
function onResPlay5() rowPlay(5) end
function onResQueue5() rowQueue(5) end
function onQPlay5() qPlay(5) end
function onQDel5() qDel(5) end
function onResPlay6() rowPlay(6) end
function onResQueue6() rowQueue(6) end
function onQPlay6() qPlay(6) end
function onQDel6() qDel(6) end
function onResPlay7() rowPlay(7) end
function onResQueue7() rowQueue(7) end
function onQPlay7() qPlay(7) end
function onQDel7() qDel(7) end
function onResPlay8() rowPlay(8) end
function onResQueue8() rowQueue(8) end
function onQPlay8() qPlay(8) end
function onQDel8() qDel(8) end
function onResPlay9() rowPlay(9) end
function onResQueue9() rowQueue(9) end
function onQPlay9() qPlay(9) end
function onQDel9() qDel(9) end
function onResPlay10() rowPlay(10) end
function onResQueue10() rowQueue(10) end
function onQPlay10() qPlay(10) end
function onQDel10() qDel(10) end
function onResPlay11() rowPlay(11) end
function onResQueue11() rowQueue(11) end
function onQPlay11() qPlay(11) end
function onQDel11() qDel(11) end
function onResPlay12() rowPlay(12) end
function onResQueue12() rowQueue(12) end
function onQPlay12() qPlay(12) end
function onQDel12() qDel(12) end
function onResPlay13() rowPlay(13) end
function onResQueue13() rowQueue(13) end
function onQPlay13() qPlay(13) end
function onQDel13() qDel(13) end
function onResPlay14() rowPlay(14) end
function onResQueue14() rowQueue(14) end
function onQPlay14() qPlay(14) end
function onQDel14() qDel(14) end
function onResPlay15() rowPlay(15) end
function onResQueue15() rowQueue(15) end
function onQPlay15() qPlay(15) end
function onQDel15() qDel(15) end
function onResPlay16() rowPlay(16) end
function onResQueue16() rowQueue(16) end
function onQPlay16() qPlay(16) end
function onQDel16() qDel(16) end
function onResPlay17() rowPlay(17) end
function onResQueue17() rowQueue(17) end
function onQPlay17() qPlay(17) end
function onQDel17() qDel(17) end
function onResPlay18() rowPlay(18) end
function onResQueue18() rowQueue(18) end
function onQPlay18() qPlay(18) end
function onQDel18() qDel(18) end
function onResPlay19() rowPlay(19) end
function onResQueue19() rowQueue(19) end
function onQPlay19() qPlay(19) end
function onQDel19() qDel(19) end
function onResPlay20() rowPlay(20) end
function onResQueue20() rowQueue(20) end
function onQPlay20() qPlay(20) end
function onQDel20() qDel(20) end
function onResPlay21() rowPlay(21) end
function onResQueue21() rowQueue(21) end
function onQPlay21() qPlay(21) end
function onQDel21() qDel(21) end
function onResPlay22() rowPlay(22) end
function onResQueue22() rowQueue(22) end
function onQPlay22() qPlay(22) end
function onQDel22() qDel(22) end
function onResPlay23() rowPlay(23) end
function onResQueue23() rowQueue(23) end
function onQPlay23() qPlay(23) end
function onQDel23() qDel(23) end
function onResPlay24() rowPlay(24) end
function onResQueue24() rowQueue(24) end
function onQPlay24() qPlay(24) end
function onQDel24() qDel(24) end
function onResPlay25() rowPlay(25) end
function onResQueue25() rowQueue(25) end
function onQPlay25() qPlay(25) end
function onQDel25() qDel(25) end
function onResPlay26() rowPlay(26) end
function onResQueue26() rowQueue(26) end
function onQPlay26() qPlay(26) end
function onQDel26() qDel(26) end
function onResPlay27() rowPlay(27) end
function onResQueue27() rowQueue(27) end
function onQPlay27() qPlay(27) end
function onQDel27() qDel(27) end
function onResPlay28() rowPlay(28) end
function onResQueue28() rowQueue(28) end
function onQPlay28() qPlay(28) end
function onQDel28() qDel(28) end
function onResPlay29() rowPlay(29) end
function onResQueue29() rowQueue(29) end
function onQPlay29() qPlay(29) end
function onQDel29() qDel(29) end
function onResPlay30() rowPlay(30) end
function onResQueue30() rowQueue(30) end
function onQPlay30() qPlay(30) end
function onQDel30() qDel(30) end
function onResPlay31() rowPlay(31) end
function onResQueue31() rowQueue(31) end
function onQPlay31() qPlay(31) end
function onQDel31() qDel(31) end
function onResPlay32() rowPlay(32) end
function onResQueue32() rowQueue(32) end
function onQPlay32() qPlay(32) end
function onQDel32() qDel(32) end
function onResPlay33() rowPlay(33) end
function onResQueue33() rowQueue(33) end
function onQPlay33() qPlay(33) end
function onQDel33() qDel(33) end
function onResPlay34() rowPlay(34) end
function onResQueue34() rowQueue(34) end
function onQPlay34() qPlay(34) end
function onQDel34() qDel(34) end
function onResPlay35() rowPlay(35) end
function onResQueue35() rowQueue(35) end
function onQPlay35() qPlay(35) end
function onQDel35() qDel(35) end
function onResPlay36() rowPlay(36) end
function onResQueue36() rowQueue(36) end
function onQPlay36() qPlay(36) end
function onQDel36() qDel(36) end
function onResPlay37() rowPlay(37) end
function onResQueue37() rowQueue(37) end
function onQPlay37() qPlay(37) end
function onQDel37() qDel(37) end
function onResPlay38() rowPlay(38) end
function onResQueue38() rowQueue(38) end
function onQPlay38() qPlay(38) end
function onQDel38() qDel(38) end
function onResPlay39() rowPlay(39) end
function onResQueue39() rowQueue(39) end
function onQPlay39() qPlay(39) end
function onQDel39() qDel(39) end
function onResPlay40() rowPlay(40) end
function onResQueue40() rowQueue(40) end
function onQPlay40() qPlay(40) end
function onQDel40() qDel(40) end

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
