-- =============================================================================
--  panel.luau — Wallpaper Engine  v0.1.0
--  Frontend for linux-wallpaperengine: browse Steam Workshop wallpapers with
--  previews, assign them per monitor (or all), pause/resume, stop.
--
--  Division of labour:
--    PANEL (this file) — owns user actions. Writes the desired state to
--      ~/.config/noctalia-wpe/state.json and (re)spawns/kills the
--      linux-wallpaperengine processes: ONE PROCESS PER MONITOR, so each
--      monitor's wallpaper can be paused independently via SIGSTOP/SIGCONT.
--    BAR WIDGET (widget.luau) — the supervisor. Auto-pauses wallpapers when
--      windows are open (hyprctl), applies the manual pause flag, respawns
--      dead wallpapers on login. WITHOUT THE WIDGET on a bar, auto-pause and
--      restore-on-login do not run.
--
--  Layout: single column, ONE ui.scroll body (multiple scroll regions break
--  input focus). Per-row buttons dispatch through rowAct() via a fixed pool
--  of literal global handlers (onRowSetN) — _G is read-only in this sandbox,
--  so the pool MUST stay declared literally; see the end of this file.
-- =============================================================================

local DATA_DIR     = noctalia.expandPath("~/.config/noctalia-wpe")
local STATE_FILE   = DATA_DIR .. "/state.json"
local RUNTIME_FILE = "/tmp/noctalia-wpe-runtime.json"   -- written by the widget
local POOL         = 60   -- wallpaper rows handler pool
local MON_POOL     = 8    -- monitor chip handler pool

-- ---------- shell quoting ----------
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- config ----------
local function getCfg(key)
  local ok, v = pcall(function() return noctalia.getConfig(key) end)
  if ok then return v end
  return nil
end

local function cfg()
  return {
    dir     = noctalia.expandPath(getCfg("workshop_dir") or "~/.local/share/Steam/steamapps/workshop/content/431960"),
    fps     = tonumber(getCfg("fps")) or 30,
    mute    = getCfg("mute_audio") ~= false,
    volume  = tonumber(getCfg("volume")) or 50,
    scaling = tostring(getCfg("scaling") or "default"),
    extra   = noctalia.string.trim(tostring(getCfg("extra_args") or "")),
  }
end

-- ---------- view state ----------
local state = {
  monitors   = {},    -- { {name} } from hyprctl monitors -j (max MON_POOL)
  target     = "all", -- "all" or a monitor name
  wallpapers = {},    -- { {id, title, preview} } sorted by title
  rows       = {},    -- wallpaper ids in rendered row order (rowAct target)
  filter     = "",
  assigned   = {},    -- monitor name -> { id, title }  (persisted desired state)
  manual     = "",    -- "" = auto pause | "paused" = force-paused
  runtime    = {},    -- monitor name -> { id, paused } (live, from the widget)
  rtRaw      = "",
  busy       = false,
  status     = "",
}

-- forward declaration
local render

-- ---------- persistence ----------
local function loadState(cb)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; cat " .. sq(STATE_FILE) .. " 2>/dev/null", function(res)
    local ok, st = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if ok and type(st) == "table" then
      state.assigned = type(st.monitors) == "table" and st.monitors or {}
      state.manual = tostring(st.manual or "")
    end
    if cb then cb() end
  end)
end

local function saveState()
  local json = noctalia.json.encode({ monitors = state.assigned, manual = state.manual })
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
    end
    render()
  end)
end

-- ---------- process control ----------
-- One linux-wallpaperengine process per monitor; the cmdline carries
-- "--screen-root <MON> --bg <ID>" so the widget can find and signal each one.
local function launchCmd(mon, wpId)
  local c = cfg()
  local cmd = "setsid linux-wallpaperengine --screen-root " .. sq(mon) .. " --bg " .. sq(wpId)
    .. " --fps " .. tostring(c.fps)
  if c.mute then
    cmd = cmd .. " --silent"
  else
    cmd = cmd .. " --volume " .. tostring(c.volume)
  end
  if c.scaling ~= "" and c.scaling ~= "default" then
    cmd = cmd .. " --scaling " .. sq(c.scaling)
  end
  if c.extra ~= "" then cmd = cmd .. " " .. c.extra end
  return cmd .. " >/dev/null 2>&1 &"
end

local function killPattern(mon)
  return "linux-wallpaperengine.*--screen-root " .. mon .. " "
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
  local kills, spawns = "", ""
  for _, mon in ipairs(mons) do
    state.assigned[mon] = { id = wp.id, title = wp.title }
    kills = kills .. "pkill -f " .. sq(killPattern(mon)) .. " 2>/dev/null; "
    spawns = spawns .. launchCmd(mon, wp.id) .. " "
  end
  saveState()
  state.status = "Applying " .. wp.title .. "…"
  render()
  noctalia.runAsync(kills .. "sleep 0.3; " .. spawns, function()
    state.status = wp.title .. " → " .. table.concat(mons, ", ")
    render()
  end)
end

local function targetMonitors()
  if state.target ~= "all" then return { state.target } end
  local mons = {}
  for _, m in ipairs(state.monitors) do mons[#mons + 1] = m.name end
  return mons
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

-- one wallpaper row: [preview] [title / id · assigned monitors] [apply]
local function wpRow(i, wp)
  local mons = {}
  for name, a in pairs(state.assigned) do
    if type(a) == "table" and a.id == wp.id then mons[#mons + 1] = name end
  end
  table.sort(mons)
  local sub = wp.id
  if #mons > 0 then sub = sub .. " · on " .. table.concat(mons, ", ") end

  local kids = {}
  if wp.preview then
    kids[#kids + 1] = ui.image({ path = wp.preview, width = 48, height = 48, radius = 6, fit = "cover" })
  else
    kids[#kids + 1] = ui.column({ width = 48, height = 48, align = "center", justify = "center", fill = "surface_variant", radius = 6 }, {
      ui.glyph({ name = "photo", size = 20, color = "on_surface_variant" }),
    })
  end
  kids[#kids + 1] = ui.column({ gap = 1, flexGrow = 1 }, {
    ui.label({ text = wp.title, fontSize = 13, color = (#mons > 0) and "primary" or "on_surface", maxLines = 1 }),
    ui.label({ text = sub, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
  })
  kids[#kids + 1] = ui.button({ glyph = "check", variant = "outline", onClick = "onRowSet" .. i })
  return ui.row({ gap = 8, align = "center", key = "wp-" .. i }, kids)
end

local function wallpaperList()
  if state.busy then
    return { ui.row({ gap = 8, align = "center", paddingV = 8 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Scanning workshop…", fontSize = 13, color = "on_surface_variant" }),
    }) }
  end
  local list = {}
  for _, wp in ipairs(state.wallpapers) do
    if state.filter == ""
      or wp.title:lower():find(state.filter, 1, true)
      or wp.id:find(state.filter, 1, true) then
      list[#list + 1] = wp
    end
  end
  if #list == 0 then
    state.rows = {}
    if #state.wallpapers == 0 then
      return { emptyNote("No wallpapers. Subscribe to some in Steam Workshop (Wallpaper Engine), or fix the workshop directory in settings.") }
    end
    return { emptyNote("Nothing matches \"" .. state.filter .. "\".") }
  end
  state.rows = {}
  local kids = {}
  for _, wp in ipairs(list) do
    local i = #state.rows + 1
    if i > POOL then
      kids[#kids + 1] = ui.label({
        text = "…and " .. (#list - POOL) .. " more — narrow it with the filter",
        fontSize = 11, color = "on_surface_variant", paddingV = 4,
      })
      break
    end
    state.rows[i] = wp.id
    kids[#kids + 1] = wpRow(i, wp)
  end
  return kids
end

function render()
  local kids = {}

  -- header
  kids[#kids + 1] = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = "Wallpaper Engine", fontSize = 15, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRescan" }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
    }),
  })

  -- monitor target chips
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

  -- per-monitor status lines (live pause state comes from the widget)
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

  -- manual controls
  kids[#kids + 1] = ui.row({ gap = 4, align = "center" }, {
    ui.button({ text = "Auto", glyph = "player-play", variant = state.manual == "" and "primary" or "ghost", onClick = "onResume" }),
    ui.button({ text = "Pause", glyph = "player-pause", variant = state.manual == "paused" and "primary" or "ghost", onClick = "onPause" }),
    ui.button({ text = "Stop all", glyph = "player-stop", variant = "ghost", onClick = "onStopAll" }),
  })

  -- filter + list (the single scroll region)
  kids[#kids + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.input({ key = "filter", placeholder = "Filter wallpapers… (Enter)", flexGrow = 1, fontSize = 13, onSubmit = "onFilter" }),
  })
  kids[#kids + 1] = ui.scroll({ flexGrow = 1, gap = 4 }, { ui.column({ gap = 2 }, wallpaperList()) })

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
function onFilter(text) state.filter = noctalia.string.trim(text or ""):lower(); render() end

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
--  Per-row dispatch: apply the row's wallpaper to the selected target.
-- ---------------------------------------------------------------------
local function rowAct(i)
  local id = state.rows[i]
  if not id then return end
  for _, wp in ipairs(state.wallpapers) do
    if wp.id == id then
      applyWallpaper(wp, targetMonitors())
      return
    end
  end
end

-- ---------------------------------------------------------------------
--  Literal handler pool (POOL rows). _G is read-only in this sandbox, so
--  these cannot be generated in a loop — keep them literal and keep the
--  count in sync with POOL above.
-- ---------------------------------------------------------------------
function onRowSet1() rowAct(1) end function onRowSet2() rowAct(2) end function onRowSet3() rowAct(3) end
function onRowSet4() rowAct(4) end function onRowSet5() rowAct(5) end function onRowSet6() rowAct(6) end
function onRowSet7() rowAct(7) end function onRowSet8() rowAct(8) end function onRowSet9() rowAct(9) end
function onRowSet10() rowAct(10) end function onRowSet11() rowAct(11) end function onRowSet12() rowAct(12) end
function onRowSet13() rowAct(13) end function onRowSet14() rowAct(14) end function onRowSet15() rowAct(15) end
function onRowSet16() rowAct(16) end function onRowSet17() rowAct(17) end function onRowSet18() rowAct(18) end
function onRowSet19() rowAct(19) end function onRowSet20() rowAct(20) end function onRowSet21() rowAct(21) end
function onRowSet22() rowAct(22) end function onRowSet23() rowAct(23) end function onRowSet24() rowAct(24) end
function onRowSet25() rowAct(25) end function onRowSet26() rowAct(26) end function onRowSet27() rowAct(27) end
function onRowSet28() rowAct(28) end function onRowSet29() rowAct(29) end function onRowSet30() rowAct(30) end
function onRowSet31() rowAct(31) end function onRowSet32() rowAct(32) end function onRowSet33() rowAct(33) end
function onRowSet34() rowAct(34) end function onRowSet35() rowAct(35) end function onRowSet36() rowAct(36) end
function onRowSet37() rowAct(37) end function onRowSet38() rowAct(38) end function onRowSet39() rowAct(39) end
function onRowSet40() rowAct(40) end function onRowSet41() rowAct(41) end function onRowSet42() rowAct(42) end
function onRowSet43() rowAct(43) end function onRowSet44() rowAct(44) end function onRowSet45() rowAct(45) end
function onRowSet46() rowAct(46) end function onRowSet47() rowAct(47) end function onRowSet48() rowAct(48) end
function onRowSet49() rowAct(49) end function onRowSet50() rowAct(50) end function onRowSet51() rowAct(51) end
function onRowSet52() rowAct(52) end function onRowSet53() rowAct(53) end function onRowSet54() rowAct(54) end
function onRowSet55() rowAct(55) end function onRowSet56() rowAct(56) end function onRowSet57() rowAct(57) end
function onRowSet58() rowAct(58) end function onRowSet59() rowAct(59) end function onRowSet60() rowAct(60) end
