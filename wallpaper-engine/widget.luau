-- =============================================================================
--  widget.luau — bar widget + SUPERVISOR for Wallpaper Engine
--  This widget is the engine room. Every second it:
--    1) auto-pauses/resumes each monitor's wallpaper via SIGSTOP/SIGCONT
--       based on the pause mode (a stopped process renders nothing and uses
--       ~zero CPU/GPU) — decided per monitor from hyprctl state
--    2) applies the manual pause flag set from the panel
--    3) respawns saved wallpapers whose process is gone (login / crash),
--       when autorestore is on
--  It publishes live per-monitor status to /tmp/noctalia-wpe-runtime.json for
--  the panel. Click toggles the panel; right-click toggles manual pause.
--
--  Pause modes (plugin setting "pause_mode"):
--    windows    — pause while ANY window is open on the monitor's active
--                 workspace (default; covers "paused when focused on a window"
--                 and stays paused while the wallpaper is covered)
--    focus      — pause only the monitor holding the focused window
--    fullscreen — pause only when the active workspace has a fullscreen window
--    never      — no auto-pause
-- =============================================================================

local DATA_DIR     = noctalia.expandPath("~/.config/noctalia-wpe")
local STATE_FILE   = DATA_DIR .. "/state.json"
local RUNTIME_FILE = "/tmp/noctalia-wpe-runtime.json"

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
    fps       = tonumber(getCfg("fps")) or 30,
    mute      = getCfg("mute_audio") ~= false,
    volume    = tonumber(getCfg("volume")) or 50,
    scaling   = tostring(getCfg("scaling") or "default"),
    extra     = noctalia.string.trim(tostring(getCfg("extra_args") or "")),
    pauseMode = tostring(getCfg("pause_mode") or "windows"),
    restore   = getCfg("autorestore") ~= false,
  }
end

-- ---------- supervisor state ----------
local ticking     = false
local missing     = {}   -- monitor -> consecutive ticks its wallpaper was absent
local lastRuntime = ""   -- last runtime JSON written (write only on change)
local lastManual  = ""   -- mirrored for the right-click toggle

-- ---------- process helpers (same conventions as panel.luau) ----------
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

-- "PID cmdline" lines from pgrep -af -> { [monitor] = { pid, id } }
local function parseRunning(out)
  local running = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local pid = line:match("^(%d+)")
    local mon = line:match("%-%-screen%-root (%S+)")
    local bg  = line:match("%-%-bg (%S+)")
    if pid and mon then running[mon] = { pid = pid, id = bg or "" } end
  end
  return running
end

-- decide per-monitor pause from hyprctl JSON (see pause modes above)
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
      else -- "windows" (default)
        paused[m.name] = ((ws and tonumber(ws.windows)) or 0) > 0
      end
    end
  end
  return paused
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
    lastManual = manual
    local c = cfg()

    -- 2) what's actually running
    noctalia.runAsync("pgrep -af linux-wallpaperengine 2>/dev/null", function(pres)
      local running = parseRunning(pres.stdout)

      -- 3) restore dead wallpapers (after 2 consecutive missing ticks, so we
      --    never race the panel while it is respawning one itself)
      local respawn = ""
      if c.restore and noctalia.commandExists("linux-wallpaperengine") then
        for mon, a in pairs(desired) do
          local want = (type(a) == "table") and tostring(a.id or "") or ""
          if want ~= "" then
            if running[mon] and running[mon].id == want then
              missing[mon] = 0
            else
              missing[mon] = (missing[mon] or 0) + 1
              if missing[mon] >= 2 then
                missing[mon] = 0
                respawn = respawn .. "pkill -f " .. sq(killPattern(mon)) .. " 2>/dev/null; "
                  .. launchCmd(mon, want) .. " "
              end
            end
          end
        end
      end
      if respawn ~= "" then noctalia.runAsync(respawn, nil) end

      -- 4) pause / resume
      local function applySignals(pausedSet)
        local sig = ""
        for mon, r in pairs(running) do
          sig = sig .. "kill -" .. (pausedSet[mon] and "STOP" or "CONT") .. " " .. r.pid .. " 2>/dev/null; "
        end
        if sig ~= "" then noctalia.runAsync(sig, nil) end
        writeRuntime(running, pausedSet, desired)
        setBar(running, pausedSet, manual)
        ticking = false
      end

      if manual == "paused" then
        local allPaused = {}
        for mon in pairs(running) do allPaused[mon] = true end
        applySignals(allPaused)
        return
      end
      if c.pauseMode == "never" or not noctalia.commandExists("hyprctl") then
        applySignals({})
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
          applySignals(decidePaused(c.pauseMode, dec(parts[1]), dec(parts[2]), dec(parts[3])))
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
