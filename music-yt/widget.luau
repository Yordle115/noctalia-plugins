-- =============================================================================
--  widget.luau — bar widget for Music (YTM + Local)
--  Click: toggle the panel. Display: now-playing glyph + optional title.
-- =============================================================================

local function cfg()
  return {
    host = noctalia.getConfig("mpc_host") or "127.0.0.1",
    port = tostring(noctalia.getConfig("mpc_port") or 6600),
  }
end

local function mpc(args)
  local c = cfg()
  return string.format("mpc -h %s -p %s %s", c.host, c.port, args)
end

local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local showTitle = barWidget.getConfig("show_title")
local maxLen    = barWidget.getConfig("max_title_len") or 28

local lastState = "stop"

local function truncate(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

function update()
  noctalia.setUpdateInterval(2000)  -- poll now-playing every 2s

  noctalia.runAsync(mpc("-f " .. sq("%title%\\t%artist%") .. " current"), function(res)
    local line = (res.stdout or ""):gsub("\n$", "")
    local title, artist = line:match("^(.-)\t(.*)$")

    noctalia.runAsync(mpc("status"), function(r2)
      local s = r2.stdout or ""
      local playing = s:match("%[playing%]") ~= nil
      local paused  = s:match("%[paused%]") ~= nil

      if playing then
        barWidget.setGlyph("player-play")
        lastState = "play"
      elseif paused then
        barWidget.setGlyph("player-pause")
        lastState = "pause"
      else
        barWidget.setGlyph("music")
        lastState = "stop"
      end

      if showTitle and title and title ~= "" and lastState ~= "stop" then
        local label = title
        if artist and artist ~= "" then label = title .. " · " .. artist end
        barWidget.setText(truncate(label, maxLen))
        barWidget.setTooltip(label)
      else
        barWidget.setText("")
        if lastState == "stop" then
          barWidget.setTooltip("Music — nothing playing")
        end
      end
    end)
  end)
end

function onClick()
  noctalia.togglePanel("yordle/music-yt:panel")
end

-- Right-click: play/pause toggle as a quick action
function onRightClick()
  if lastState == "play" then
    noctalia.runAsync(mpc("pause"))
  else
    noctalia.runAsync(mpc("play"))
  end
end

-- Middle-click: skip
function onMiddleClick()
  noctalia.runAsync(mpc("next"))
end
