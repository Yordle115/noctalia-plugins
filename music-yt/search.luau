-- =============================================================================
--  search.luau — launcher provider (/music-yt)
--  Quick search from the launcher. Each result offers Play (activate) and a
--  "+ queue" variant row. Selecting opens nothing extra — it acts immediately.
-- =============================================================================

local function cfg()
  return {
    host  = noctalia.getConfig("mpc_host") or "127.0.0.1",
    port  = tostring(noctalia.getConfig("mpc_port") or 6600),
    limit = noctalia.getConfig("search_limit") or 8,
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

local FMT = "%file%\\t%title%\\t%artist%"

local function sourceOf(uri)
  if uri:match("ytmusic") or uri:match("^yt:") then return "YTM" end
  return "Local"
end

-- Map result id -> uri so onActivate can act. id encodes action + uri.
-- We build ids like "play\turi" and "queue\turi".

function onQuery(text)
  text = noctalia.string.trim(text or "")
  if text == "" then
    launcher.setResults("", { { id = "_hint", title = "Type to search YouTube Music + local", glyph = "music" } })
    return
  end

  launcher.setResults(text, { { id = "_loading", title = "Searching…", glyph = "loader" } })

  local c = cfg()
  local cmd = mpc("-f " .. sq(FMT) .. " search any " .. sq(text))
            .. " | head -n " .. tostring(c.limit)

  noctalia.runAsync(cmd, function(res)
    local results = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local uri, title, artist = line:match("^(.-)\t(.-)\t(.*)$")
      if uri and uri ~= "" then
        if title == "" then title = uri:gsub("^.*/", "") end
        local src = sourceOf(uri)
        local sub = (artist ~= "" and artist or "") .. "   [" .. src .. "]"
        -- Play row
        table.insert(results, {
          id = "play\t" .. uri,
          title = title,
          subtitle = "▶ Play   ·   " .. sub,
          glyph = "player-play",
        })
        -- Queue row
        table.insert(results, {
          id = "queue\t" .. uri,
          title = title,
          subtitle = "+ Queue   ·   " .. sub,
          glyph = "plus",
        })
      end
    end
    if #results == 0 then
      results = { { id = "_none", title = "No results", glyph = "mood-empty" } }
    end
    launcher.setResults(text, results)
  end)
end

function onActivate(id)
  if id:sub(1, 1) == "_" then return end  -- hint/loading/none rows
  local action, uri = id:match("^(%a+)\t(.*)$")
  if not action or not uri then return end

  if action == "play" then
    local seq = mpc("clear") .. " && " .. mpc("add " .. sq(uri)) .. " && " .. mpc("play")
    noctalia.runAsync(seq, function()
      noctalia.notify("Music", "Playing")
    end)
  elseif action == "queue" then
    noctalia.runAsync(mpc("add " .. sq(uri)), function()
      noctalia.notify("Music", "Added to queue")
    end)
  end
end
