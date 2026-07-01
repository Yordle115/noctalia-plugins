-- =============================================================================
--  search.luau — launcher provider (/music-yt)
--  Quick YouTube search from the launcher. Each hit: a Play row and a Queue row.
--  Play/Queue talk to the SAME mpv socket + a small state file the panel reads.
-- =============================================================================

local SOCKET = "/tmp/noctalia-music-mpv.sock"

local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function cfg()
  return {
    results  = noctalia.getConfig("search_results") or 15,
    ytClient = noctalia.getConfig("yt_player_client") or "android",
  }
end

function onQuery(text)
  text = noctalia.string.trim(text or "")
  if text == "" then
    launcher.setResults("", { { id = "_hint", title = "Type to search YouTube", glyph = "music" } })
    return
  end
  launcher.setResults(text, { { id = "_loading", title = "Searching…", glyph = "loader" } })

  local c = cfg()
  local ytCmd = "yt-dlp --ignore-config --flat-playlist --dump-single-json"
    .. " --extractor-args " .. sq("youtube:player_client=" .. c.ytClient)
    .. " " .. sq("ytsearch" .. tostring(c.results) .. ":" .. text)
    .. " 2>/dev/null"

  noctalia.runAsync(ytCmd, function(res)
    local results = {}
    local ok, parsed = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if ok and parsed and parsed.entries then
      for _, e in ipairs(parsed.entries) do
        local id = e.id or ""
        if id ~= "" then
          local url = "https://www.youtube.com/watch?v=" .. id
          local title = e.title or "Untitled"
          local up = e.channel or e.uploader or ""
          table.insert(results, {
            id = "play\t" .. url .. "\t" .. title,
            title = title,
            subtitle = "▶ Play   ·   " .. up,
            glyph = "player-play",
          })
          table.insert(results, {
            id = "queue\t" .. url .. "\t" .. title,
            title = title,
            subtitle = "+ Queue   ·   " .. up,
            glyph = "plus",
          })
        end
      end
    end
    if #results == 0 then
      results = { { id = "_none", title = "No results", glyph = "mood-empty" } }
    end
    launcher.setResults(text, results)
  end)
end

function onActivate(id)
  if id:sub(1, 1) == "_" then return end
  local action, url, title = id:match("^(%a+)\t([^\t]*)\t(.*)$")
  if not action or not url then return end

  -- Publish the request to the shared plugin state channel; the panel entry
  -- watches "launcher_request" and handles play/queue with its live mpv state.
  noctalia.state.set("launcher_request", {
    action = action,
    url = url,
    title = title,
    nonce = tostring(noctalia.formatTime("%s")) .. "-" .. tostring(math.random(1, 99999)),
  })

  if action == "play" then
    noctalia.notify("Music", "Playing: " .. title)
  else
    noctalia.notify("Music", "Queued: " .. title)
  end
end
