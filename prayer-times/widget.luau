-- =============================================================================
--  widget.luau — bar widget for Prayer Times
--  Shows the next prayer + countdown; sends a notification at adhan time.
--  Click opens the panel; middle-click forces a re-fetch.
--  Same AlAdhan data + daily cache as the panel
--  (~/.config/noctalia-prayers/today.json).
-- =============================================================================

local DATA_DIR   = noctalia.expandPath("~/.config/noctalia-prayers")
local CACHE_FILE = DATA_DIR .. "/today.json"

local PRAYERS = { "Fajr", "Dhuhr", "Asr", "Maghrib", "Isha" }

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
    city    = tostring(getCfg("city") or "Doha"),
    country = tostring(getCfg("country") or "Qatar"),
    method  = tonumber(getCfg("method")) or 10,
    h12     = getCfg("twelve_hour") ~= false,
    lat     = tostring(getCfg("latitude") or "25.2854"),
    lon     = tostring(getCfg("longitude") or "51.5310"),
    -- minutes from adhan to iqamah, per prayer
    iq = {
      Fajr    = tonumber(getCfg("iqamah_fajr")) or 25,
      Dhuhr   = tonumber(getCfg("iqamah_dhuhr")) or 20,
      Asr     = tonumber(getCfg("iqamah_asr")) or 25,
      Maghrib = tonumber(getCfg("iqamah_maghrib")) or 10,
      Isha    = tonumber(getCfg("iqamah_isha")) or 20,
    },
  }
end

local showCountdown = barWidget.getConfig("show_countdown") ~= false
local notifyAdhan   = barWidget.getConfig("notify") ~= false

local cached      = nil   -- parsed { date, timings, hijri, readable }
local fetching    = false
local lastCurrent = nil   -- last "current prayer" seen ("-" before Fajr)
local lastIqamah  = nil   -- prayer whose iqamah window we were in last tick

-- ---------- time helpers ----------
local function toMin(hhmm)
  local h, m = tostring(hhmm or ""):match("^(%d+):(%d+)")
  if not h then return nil end
  return tonumber(h) * 60 + tonumber(m)
end

local function fmtTime(hhmm, h12)
  local h, m = tostring(hhmm or ""):match("^(%d+):(%d+)")
  if not h then return "—" end
  h = tonumber(h)
  if not h12 then return string.format("%02d:%s", h, m) end
  local suffix = h >= 12 and "PM" or "AM"
  local hh = h % 12
  if hh == 0 then hh = 12 end
  return hh .. ":" .. m .. " " .. suffix
end

local function fmtRemaining(mins)
  if mins >= 60 then return math.floor(mins / 60) .. "h " .. (mins % 60) .. "m" end
  return mins .. "m"
end

local function nextPrayer(timings, nowMin)
  for _, name in ipairs(PRAYERS) do
    local m = toMin(timings[name])
    if m and m > nowMin then return name, m - nowMin end
  end
  local fajr = toMin(timings.Fajr) or 0
  return "Fajr", (24 * 60 - nowMin) + fajr
end

-- the most recent prayer whose time has passed today ("-" if none yet)
local function currentPrayer(timings, nowMin)
  local cur = "-"
  for _, name in ipairs(PRAYERS) do
    local m = toMin(timings[name])
    if m and m <= nowMin then cur = name end
  end
  return cur
end

-- If we're inside a prayer's adhan→iqamah window, return that prayer and the
-- minutes remaining until iqamah (the bar countdown switches to this at adhan).
local function iqamahWindow(timings, nowMin, iq)
  for _, name in ipairs(PRAYERS) do
    local m = toMin(timings[name])
    local off = iq[name] or 0
    if m and off > 0 and nowMin >= m and nowMin < m + off then
      return name, (m + off) - nowMin
    end
  end
  return nil
end

-- ---------- data ----------
local function parseApi(raw)
  local ok, parsed = pcall(function() return noctalia.json.decode(raw or "") end)
  if not ok or type(parsed) ~= "table" or type(parsed.data) ~= "table" then return nil end
  local d = parsed.data
  if type(d.timings) ~= "table" then return nil end
  local hijri = (type(d.date) == "table" and type(d.date.hijri) == "table") and d.date.hijri or {}
  return {
    date     = noctalia.formatTime("%Y-%m-%d"),
    timings  = d.timings,
    readable = (type(d.date) == "table" and d.date.readable) or "",
    hijri = {
      day     = tostring(hijri.day or ""),
      month   = (type(hijri.month) == "table" and hijri.month.en) or "",
      monthAr = (type(hijri.month) == "table" and hijri.month.ar) or "",
      year    = tostring(hijri.year or ""),
      weekday = (type(hijri.weekday) == "table" and hijri.weekday.en) or "",
    },
  }
end

local function saveCache(data)
  local json = noctalia.json.encode(data)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(CACHE_FILE), nil)
end

-- Same fetch strategy as the panel: real UA + redirects, coordinates
-- endpoint as fallback, and stale cache rather than nothing when offline.
local UA = "noctalia-prayer-times (github.com/Yordle115/noctalia-plugins)"

local function fetchCmd(url)
  return "curl -sS -L --max-time 15 -A " .. sq(UA)
    .. " -w '\\n@@HTTP:%{http_code}' " .. sq(url) .. " 2>&1"
end

local function stripHttp(out)
  local body = tostring(out or ""):match("^(.-)\n?@@HTTP:%d+%s*$")
  return body or tostring(out or "")
end

local function apiUrls()
  local c = cfg()
  local city = (c.city:gsub(" ", "%%20"))
  local country = (c.country:gsub(" ", "%%20"))
  return {
    "https://api.aladhan.com/v1/timingsByCity?city=" .. city
      .. "&country=" .. country .. "&method=" .. tostring(c.method),
    "https://api.aladhan.com/v1/timings?latitude=" .. c.lat
      .. "&longitude=" .. c.lon .. "&method=" .. tostring(c.method),
  }
end

local function ensureData(cb)
  local today = noctalia.formatTime("%Y-%m-%d")
  if cached and cached.date == today then cb(cached); return end
  -- disk cache first (the panel may have fetched already)
  noctalia.runAsync("cat " .. sq(CACHE_FILE) .. " 2>/dev/null", function(res)
    local ok, disk = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    local diskOk = ok and type(disk) == "table" and type(disk.timings) == "table"
    if diskOk and disk.date == today then
      cached = disk
      cb(cached)
      return
    end
    if fetching or not noctalia.commandExists("curl") then
      cb(diskOk and disk or cached)   -- stale beats nothing
      return
    end
    fetching = true
    local urls = apiUrls()
    noctalia.runAsync(fetchCmd(urls[1]), function(r1)
      local data = parseApi(stripHttp(r1.stdout))
      if data then
        fetching = false
        cached = data
        saveCache(data)
        cb(data)
        return
      end
      noctalia.runAsync(fetchCmd(urls[2]), function(r2)
        fetching = false
        local d2 = parseApi(stripHttp(r2.stdout))
        if d2 then
          cached = d2
          saveCache(d2)
          cb(d2)
          return
        end
        cb(diskOk and disk or cached)   -- stale beats nothing
      end)
    end)
  end)
end

-- ---------- widget ----------
function update()
  noctalia.setUpdateInterval(30000)

  ensureData(function(data)
    barWidget.setGlyph("building-mosque")
    if not data then
      barWidget.setText("")
      barWidget.setTooltip("Prayer Times — no data (offline?)")
      return
    end
    local c = cfg()
    local nowMin = (tonumber(noctalia.formatTime("%H")) or 0) * 60 + (tonumber(noctalia.formatTime("%M")) or 0)
    local name, mins = nextPrayer(data.timings, nowMin)

    -- adhan notification when a prayer time is reached (skip first tick)
    local cur = currentPrayer(data.timings, nowMin)
    if cur ~= lastCurrent then
      if notifyAdhan and lastCurrent ~= nil and cur ~= "-" then
        noctalia.notify("Prayer Times", "It's time for " .. cur .. " — " .. fmtTime(data.timings[cur], c.h12))
      end
      lastCurrent = cur
    end

    -- iqamah: after adhan the countdown switches to the iqamah window; when
    -- the window closes, that IS iqamah time — notify
    local iqName, iqMins = iqamahWindow(data.timings, nowMin, c.iq)
    if lastIqamah and iqName ~= lastIqamah and notifyAdhan then
      noctalia.notify("Prayer Times", "Iqamah for " .. lastIqamah)
    end
    lastIqamah = iqName

    if iqName then
      barWidget.setText("Iqamah · " .. fmtRemaining(iqMins))
    elseif showCountdown then
      barWidget.setText(name .. " · " .. fmtRemaining(mins))
    else
      barWidget.setText(name .. " " .. fmtTime(data.timings[name], c.h12))
    end

    local h = data.hijri
    local lines = {}
    if data.date ~= noctalia.formatTime("%Y-%m-%d") then
      lines[#lines + 1] = "⚠ offline — cached from " .. tostring(data.date or "?")
    end
    if h.day ~= "" and h.month ~= "" then
      lines[#lines + 1] = h.day .. " " .. h.month .. " " .. h.year .. " AH"
    end
    if iqName then
      lines[#lines + 1] = "Iqamah for " .. iqName .. " in " .. fmtRemaining(iqMins)
    end
    for _, p in ipairs({ "Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha" }) do
      lines[#lines + 1] = p .. "  " .. fmtTime(data.timings[p], c.h12)
    end
    barWidget.setTooltip(table.concat(lines, "\n"))
  end)
end

function onClick()
  noctalia.togglePanel("yordle/prayer-times:panel")
end

function onMiddleClick()
  -- force a re-fetch: drop caches; the next tick re-downloads
  cached = nil
  noctalia.runAsync("rm -f " .. sq(CACHE_FILE), nil)
end
