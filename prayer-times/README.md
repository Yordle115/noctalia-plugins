# Prayer Times — Noctalia v5 plugin

Islamic prayer times for Noctalia v5, defaulting to **Doha, Qatar**.

Two entry points:
- **Bar widget** — the next prayer and a live countdown (e.g. `Maghrib · 1h 23m`),
  with a notification when adhan time arrives. When the adhan countdown hits 0
  it switches to an **iqamah countdown** (`Iqamah · 8m`) and notifies again at
  iqamah time. Tooltip shows the Hijri date and the full table. Click opens
  the panel; middle-click forces a re-fetch.
- **Panel** — the Hijri date (English + Arabic month) and the day's prayer
  table (Fajr, Sunrise, Dhuhr, Asr, Maghrib, Isha) with each prayer's iqamah
  time, the current/next prayer highlighted, and the same adhan/iqamah
  countdown.

Iqamah offsets (minutes after adhan, each a setting): **Fajr 25 · Dhuhr 20 ·
Asr 25 · Maghrib 10 · Isha 20**. Set an offset to 0 to disable that prayer's
iqamah window.

Times come from the free [AlAdhan API](https://aladhan.com/prayer-times-api)
using Qatar's official calculation method (`method=10`) — no API key. The
response is fetched **once per day** with `curl` and cached in
`~/.config/noctalia-prayers/today.json` (shared by the widget and the panel),
so the plugin works offline for the rest of the day. The Hijri date comes from
the same response.

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes. Built
> against the v5 plugin docs as of July 2026.

---

## Requirements

- **curl** on `PATH` (internet needed once per day for the fetch).

## Install (as a source)

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
noctalia msg plugins enable yordle/prayer-times
```

## Wire it up

**Bar widget** — add `yordle/prayer-times:bar` to a bar section in your
Noctalia bar config.

**Keybind** (Hyprland) — toggle the panel:
```lua
hl.bind("SUPER + P", hl.dsp.exec_cmd("noctalia msg panel-toggle yordle/prayer-times:panel"))
```

## Settings (Settings → Plugins → gear)

- **City / Country** — location passed to the AlAdhan API (default Doha, Qatar).
- **Calculation method** — AlAdhan method id (default `10` = Qatar; `4` =
  Umm Al-Qura, `3` = Muslim World League, `8` = Gulf Region).
- **12-hour clock** — `5:07 PM` vs `17:07`.
- **Adhan offsets** — per-prayer ±minutes correction if the API drifts from
  your local timetable (e.g. QatarPrayer). Compare the panel's table against
  the local one and set each prayer's offset; applies immediately to the
  countdown, table, notifications and iqamah windows.
- **Iqamah offsets** — minutes from adhan to iqamah per prayer
  (defaults 25/20/25/10/20; 0 disables).
- **Bar widget**: countdown on/off, adhan+iqamah notifications on/off.

---

## Troubleshooting

The panel status line reports the exact failure — an HTTP code from the API,
or the curl network error. The fetch tries the city endpoint first, then falls
back to coordinates (settings: latitude/longitude), then to the last cached
day if both fail ("Offline — cached times from …").

Mirror what the plugin runs to test by hand:

```fish
curl -sS -L -A noctalia "https://api.aladhan.com/v1/timingsByCity?city=Doha&country=Qatar&method=10" | head -c 300
```

If that works in a terminal but the plugin still reports a network error,
Noctalia's script context may have a restricted PATH or environment — check
`~/.cache/noctalia/noctalia.log`.

## Known rough edges (alpha API)

- After Isha the countdown targets **today's** Fajr time as an approximation
  of tomorrow's (they drift by a minute or two per day); the real time loads
  at the date rollover.
- The adhan notification is a desktop notification — it doesn't play the
  adhan audio (a candidate for a future version, e.g. via mpv).
- The widget polls every 30s, so the countdown ticks in ~half-minute steps.
