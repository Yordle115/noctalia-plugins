-- =============================================================================
--  panel.luau — Prayer Times  v0.4.0
--  Hijri date + the day's prayer table, with a next-prayer countdown.
--  Data from the AlAdhan API (defaults: Doha, Qatar — method 10), fetched
--  once per day via curl and cached in ~/.config/noctalia-prayers/today.json
--  (shared with the bar widget — whoever fetches first fills the cache).
-- =============================================================================

local DATA_DIR   = noctalia.expandPath("~/.config/noctalia-prayers")
local CACHE_FILE = DATA_DIR .. "/today.json"

local PRAYERS    = { "Fajr", "Dhuhr", "Asr", "Maghrib", "Isha" }          -- countdown targets
local TABLE_ROWS = { "Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha" } -- displayed rows

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
    -- per-prayer adhan correction in minutes (to match a local timetable)
    tune = {
      Fajr    = tonumber(getCfg("tune_fajr")) or 0,
      Sunrise = tonumber(getCfg("tune_sunrise")) or 0,
      Dhuhr   = tonumber(getCfg("tune_dhuhr")) or 0,
      Asr     = tonumber(getCfg("tune_asr")) or 0,
      Maghrib = tonumber(getCfg("tune_maghrib")) or 0,
      Isha    = tonumber(getCfg("tune_isha")) or 0,
    },
  }
end

-- ---------- view state ----------
local state = {
  data    = nil,   -- { date, timings, readable, hijri = {day,month,monthAr,year,weekday} }
  busy    = false,
  status  = "",
  lastMin = -1,    -- last minute-of-day we rendered (ticks re-render on change)
}

-- forward declaration
local render

-- ---------- time helpers ----------
local function toMin(hhmm)
  local h, m = tostring(hhmm or ""):match("^(%d+):(%d+)")
  if not h then return nil end
  return tonumber(h) * 60 + tonumber(m)
end

local function nowMinutes()
  return (tonumber(noctalia.formatTime("%H")) or 0) * 60 + (tonumber(noctalia.formatTime("%M")) or 0)
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

-- Next of the five daily prayers after nowMin; wraps to Fajr overnight
-- (approximating tomorrow's Fajr with today's — off by a minute or two).
local function nextPrayer(timings, nowMin)
  for _, name in ipairs(PRAYERS) do
    local m = toMin(timings[name])
    if m and m > nowMin then return name, m - nowMin end
  end
  local fajr = toMin(timings.Fajr) or 0
  return "Fajr", (24 * 60 - nowMin) + fajr
end

-- If we're inside a prayer's adhan→iqamah window, return that prayer and the
-- minutes remaining until iqamah (the countdown switches to this at adhan).
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

-- Apply the per-prayer adhan corrections to the raw API timings. Applied at
-- use time (not cache time) so changing an offset takes effect immediately.
local function tuneTimings(timings, tune)
  local out = {}
  for _, name in ipairs({ "Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha" }) do
    local m = toMin(timings[name])
    if m then
      m = (m + (tune[name] or 0)) % (24 * 60)
      out[name] = string.format("%02d:%02d", math.floor(m / 60), m % 60)
    end
  end
  return out
end

-- minutes-of-day -> clock text (for computed iqamah times)
local function fmtMinutes(totalMin, h12)
  totalMin = totalMin % (24 * 60)
  local h = math.floor(totalMin / 60)
  local mm = string.format("%02d", totalMin % 60)
  if not h12 then return string.format("%02d:%s", h, mm) end
  local suffix = h >= 12 and "PM" or "AM"
  local hh = h % 12
  if hh == 0 then hh = 12 end
  return hh .. ":" .. mm .. " " .. suffix
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

-- ---------- fetching (with real diagnostics) ----------
-- curl appends "@@HTTP:<code>" to the output (code 000 on network failure,
-- where the curl error text lands in the body via 2>&1) so failures can be
-- reported precisely instead of a generic "offline?".
local UA = "noctalia-prayer-times (github.com/Yordle115/noctalia-plugins)"

local function fetchCmd(url)
  return "curl -sS -L --max-time 15 -A " .. sq(UA)
    .. " -w '\\n@@HTTP:%{http_code}' " .. sq(url) .. " 2>&1"
end

local function splitHttp(out)
  local body, code = tostring(out or ""):match("^(.-)\n?@@HTTP:(%d+)%s*$")
  if not body then return tostring(out or ""), nil end
  return body, tonumber(code)
end

-- primary: city lookup; fallback: coordinates (city resolution sometimes fails)
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

local function describeFailure(body, code)
  if code == nil or code == 0 then
    local err = tostring(body or ""):match("curl: %(%d+%)[^\r\n]*") or "no network?"
    return "Network error — " .. err
  end
  if code ~= 200 then return "AlAdhan API returned HTTP " .. code end
  return "Unexpected API response (HTTP 200 but no timings)"
end

local function loadTimes(force)
  state.busy = true
  state.status = ""
  render()
  local today = noctalia.formatTime("%Y-%m-%d")

  local function fetch()
    if not noctalia.commandExists("curl") then
      state.busy = false
      state.status = "curl not found on PATH"
      render()
      return
    end
    local urls = apiUrls()
    noctalia.runAsync(fetchCmd(urls[1]), function(res)
      local body, code = splitHttp(res.stdout)
      local data = parseApi(body)
      if data then
        state.busy = false
        state.data = data
        saveCache(data)
        render()
        return
      end
      noctalia.runAsync(fetchCmd(urls[2]), function(r2)
        state.busy = false
        local d2 = parseApi((splitHttp(r2.stdout)))
        if d2 then
          state.data = d2
          state.status = "City lookup failed — using coordinates"
          saveCache(d2)
          render()
          return
        end
        -- both endpoints failed: a stale cached day beats nothing
        noctalia.runAsync("cat " .. sq(CACHE_FILE) .. " 2>/dev/null", function(r3)
          local ok, disk = pcall(function() return noctalia.json.decode(r3.stdout or "") end)
          if ok and type(disk) == "table" and type(disk.timings) == "table" then
            state.data = disk
            state.status = "Offline — cached times from " .. tostring(disk.date or "?")
              .. " (" .. describeFailure(body, code) .. ")"
          else
            state.status = describeFailure(body, code)
          end
          render()
        end)
      end)
    end)
  end

  if force then fetch(); return end
  noctalia.runAsync("cat " .. sq(CACHE_FILE) .. " 2>/dev/null", function(res)
    local ok, disk = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if ok and type(disk) == "table" and disk.date == today and type(disk.timings) == "table" then
      state.busy = false
      state.data = disk
      render()
    else
      fetch()
    end
  end)
end

-- =====================================================================
--  RENDER
-- =====================================================================

function render()
  local c = cfg()
  local kids = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 1 }, {
        ui.label({ text = "Prayer Times", fontSize = 15, fontWeight = "bold", color = "primary" }),
        ui.label({ text = c.city .. ", " .. c.country, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
        ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
      }),
    }),
  }

  if state.busy then
    kids[#kids + 1] = ui.row({ gap = 8, align = "center", paddingV = 12 }, {
      ui.glyph({ name = "loader", size = 16, color = "primary" }),
      ui.label({ text = "Loading…", fontSize = 13, color = "on_surface_variant" }),
    })
  elseif not state.data then
    kids[#kids + 1] = ui.label({
      text = state.status ~= "" and state.status or "No data yet — hit refresh.",
      fontSize = 13, color = "on_surface_variant", paddingV = 12,
    })
  else
    local d = state.data
    local h = d.hijri

    -- Hijri date card
    local card = {}
    if h.day ~= "" and h.month ~= "" then
      card[#card + 1] = ui.label({
        text = h.day .. " " .. h.month .. " " .. h.year .. " AH",
        fontSize = 16, fontWeight = "bold", color = "on_surface",
      })
    end
    if h.monthAr ~= "" then
      card[#card + 1] = ui.label({
        text = h.day .. " " .. h.monthAr .. " " .. h.year,
        fontSize = 13, color = "on_surface_variant",
      })
    end
    local greg = h.weekday
    if d.readable ~= "" then greg = (greg ~= "" and (greg .. " · ") or "") .. d.readable end
    if greg ~= "" then
      card[#card + 1] = ui.label({ text = greg, fontSize = 11, color = "on_surface_variant" })
    end
    kids[#kids + 1] = ui.column({ gap = 2, paddingV = 6, align = "center" }, card)

    -- countdown: next adhan — or iqamah while inside the adhan→iqamah window
    local T = tuneTimings(d.timings, c.tune)
    local nowMin = nowMinutes()
    local name, mins = nextPrayer(T, nowMin)
    local iqName, iqMins = iqamahWindow(T, nowMin, c.iq)
    kids[#kids + 1] = ui.row({ gap = 6, align = "center", justify = "center", paddingV = 4 }, {
      ui.glyph({ name = "clock", size = 15, color = "primary" }),
      ui.label({
        text = iqName
          and ("Iqamah for " .. iqName .. " in " .. fmtRemaining(iqMins))
          or (name .. " in " .. fmtRemaining(mins)),
        fontSize = 14, fontWeight = "bold", color = "primary",
      }),
    })
    kids[#kids + 1] = ui.separator({ spacing = 4 })

    -- prayer times table (Sunrise dimmed; prayers also show their iqamah time)
    local hlName = iqName or name
    for _, rowName in ipairs(TABLE_ROWS) do
      local isHl = (rowName == hlName)
      local color = isHl and "primary" or (rowName == "Sunrise" and "on_surface_variant" or "on_surface")
      local right = {
        ui.label({ text = fmtTime(T[rowName], c.h12), fontSize = 13, color = color, fontWeight = isHl and "bold" or nil }),
      }
      local off = c.iq[rowName] or 0
      local adhanMin = toMin(T[rowName])
      if off > 0 and adhanMin then
        table.insert(right, 1, ui.label({
          text = "iq " .. fmtMinutes(adhanMin + off, c.h12),
          fontSize = 10, color = "on_surface_variant",
        }))
      end
      kids[#kids + 1] = ui.row({ align = "center", justify = "space_between", paddingV = 3, key = "pt-" .. rowName }, {
        ui.label({ text = rowName, fontSize = 13, color = color, fontWeight = isHl and "bold" or nil }),
        ui.row({ gap = 8, align = "center" }, right),
      })
    end
  end

  if state.status ~= "" and state.data then
    kids[#kids + 1] = ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, kids))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen()
  panel.setWantsSecondTicks(true)
  loadTimes(false)
end

function update()
  if not state.data or state.busy then return end
  local nowMin = nowMinutes()
  if nowMin == state.lastMin then return end
  state.lastMin = nowMin
  -- refetch at the date rollover, otherwise just refresh the countdown
  if state.data.date ~= noctalia.formatTime("%Y-%m-%d") then
    loadTimes(false)
  else
    render()
  end
end

function onClose() panel.close() end
function onRefresh() loadTimes(true) end
