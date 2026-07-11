-- =============================================================================
--  panel.luau — Wallpaper Engine  v0.3.0
--  Frontend for linux-wallpaperengine. Two-pane layout:
--    LEFT  — paginated wallpaper list (no scrolling/searching required;
--            filter box optional) with thumbnails
--    RIGHT — selected wallpaper: big preview, monitor target chips, Apply,
--            playback settings (FPS / audio / scaling / pause mode) editable
--            live, manual pause controls, per-monitor status
--
--  Settings changed here are saved as overrides in state.json ("settings")
--  and win over the plugin's Settings → Plugins values; the widget reads
--  them every tick. FPS/audio/scaling need a wallpaper restart to apply
--  (the "Restart to apply" button); pause mode applies live.
--
--  Division of labour is unchanged from v0.2: the panel owns user actions
--  and (re)spawns/kills the linux-wallpaperengine process(es); the BAR
--  WIDGET is the supervisor (auto-pause via SIGSTOP/SIGCONT, manual pause
--  flag, respawn on login/crash). Without the widget on a bar, auto-pause
--  and restore do not run.
--
--  No ui.scroll anywhere: pagination keeps the list a fixed size (multiple
--  scroll regions break input focus; zero is even safer). Per-row buttons
--  dispatch through rowAct() via a fixed pool of literal global handlers
--  (onRowSelN) — _G is read-only in this sandbox, so the pool MUST stay
--  declared literally; see the end of this file.
-- =============================================================================

local DATA_DIR     = noctalia.expandPath("~/.config/noctalia-wpe")
local STATE_FILE   = DATA_DIR .. "/state.json"
local RUNTIME_FILE = "/tmp/noctalia-wpe-runtime.json"   -- written by the widget
local PAGE         = 10   -- wallpapers per page (= row handler pool size)
local MON_POOL     = 8    -- monitor chip handler pool

local SCALINGS = { "default", "stretch", "fit", "fill" }
local PMODES   = { "fullscreen", "windows", "focus", "never" }

-- ---------- shell quoting ----------
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- view state ----------
local state = {
  monitors   = {},    -- { {name} } from hyprctl monitors -j (max MON_POOL)
  target     = "all", -- "all" or a monitor name
  wallpapers = {},    -- { {id, title, preview} } sorted by title
  rows       = {},    -- wallpaper ids of the current page rows (rowAct target)
  sel        = nil,   -- selected wallpaper id (shown in the right pane)
  page       = 1,
  filter     = "",
  assigned   = {},    -- monitor name -> { id, title }  (persisted desired state)
  manual     = "",    -- "" = auto pause | "paused" = force-paused
  ov         = {},    -- playback settings overrides (persisted in state.json)
  runtime    = {},    -- monitor name -> { id, paused } (live, from the widget)
  rtRaw      = "",
  busy       = false,
  status     = "",
}

-- forward declaration
local render

-- ---------- config (panel overrides win over plugin settings) ----------
local function getCfg(key)
  local ok, v = pcall(function() return noctalia.getConfig(key) end)
  if ok then return v end
  return nil
end

local function ovBool(key, fallback)
  local v = state.ov[key]
  if type(v) == "boolean" then return v end
  return fallback
end

local function cfg()
  return {
    dir      = noctalia.expandPath(getCfg("workshop_dir") or "~/.local/share/Steam/steamapps/workshop/content/431960"),
    fps      = tonumber(state.ov.fps) or tonumber(getCfg("fps")) or 30,
    mute     = ovBool("mute", getCfg("mute_audio") ~= false),
    volume   = tonumber(state.ov.volume) or tonumber(getCfg("volume")) or 50,
    scaling  = tostring(state.ov.scaling or getCfg("scaling") or "default"),
    pmode    = tostring(state.ov.pause_mode or getCfg("pause_mode") or "fullscreen"),
    extra    = noctalia.string.trim(tostring(getCfg("extra_args") or "")),
    procMode = tostring(getCfg("process_mode") or "single"),
  }
end

-- ---------- persistence ----------
local function loadState(cb)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; cat " .. sq(STATE_FILE) .. " 2>/dev/null", function(res)
    local ok, st = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if ok and type(st) == "table" then
      state.assigned = type(st.monitors) == "table" and st.monitors or {}
      state.manual = tostring(st.manual or "")
      state.ov = type(st.settings) == "table" and st.settings or {}
    end
    if cb then cb() end
  end)
end

local function saveState()
  local json = noctalia.json.encode({ monitors = state.assigned, manual = state.manual, settings = state.ov })
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(STATE_FILE), nil)
end

-- ---------- monitors / wallpapers ----------
local function loadMonitors(cb)
  if not noctalia.commandExists("hyprctl") then
    state.monitors = {}
    if cb then cb() end
    return
  end
  noctalia.runAsync("hyprctl monitors -j 2>/dev/null", function(res)
    local ok, mons = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    state.monitors = {}
    if ok and type(mons) == "table" then
      for _, m in ipairs(mons) do
        if type(m) == "table" and m.name then
          state.monitors[#state.monitors + 1] = { name = tostring(m.name) }
          if #state.monitors >= MON_POOL then break end
        end
      end
    end
    if cb then cb() end
  end)
end

-- Scan the workshop dir: one line per wallpaper, "<id>\t<project.json flattened>"
local function scanWallpapers()
  local c = cfg()
  state.busy = true
  render()
  local cmd = "for d in " .. sq(c.dir) .. "/*/; do"
    .. " [ -f \"$d/project.json\" ] || continue;"
    .. " printf '%s\\t' \"$(basename \"$d\")\";"
    .. " tr -d '\\n\\r\\t' < \"$d/project.json\";"
    .. " printf '\\n';"
    .. " done 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    local wps = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local id, json = line:match("^([^\t]+)\t(.*)$")
      if id then
        local ok, proj = pcall(function() return noctalia.json.decode(json) end)
        local title = (ok and type(proj) == "table" and proj.title) or id
        local preview = nil
        if ok and type(proj) == "table" and type(proj.preview) == "string" and proj.preview ~= "" then
          preview = c.dir .. "/" .. id .. "/" .. proj.preview
        end
        wps[#wps + 1] = { id = id, title = tostring(title), preview = preview }
      end
    end
    table.sort(wps, function(a, b) return a.title:lower() < b.title:lower() end)
    state.wallpapers = wps
    state.busy = false
    if #wps == 0 then
      state.status = "No wallpapers found in " .. c.dir
    elseif state.sel == nil then
      state.sel = wps[1].id
    end
    render()
  end)
end

local function selectedWp()
  for _, wp in ipairs(state.wallpapers) do
    if wp.id == state.sel then return wp end
  end
  return nil
end

local function monitorsUsing(wpId)
  local mons = {}
  for name, a in pairs(state.assigned) do
    if type(a) == "table" and a.id == wpId then mons[#mons + 1] = name end
  end
  table.sort(mons)
  return mons
end

-- ---------- process control ----------
-- The cmdline always carries "--screen-root <MON> --bg <ID>" pairs so the
-- widget can find each monitor's assignment and signal the process.
local function commonFlags()
  local c = cfg()
  local f = " --fps " .. tostring(c.fps)
  if c.mute then
    f = f .. " --silent"
  else
    f = f .. " --volume " .. tostring(c.volume)
  end
  if c.scaling ~= "" and c.scaling ~= "default" then
    f = f .. " --scaling " .. sq(c.scaling)
  end
  if c.extra ~= "" then f = f .. " " .. c.extra end
  return f
end

-- per-monitor mode: one process for one monitor
local function launchCmd(mon, wpId)
  return "setsid linux-wallpaperengine --screen-root " .. sq(mon) .. " --bg " .. sq(wpId)
    .. commonFlags() .. " >/dev/null 2>&1 &"
end

-- single mode: one process carrying every assignment ({ {mon, id}, ... })
local function singleLaunchCmd(list)
  if #list == 0 then return "true" end
  local cmd = "setsid linux-wallpaperengine"
  for _, a in ipairs(list) do
    cmd = cmd .. " --screen-root " .. sq(a.mon) .. " --bg " .. sq(a.id)
  end
  return cmd .. commonFlags() .. " >/dev/null 2>&1 &"
end

local function killPattern(mon)
  return "linux-wallpaperengine.*--screen-root " .. mon .. " "
end

-- every assignment on a currently-present monitor (a stale name from an
-- unplugged monitor would kill the whole shared launch)
local function currentAssignedList()
  local list = {}
  for _, m in ipairs(state.monitors) do
    local a = state.assigned[m.name]
    if type(a) == "table" and a.id then
      list[#list + 1] = { mon = m.name, id = tostring(a.id) }
    end
  end
  return list
end

local function relaunchAllCmd()
  local c = cfg()
  local list = currentAssignedList()
  if #list == 0 then return nil end
  if c.procMode == "per-monitor" then
    local spawns = ""
    for _, a in ipairs(list) do spawns = spawns .. launchCmd(a.mon, a.id) .. " " end
    return "pkill -f linux-wallpaperengine 2>/dev/null; sleep 0.3; " .. spawns
  end
  return "pkill -f linux-wallpaperengine 2>/dev/null; sleep 0.3; " .. singleLaunchCmd(list)
end

local function targetMonitors()
  if state.target ~= "all" then return { state.target } end
  local mons = {}
  for _, m in ipairs(state.monitors) do mons[#mons + 1] = m.name end
  return mons
end

local function applyWallpaper(wp, mons)
  if not noctalia.commandExists("linux-wallpaperengine") then
    state.status = "linux-wallpaperengine not found on PATH"
    render()
    return
  end
  if #mons == 0 then
    state.status = "No monitors found (is hyprctl available?)"
    render()
    return
  end
  for _, mon in ipairs(mons) do
    state.assigned[mon] = { id = wp.id, title = wp.title }
  end
  saveState()
  state.status = "Applying " .. wp.title .. "…"
  render()
  local cmd = relaunchAllCmd() or "true"
  noctalia.runAsync(cmd, function()
    state.status = wp.title .. " → " .. table.concat(mons, ", ")
    render()
  end)
end

-- ---------- runtime (live status from the widget) ----------
local function readRuntime()
  noctalia.runAsync("cat " .. sq(RUNTIME_FILE) .. " 2>/dev/null", function(res)
    local raw = res.stdout or ""
    if raw == state.rtRaw then return end
    state.rtRaw = raw
    local ok, rt = pcall(function() return noctalia.json.decode(raw) end)
    state.runtime = (ok and type(rt) == "table") and rt or {}
    render()
  end)
end

-- =====================================================================
--  RENDER
-- =====================================================================

local function emptyNote(text)
  return ui.label({ text = text, fontSize = 13, color = "on_surface_variant", paddingV = 8 })
end

local function thumb(wp, size, radius)
  if wp and wp.preview then
    return ui.image({ path = wp.preview, width = size, height = size, radius = radius, fit = "cover" })
  end
  return ui.column({ width = size, height = size, align = "center", justify = "center", fill = "surface_variant", radius = radius }, {
    ui.glyph({ name = "photo", size = math.floor(size / 2.2), color = "on_surface_variant" }),
  })
end

-- one list row: [thumb] [title / where it's used] [select]
local function listRow(i, wp)
  local isSel = (wp.id == state.sel)
  local mons = monitorsUsing(wp.id)
  return ui.row({ gap = 8, align = "center", key = "wp-" .. i }, {
    thumb(wp, 36, 5),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = wp.title, fontSize = 13, color = isSel and "primary" or "on_surface", maxLines = 1 }),
      ui.label({
        text = (#mons > 0) and ("on " .. table.concat(mons, ", ")) or wp.id,
        fontSize = 10, color = "on_surface_variant", maxLines = 1,
      }),
    }),
    ui.button({ glyph = "chevron-right", variant = isSel and "primary" or "ghost", onClick = "onRowSel" .. i }),
  })
end

local function filteredList()
  local list = {}
  for _, wp in ipairs(state.wallpapers) do
    if state.filter == ""
      or wp.title:lower():find(state.filter, 1, true)
      or wp.id:find(state.filter, 1, true) then
      list[#list + 1] = wp
    end
  end
  return list
end

local function leftPane()
  local kids = {
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "filter", placeholder = "Filter… (optional)", flexGrow = 1, fontSize = 13, onSubmit = "onFilter" }),
    }),
  }

  local list = filteredList()
  local totalPages = math.max(1, math.ceil(#list / PAGE))
  if state.page > totalPages then state.page = totalPages end
  if state.page < 1 then state.page = 1 end

  state.rows = {}
  if state.busy then
    kids[#kids + 1] = ui.row({ gap = 8, align = "center", paddingV = 8 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Scanning workshop…", fontSize = 13, color = "on_surface_variant" }),
    })
  elseif #list == 0 then
    kids[#kids + 1] = emptyNote(#state.wallpapers == 0
      and "No wallpapers. Subscribe in Steam Workshop (Wallpaper Engine), or fix the workshop directory in settings."
      or ("Nothing matches \"" .. state.filter .. "\"."))
  else
    local first = (state.page - 1) * PAGE
    for i = 1, PAGE do
      local wp = list[first + i]
      if not wp then break end
      state.rows[i] = wp.id
      kids[#kids + 1] = listRow(i, wp)
    end
  end

  kids[#kids + 1] = ui.column({ flexGrow = 1 }, {})   -- push pagination down
  kids[#kids + 1] = ui.row({ gap = 6, align = "center", justify = "space_between" }, {
    ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onPrevPage" }),
    ui.label({
      text = "Page " .. state.page .. " / " .. totalPages .. "  ·  " .. #list .. " wallpapers",
      fontSize = 11, color = "on_surface_variant",
    }),
    ui.button({ glyph = "chevron-right", variant = "ghost", onClick = "onNextPage" }),
  })
  return ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, kids)
end

local function settingRow(label, controls)
  local kids = {
    ui.label({ text = label, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
  }
  for _, c in ipairs(controls) do kids[#kids + 1] = c end
  return ui.row({ gap = 4, align = "center" }, kids)
end

local function rightPane()
  local c = cfg()
  local kids = {}
  local wp = selectedWp()

  -- selected wallpaper: preview + info + target + apply
  if not wp then
    kids[#kids + 1] = emptyNote("Select a wallpaper on the left.")
  else
    if wp.preview then
      kids[#kids + 1] = ui.image({ path = wp.preview, width = 300, height = 168, radius = 8, fit = "cover" })
    else
      kids[#kids + 1] = ui.column({ width = 300, height = 168, align = "center", justify = "center", fill = "surface_variant", radius = 8 }, {
        ui.glyph({ name = "photo", size = 40, color = "on_surface_variant" }),
      })
    end
    kids[#kids + 1] = ui.label({ text = wp.title, fontSize = 14, fontWeight = "bold", color = "on_surface", maxLines = 2 })
    local mons = monitorsUsing(wp.id)
    kids[#kids + 1] = ui.label({
      text = wp.id .. ((#mons > 0) and ("  ·  on " .. table.concat(mons, ", ")) or ""),
      fontSize = 10, color = "on_surface_variant", maxLines = 1,
    })

    local chips = {
      ui.button({ text = "All", variant = state.target == "all" and "primary" or "ghost", onClick = "onMon0" }),
    }
    for i, m in ipairs(state.monitors) do
      chips[#chips + 1] = ui.button({
        text = m.name,
        variant = state.target == m.name and "primary" or "ghost",
        onClick = "onMon" .. i,
      })
    end
    kids[#kids + 1] = ui.row({ gap = 4, align = "center" }, chips)
    kids[#kids + 1] = ui.button({
      text = "Apply to " .. (state.target == "all" and "all monitors" or state.target),
      glyph = "check", variant = "primary", onClick = "onApply",
    })
  end

  -- playback settings (overrides saved to state.json; widget follows)
  kids[#kids + 1] = ui.separator({ spacing = 4 })
  kids[#kids + 1] = ui.label({ text = "Playback settings", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" })
  kids[#kids + 1] = settingRow("FPS", {
    ui.button({ glyph = "minus", variant = "ghost", onClick = "onFpsDown" }),
    ui.label({ text = tostring(c.fps), fontSize = 12, color = "on_surface" }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onFpsUp" }),
  })
  kids[#kids + 1] = settingRow("Audio", {
    ui.button({ glyph = c.mute and "volume-off" or "volume", variant = c.mute and "primary" or "ghost", onClick = "onMuteToggle" }),
    ui.button({ glyph = "minus", variant = "ghost", onClick = "onVolDown" }),
    ui.label({ text = tostring(c.volume) .. "%", fontSize = 12, color = c.mute and "on_surface_variant" or "on_surface" }),
    ui.button({ glyph = "plus", variant = "ghost", onClick = "onVolUp" }),
  })
  kids[#kids + 1] = settingRow("Scaling", {
    ui.button({ text = c.scaling, variant = "outline", onClick = "onScaleCycle" }),
  })
  kids[#kids + 1] = settingRow("Auto-pause", {
    ui.button({ text = c.pmode, variant = "outline", onClick = "onPModeCycle" }),
  })
  kids[#kids + 1] = ui.row({ gap = 6, align = "center" }, {
    ui.button({ text = "Restart to apply", glyph = "refresh", variant = "ghost", onClick = "onRestart", flexGrow = 1 }),
  })
  kids[#kids + 1] = ui.label({
    text = "FPS · audio · scaling apply on restart — pause mode applies live",
    fontSize = 9, color = "on_surface_variant",
  })

  -- manual controls + live status
  kids[#kids + 1] = ui.separator({ spacing = 4 })
  kids[#kids + 1] = ui.row({ gap = 4, align = "center" }, {
    ui.button({ text = "Auto", glyph = "player-play", variant = state.manual == "" and "primary" or "ghost", onClick = "onResume" }),
    ui.button({ text = "Pause", glyph = "player-pause", variant = state.manual == "paused" and "primary" or "ghost", onClick = "onPause" }),
    ui.button({ text = "Stop all", glyph = "player-stop", variant = "ghost", onClick = "onStopAll" }),
  })
  if #state.monitors == 0 then
    kids[#kids + 1] = ui.label({ text = "No monitors — hyprctl not found or returned nothing.", fontSize = 11, color = "on_surface_variant" })
  else
    for _, m in ipairs(state.monitors) do
      local a = state.assigned[m.name]
      local rt = state.runtime[m.name]
      local txt = m.name .. " → " .. ((type(a) == "table" and a.title) or "none")
      if type(a) == "table" and type(rt) == "table" then
        txt = txt .. (rt.paused and "  ⏸ paused" or "  ▶ playing")
      end
      kids[#kids + 1] = ui.label({ text = txt, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
    end
  end

  return ui.column({ gap = 6, width = 320, align = "stretch" }, kids)
end

function render()
  local kids = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Wallpaper Engine", fontSize = 15, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRescan" }),
        ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
      }),
    }),
    ui.row({ flexGrow = 1, gap = 12, align = "stretch" }, {
      leftPane(),
      ui.separator({ orientation = "vertical", spacing = 2 }),
      rightPane(),
    }),
  }
  if state.status ~= "" then
    kids[#kids + 1] = ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
  end
  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, kids))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen()
  panel.setWantsSecondTicks(true)
  state.status = ""
  loadState(function()
    loadMonitors(function() render() end)
  end)
  scanWallpapers()
  readRuntime()
end

local tick = 0
function update()
  tick = tick + 1
  if tick % 2 == 0 then readRuntime() end
end

function onClose() panel.close() end
function onRescan() loadMonitors(function() render() end); scanWallpapers() end
function onFilter(text)
  state.filter = noctalia.string.trim(text or ""):lower()
  state.page = 1
  render()
end
function onPrevPage() if state.page > 1 then state.page = state.page - 1; render() end end
function onNextPage() state.page = state.page + 1; render() end   -- clamped in leftPane

function onApply()
  local wp = selectedWp()
  if wp then applyWallpaper(wp, targetMonitors()) end
end

-- restart current assignments so FPS/audio/scaling changes take effect
function onRestart()
  local cmd = relaunchAllCmd()
  if not cmd then
    state.status = "Nothing to restart"
    render()
    return
  end
  state.status = "Restarting wallpapers…"
  render()
  noctalia.runAsync(cmd, function()
    state.status = "Restarted with current settings"
    render()
  end)
end

-- playback settings (persisted immediately; process restart applies them)
local function cycleNext(list, cur)
  for i, v in ipairs(list) do
    if v == cur then return list[(i % #list) + 1] end
  end
  return list[1]
end

function onFpsUp() state.ov.fps = math.min(240, cfg().fps + 5); saveState(); render() end
function onFpsDown() state.ov.fps = math.max(5, cfg().fps - 5); saveState(); render() end
function onVolUp() state.ov.volume = math.min(100, cfg().volume + 10); saveState(); render() end
function onVolDown() state.ov.volume = math.max(0, cfg().volume - 10); saveState(); render() end
function onMuteToggle() state.ov.mute = not cfg().mute; saveState(); render() end
function onScaleCycle() state.ov.scaling = cycleNext(SCALINGS, cfg().scaling); saveState(); render() end
function onPModeCycle() state.ov.pause_mode = cycleNext(PMODES, cfg().pmode); saveState(); render() end

-- manual pause: the flag is persisted for the widget, plus we signal
-- immediately so the effect is instant rather than waiting a tick
function onPause()
  state.manual = "paused"
  saveState()
  noctalia.runAsync("pkill -STOP -f linux-wallpaperengine 2>/dev/null", nil)
  state.status = "Paused (manual — click Auto to hand control back)"
  render()
end

function onResume()
  state.manual = ""
  saveState()
  noctalia.runAsync("pkill -CONT -f linux-wallpaperengine 2>/dev/null", nil)
  state.status = "Auto pause active"
  render()
end

function onStopAll()
  state.assigned = {}
  state.manual = ""
  saveState()
  noctalia.runAsync("pkill -f linux-wallpaperengine 2>/dev/null", function()
    state.status = "Stopped all wallpapers"
    render()
  end)
end

-- monitor chips (literal pool — _G is read-only)
function onMon0() state.target = "all"; render() end
function onMon1() local m = state.monitors[1]; if m then state.target = m.name; render() end end
function onMon2() local m = state.monitors[2]; if m then state.target = m.name; render() end end
function onMon3() local m = state.monitors[3]; if m then state.target = m.name; render() end end
function onMon4() local m = state.monitors[4]; if m then state.target = m.name; render() end end
function onMon5() local m = state.monitors[5]; if m then state.target = m.name; render() end end
function onMon6() local m = state.monitors[6]; if m then state.target = m.name; render() end end
function onMon7() local m = state.monitors[7]; if m then state.target = m.name; render() end end
function onMon8() local m = state.monitors[8]; if m then state.target = m.name; render() end end

-- ---------------------------------------------------------------------
--  Per-row dispatch: select the row's wallpaper (shown in the right pane).
--  Literal pool (PAGE rows) — _G is read-only, keep in sync with PAGE.
-- ---------------------------------------------------------------------
local function rowAct(i)
  if state.rows[i] then
    state.sel = state.rows[i]
    render()
  end
end

function onRowSel1() rowAct(1) end
function onRowSel2() rowAct(2) end
function onRowSel3() rowAct(3) end
function onRowSel4() rowAct(4) end
function onRowSel5() rowAct(5) end
function onRowSel6() rowAct(6) end
function onRowSel7() rowAct(7) end
function onRowSel8() rowAct(8) end
function onRowSel9() rowAct(9) end
function onRowSel10() rowAct(10) end
