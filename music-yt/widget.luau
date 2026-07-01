-- =============================================================================
--  widget.luau — bar widget for Music (YouTube + Local)
--  Click toggles the panel. Polls mpv IPC socket for now-playing state.
-- =============================================================================

local SOCKET = "/tmp/noctalia-music-mpv.sock"

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

local function mpvGet(prop, cb)
  local cmd = "printf '%s\\n' " .. sq('{"command":["get_property","' .. prop .. '"]}')
            .. " | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null | head -1"
  noctalia.runAsync(cmd, function(res)
    local reply = (res.stdout or ""):gsub("\n$", "")
    if reply == "" then cb(nil); return end
    local ok, parsed = pcall(function() return noctalia.json.decode(reply) end)
    if ok and parsed then cb(parsed.data) else cb(nil) end
  end)
end

function update()
  noctalia.setUpdateInterval(2000)

  noctalia.runAsync("test -S " .. sq(SOCKET) .. " && echo yes || echo no", function(res)
    local exists = (res.stdout or ""):match("yes") ~= nil
    if not exists then
      barWidget.setGlyph("music")
      barWidget.setText("")
      barWidget.setTooltip("Music — nothing playing")
      lastState = "stop"
      return
    end
    mpvGet("pause", function(paused)
      if paused == true then
        barWidget.setGlyph("player-pause")
        lastState = "pause"
      else
        barWidget.setGlyph("player-play")
        lastState = "play"
      end
      if showTitle then
        mpvGet("media-title", function(title)
          local t = tostring(title or "")
          if t ~= "" and t ~= "nil" then
            barWidget.setText(truncate(t, maxLen))
            barWidget.setTooltip(t)
          else
            barWidget.setText("")
          end
        end)
      else
        barWidget.setText("")
      end
    end)
  end)
end

function onClick()
  noctalia.togglePanel("yordle/music-yt:panel")
end

function onRightClick()
  local toggle = (lastState == "play") and "true" or "false"
  local cmd = "printf '%s\\n' " .. sq('{"command":["set_property","pause",' .. toggle .. ']}')
            .. " | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null"
  noctalia.runAsync(cmd)
end

function onMiddleClick()
  -- middle-click stops playback
  local cmd = "printf '%s\\n' " .. sq('{"command":["quit"]}')
            .. " | socat -t 1 - UNIX-CONNECT:" .. sq(SOCKET) .. " 2>/dev/null"
  noctalia.runAsync(cmd)
end
