-- =============================================================================
--  widget.luau — bar widget + SUPERVISOR for Wallpaper Engine
--  This widget is the engine room. Every second it:
--    1) auto-pauses/resumes wallpapers via SIGSTOP/SIGCONT based on the pause
--       mode (a stopped process renders nothing and uses ~zero CPU/GPU),
--       decided from hyprctl state
--    2) applies the manual pause flag set from the panel
--    3) respawns saved wallpapers whose process is gone (login / crash),
--       when autorestore is on
--  It publishes live per-monitor status to /tmp/noctalia-wpe-runtime.json for
--  the panel. Click toggles the panel; right-click toggles manual pause.
--
--  Process modes (plugin setting "process_mode"):
--    single (default) — ONE process drives all monitors, so pausing is
--      all-or-nothing. Aggregation per pause mode: "windows" pauses only when
--      EVERY monitor's wallpaper is covered; "focus"/"fullscreen" pause when
--      ANY monitor triggers. (Implemented generically: monitors sharing a pid
--      are aggregated, so per-monitor processes still pause independently.)
--    per-monitor — one process per monitor, fully independent pause.
--
--  Pause modes (plugin setting "pause_mode"):
--    fullscreen — a monitor triggers while its workspace has a fullscreen app
--                 (default: with transparent/blurred windows the wallpaper
--                 stays visible, so keep it animating until truly hidden)
--    windows    — a monitor triggers while ANY window is open on its active
--                 workspace (max GPU savings; wallpaper freezes while working)
--    focus      — a monitor triggers while it holds the focused window
--    never      — no auto-pause
-- =============================================================================

local DATA_DIR     = noctalia.expandPath("~/.config/noctalia-wpe")
local STATE_FILE   = DATA_DIR .. "/state.json"
local RUNTIME_FILE = "/tmp/noctalia-wpe-runtime.json"
local LOG_FILE     = DATA_DIR .. "/wpe.log"   -- engine stdout/stderr

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

-- live settings overrides from state.json ("settings", written by the panel);
-- refreshed every tick before cfg() is consulted — panel values win
local ov = {}

-- does the engine build support --bg? (probed by the panel, persisted in
-- state.json "engine"; default to modern syntax until told otherwise)
local engBg = true

local function ovBool(key, fallback)
  local v = ov[key]
  if type(v) == "boolean" then return v end
  return fallback
end

local function cfg()
  return {
    fps       = tonumber(ov.fps) or tonumber(getCfg("fps")) or 30,
    mute      = ovBool("mute", getCfg("mute_audio") ~= false),
    volume    = tonumber(ov.volume) or tonumber(getCfg("volume")) or 50,
    scaling   = tostring(ov.scaling or getCfg("scaling") or "default"),
    extra     = noctalia.string.trim(tostring(getCfg("extra_args") or "")),
    pauseMode = tostring(ov.pause_mode or getCfg("pause_mode") or "fullscreen"),
    procMode  = tostring(getCfg("process_mode") or "single"),
    restore   = getCfg("autorestore") ~= false,
  }
end

-- ---------- supervisor state ----------
local ticking     = false
local missing     = {}   -- per-monitor mode: monitor -> consecutive absent ticks
local missTicks   = 0    -- single mode: consecutive unhealthy ticks
local lastRuntime = ""   -- last runtime JSON written (write only on change)

-- ---------- process helpers (same conventions as panel.luau) ----------
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

local function launchCmd(mon, wpId)
  local cmd = "setsid linux-wallpaperengine --screen-root " .. sq(mon)
  if engBg then
    cmd = cmd .. " --bg " .. sq(wpId) .. commonFlags()
  else
    cmd = cmd .. commonFlags() .. " " .. sq(wpId)   -- legacy: positional id last
  end
  return cmd .. " >> " .. sq(LOG_FILE) .. " 2>&1 &"
end

local function singleLaunchCmd(list)
  if #list == 0 then return "true" end
  local cmd = "setsid linux-wallpaperengine"
  for _, a in ipairs(list) do
    cmd = cmd .. " --screen-root " .. sq(a.mon) .. " --bg " .. sq(a.id)
  end
  return cmd .. commonFlags() .. " >> " .. sq(LOG_FILE) .. " 2>&1 &"
end

local function killPattern(mon)
  return "linux-wallpaperengine.*--screen-root " .. mon .. " "
end

-- "PID cmdline" lines from pgrep -af -> { [monitor] = { pid, id } }.
-- A single process may carry several --screen-root/--bg pairs; every monitor
-- it drives maps to the same pid.
local function parseRunning(out)
  local running = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local pid = line:match("^(%d+)")
    if pid and line:find("linux%-wallpaperengine") then
      for mon, bg in line:gmatch("%-%-screen%-root (%S+) %-%-bg (%S+)") do
        running[mon] = { pid = pid, id = bg }
      end
      -- legacy form: no --bg pair, wallpaper id is the last positional arg
      for mon in line:gmatch("%-%-screen%-root (%S+)") do
        if not running[mon] then
          local tailId = line:match("%s(%S+)%s*$")
          if tailId and (tailId:sub(1, 1) == "-" or tailId == mon) then tailId = nil end
          running[mon] = { pid = pid, id = tailId or "" }
        end
      end
    end
  end
  return running
end

-- per-monitor trigger decisions from hyprctl JSON (see pause modes above)
local function decidePaused(mode, mons, wss, aw)
  local paused = {}
  local wsById = {}
  for _, w in ipairs(wss or {}) do
    if type(w) == "table" and w.id then wsById[w.id] = w end
  end
  local monNameById = {}
  for _, m in ipairs(mons or {}) do
    if type(m) == "table" and m.name then monNameById[m.id] = m.name end
  end
  for _, m in ipairs(mons or {}) do
    if type(m) == "table" and m.name then
      local ws = (type(m.activeWorkspace) == "table") and wsById[m.activeWorkspace.id] or nil
      if mode == "focus" then
        paused[m.name] = type(aw) == "table" and aw.address ~= nil
          and monNameById[aw.monitor] == m.name
      elseif mode == "fullscreen" then
        paused[m.name] = (ws ~= nil) and (ws.hasfullscreen == true)
      elseif mode == "never" then
        paused[m.name] = false
      else -- "windows"
        paused[m.name] = ((ws and tonumber(ws.windows)) or 0) > 0
      end
    end
  end
  return paused
end

-- Should the process driving `group` (list of monitor names) pause?
-- windows: only when EVERY monitor it drives is covered (the wallpaper is
-- visible nowhere). focus/fullscreen: when ANY of them triggers.
local function groupPause(mode, group, pausedSet)
  if mode == "windows" then
    for _, mon in ipairs(group) do
      if not pausedSet[mon] then return false end
    end
    return #group > 0
  end
  for _, mon in ipairs(group) do
    if pausedSet[mon] then return true end
  end
  return false
end

-- Respawn command for dead/missing wallpapers ("" when everything is fine).
-- Debounced by 2 ticks so we never race the panel while it is respawning.
-- `presentMons` (from hyprctl) filters out unplugged monitors — a stale
-- --screen-root would make the whole (shared) launch fail.
local function restoreCmds(c, desired, running, presentMons)
  if not c.restore or not noctalia.commandExists("linux-wallpaperengine") then return "" end
  local present = nil
  if presentMons then
    present = {}
    for _, m in ipairs(presentMons) do
      if type(m) == "table" and m.name then present[m.name] = true end
    end
  end

  local names, wanted = {}, {}
  for mon, a in pairs(desired) do
    local id = (type(a) == "table") and tostring(a.id or "") or ""
    if id ~= "" and (present == nil or present[mon]) then
      names[#names + 1] = mon
      wanted[mon] = id
    end
  end
  table.sort(names)
  if #names == 0 then
    missing = {}
    missTicks = 0
    return ""
  end

  if c.procMode == "per-monitor" or not engBg then
    local cmds = ""
    for _, mon in ipairs(names) do
      if running[mon] and running[mon].id == wanted[mon] then
        missing[mon] = 0
      else
        missing[mon] = (missing[mon] or 0) + 1
        if missing[mon] >= 2 then
          missing[mon] = 0
          cmds = cmds .. "pkill -f " .. sq(killPattern(mon)) .. " 2>/dev/null; "
            .. launchCmd(mon, wanted[mon]) .. " "
        end
      end
    end
    return cmds
  end

  -- single mode: healthy only if every wanted monitor runs the right id
  for _, mon in ipairs(names) do
    if not (running[mon] and running[mon].id == wanted[mon]) then
      missTicks = missTicks + 1
      if missTicks < 2 then return "" end
      missTicks = 0
      local list = {}
      for _, m in ipairs(names) do list[#list + 1] = { mon = m, id = wanted[m] } end
      return "pkill -f linux-wallpaperengine 2>/dev/null; sleep 0.3; " .. singleLaunchCmd(list)
    end
  end
  missTicks = 0
  return ""
end

-- publish live status for the panel (only when it changed)
local function writeRuntime(running, pausedSet, desired)
  local rt = {}
  for mon, r in pairs(running) do
    local a = type(desired) == "table" and desired[mon] or nil
    rt[mon] = {
      id = r.id,
      title = (type(a) == "table" and a.title) or r.id,
      paused = pausedSet[mon] == true,
    }
  end
  local json = noctalia.json.encode(rt)
  if json == lastRuntime then return end
  lastRuntime = json
  noctalia.runAsync("printf '%s' " .. sq(json) .. " > " .. sq(RUNTIME_FILE), nil)
end

local function setBar(running, pausedSet, manual)
  barWidget.setGlyph("photo")
  local total, pausedN = 0, 0
  local lines = {}
  for mon, r in pairs(running) do
    total = total + 1
    if pausedSet[mon] then pausedN = pausedN + 1 end
    lines[#lines + 1] = mon .. " · " .. r.id .. (pausedSet[mon] and " · paused" or " · playing")
  end
  table.sort(lines)
  if manual == "paused" then
    barWidget.setText("⏸")
    barWidget.setTooltip("Wallpaper Engine — manually paused (right-click to resume)\n" .. table.concat(lines, "\n"))
  elseif total == 0 then
    barWidget.setText("")
    barWidget.setTooltip("Wallpaper Engine — nothing running")
  else
    barWidget.setText(pausedN == total and "⏸" or "")
    barWidget.setTooltip("Wallpaper Engine\n" .. table.concat(lines, "\n"))
  end
end

-- ---------- the supervisor tick ----------
function update()
  noctalia.setUpdateInterval(1000)
  if ticking then return end
  ticking = true

  -- 1) desired state
  noctalia.runAsync("cat " .. sq(STATE_FILE) .. " 2>/dev/null", function(res)
    local ok, st = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if not ok or type(st) ~= "table" then st = {} end
    local desired = type(st.monitors) == "table" and st.monitors or {}
    local manual = tostring(st.manual or "")
    ov = type(st.settings) == "table" and st.settings or {}
    local eng = type(st.engine) == "table" and st.engine or {}
    engBg = (eng.bg ~= false)
    local c = cfg()

    -- 2) what's actually running
    noctalia.runAsync("pgrep -af linux-wallpaperengine 2>/dev/null", function(pres)
      local running = parseRunning(pres.stdout)

      local function finish(mons, wss, aw)
        -- 3) restore dead wallpapers
        local respawn = restoreCmds(c, desired, running, mons)
        if respawn ~= "" then noctalia.runAsync(respawn, nil) end

        -- 4) pause / resume: per-monitor triggers, aggregated per pid group
        local pausedSet = {}
        if manual ~= "paused" and mons and c.pauseMode ~= "never" then
          pausedSet = decidePaused(c.pauseMode, mons, wss, aw)
        end
        local monsByPid = {}
        for mon, r in pairs(running) do
          monsByPid[r.pid] = monsByPid[r.pid] or {}
          table.insert(monsByPid[r.pid], mon)
        end
        local finalPause = {}
        local sig = ""
        for pid, group in pairs(monsByPid) do
          local pause = (manual == "paused") or groupPause(c.pauseMode, group, pausedSet)
          for _, mon in ipairs(group) do finalPause[mon] = pause end
          sig = sig .. "kill -" .. (pause and "STOP" or "CONT") .. " " .. pid .. " 2>/dev/null; "
        end
        if sig ~= "" then noctalia.runAsync(sig, nil) end

        writeRuntime(running, finalPause, desired)
        setBar(running, finalPause, manual)
        ticking = false
      end

      if not noctalia.commandExists("hyprctl") then
        finish(nil, nil, nil)
        return
      end
      noctalia.runAsync(
        "hyprctl monitors -j 2>/dev/null; echo '@@@'; hyprctl workspaces -j 2>/dev/null; echo '@@@'; hyprctl activewindow -j 2>/dev/null",
        function(hres)
          local parts = {}
          for chunk in (tostring(hres.stdout or "") .. "@@@"):gmatch("(.-)@@@") do
            parts[#parts + 1] = chunk
          end
          local function dec(s)
            local ok2, v = pcall(function() return noctalia.json.decode(s or "") end)
            return ok2 and v or nil
          end
          finish(dec(parts[1]), dec(parts[2]), dec(parts[3]))
        end)
    end)
  end)
end

function onClick()
  noctalia.togglePanel("yordle/wallpaper-engine:panel")
end

-- right-click: toggle manual pause (persisted so it survives the next tick)
function onRightClick()
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; cat " .. sq(STATE_FILE) .. " 2>/dev/null", function(res)
    local ok, st = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if not ok or type(st) ~= "table" then st = {} end
    st.monitors = type(st.monitors) == "table" and st.monitors or {}
    st.manual = (tostring(st.manual or "") == "paused") and "" or "paused"
    local json = noctalia.json.encode(st)
    local sig = (st.manual == "paused")
      and "pkill -STOP -f linux-wallpaperengine 2>/dev/null"
      or "pkill -CONT -f linux-wallpaperengine 2>/dev/null"
    noctalia.runAsync("printf '%s' " .. sq(json) .. " > " .. sq(STATE_FILE) .. "; " .. sig, nil)
  end)
end
