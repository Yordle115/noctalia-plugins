# Music (YouTube + Local) — Noctalia v5 plugin

A GUI music panel for Noctalia v5 that searches **YouTube** (and optionally your
local library), plays or queues tracks, and gives you transport controls — all
streamed through **yt-dlp + mpv**. No Mopidy, no MPD, no accounts, no OAuth.

This is the same approach Noctalia v4's `music-search` used: yt-dlp resolves
YouTube, mpv plays the audio in the background, and an mpv IPC socket drives
pause/seek/etc. All actively-maintained tooling that works against current
YouTube.

Three entry points:
- **Bar widget** — click toggles the panel; shows now-playing glyph + title.
  Right-click = play/pause, middle-click = stop.
- **Panel** — a single column: tabs (Search / Queue / Favourites / Playlists)
  over one list, with a now-playing bar (album art, progress, transport,
  shuffle/repeat, favourite) pinned at the bottom.
- **Launcher** `/music-yt <query>` — quick YouTube search; each hit offers a
  ▶ Play row and a + Queue row. Requests hand off to the panel via Noctalia's
  shared state channel (the panel picks them up while open, or within a minute
  of being opened).

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes. Built
> against the v5 plugin docs as of July 2026.

---

## Requirements

Three commands on `PATH`:

- **yt-dlp** — YouTube search + stream resolution
- **mpv** — audio playback
- **socat** — talks to mpv's IPC socket for transport control

On NixOS, in your `media.nix` `environment.systemPackages`:

```nix
environment.systemPackages = with pkgs; [
  # ... your existing packages ...
  yt-dlp
  mpv
  socat      # ← required for mpv IPC control
];
```

Then `nixosrebuild`. The plugin checks for these at runtime and shows a clear
message if one is missing (e.g. "socat not found — add it to media.nix").

No services, no daemons — the plugin launches mpv on demand.

---

## Install (as a source)

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
noctalia msg plugins enable yordle/music-yt
```

`source add` makes it available; `enable` materializes and loads it. Then it
appears in **Settings → Plugins**.

For local iteration, drop the plugin folder in
`~/.local/state/noctalia/plugins/` — local copies outrank the source and hot-
reload on `.luau` edits.

---

## Wire it up

**Bar widget** — add `yordle/music-yt:bar` to a bar section in your Noctalia
bar config.

**Keybind** (Hyprland) — toggle the panel:
```lua
hl.bind("SUPER + M", hl.dsp.exec_cmd("noctalia msg panel-toggle yordle/music-yt:panel"))
```

**Launcher** — type `/music-yt <song>` once the plugin is enabled.

---

## Settings (Settings → Plugins → gear)

- **Search results** — how many YouTube results per search (default 15).
- **yt-dlp player client** — YouTube extractor client (default `android`; fast
  and reliable. Alternatives: `web`, `tv`, `ios` — change if YouTube breaks one).
- **Also search local library** — include local files in results (default off).
- **Local music directory** — folder to search when local is on (default `~/Music`).
- **Bar widget**: show title on/off, max title length.

---

## How it works

- **Search:** `yt-dlp --flat-playlist --dump-single-json ytsearch15:<query>` —
  `--flat-playlist` keeps it fast (doesn't resolve each video). Results parsed
  in Luau (no jq needed).
- **Play:** `mpv --no-video --ytdl-format=bestaudio/best --input-ipc-server=<sock> <url>`
  launched detached with `setsid`. mpv uses yt-dlp internally to resolve the
  audio stream.
- **Transport:** JSON commands piped to the mpv socket via socat, e.g.
  `{"command":["set_property","pause",true]}`. Now-playing/position read the
  same way (`playback-time`, `duration`, `media-title`, `eof-reached`).
- **Queue:** managed in the panel's Luau state. When a track ends (mpv socket
  gone or `eof-reached`), the next queue item plays automatically.
- **Launcher ↔ panel:** the launcher publishes play/queue requests on
  `noctalia.state` (`launcher_request`); the panel watches for them and handles
  playback with its live mpv state — so launcher and panel stay in sync.

Socket lives at `/tmp/noctalia-music-mpv.sock`.

---

## Scope (v0.4.0)

Included: YouTube search → play/queue → transport (pause, prev/next, ±10s
seek, stop), shuffle + repeat, favourites, playlists (save/load the queue
locally, load YouTube playlist URLs), now-playing with album art. Deliberately
**not** included yet (were in v4): mp3 downloads, SoundCloud provider,
ratings/tags. These can be added later as phase 2.

Known rough edges (alpha API):
- Per-row buttons use a fixed pool of 80 handlers; lists show at most 80
  clickable rows and note "…and N more" past that (queued tracks beyond the
  cap still auto-play in order).
- Now-playing polls mpv every ~2s (bar widget) — position updates aren't
  frame-smooth, they tick.
- Queue is in-memory (panel state); it isn't persisted across Noctalia restarts.

---

## Troubleshooting

```fish
# Are the three deps present?
which yt-dlp mpv socat

# Does yt-dlp search work on its own? (mirrors what the plugin runs)
yt-dlp --flat-playlist --dump-single-json "ytsearch3:daft punk" | head -c 300

# Is mpv playing? (check the socket exists while a track plays)
ls -la /tmp/noctalia-music-mpv.sock

# Poke the socket manually (should return JSON if mpv is running)
printf '%s\n' '{"command":["get_property","media-title"]}' | socat -t 1 - UNIX-CONNECT:/tmp/noctalia-music-mpv.sock
```

If yt-dlp search works on the CLI but the panel shows nothing, check Noctalia's
log (`~/.cache/noctalia/noctalia.log`) for the plugin's script context. If
YouTube starts returning errors on one player client, switch `yt_player_client`
in settings (android → web → tv).
