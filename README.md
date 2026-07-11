# yordle's Noctalia plugins

A Noctalia v5 plugin **source repo**.

> Some plugins here are AI-assisted.

## Add this source

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
noctalia msg plugins enable yordle/music-yt
```

Then open **Settings → Plugins** to configure.

## Plugins

### Music (YouTube + Local) — `yordle/music-yt`
GUI music panel: search YouTube (and optionally local files), play or queue,
favourites and playlists, transport controls, now-playing bar. Streams via
**yt-dlp + mpv** — no Mopidy, no accounts.

**Requires** `yt-dlp`, `mpv`, and `socat` on `PATH`. See
[`music-yt/README.md`](music-yt/README.md) for setup, wiring, and how it works.

### Wallpaper Engine — `yordle/wallpaper-engine`
Frontend for `linux-wallpaperengine`: browse Steam Workshop wallpapers with
previews, assign per monitor, auto-pause on fullscreen — or whenever windows
are open/focused (near-zero CPU/GPU while paused) — restore on login.
**Requires** `linux-wallpaperengine` and Hyprland. See
[`wallpaper-engine/README.md`](wallpaper-engine/README.md).

### Prayer Times — `yordle/prayer-times`
Next-prayer countdown on the bar with a notification at adhan time; the panel
shows the Hijri date and the day's prayer table. Defaults to Doha, Qatar
(AlAdhan API, one fetch per day, cached). **Requires** `curl`. See
[`prayer-times/README.md`](prayer-times/README.md).

### To-Do — `yordle/todo`
Simple persistent to-do list: panel with Active/Done tabs and pinning, bar
widget with the open-task count, and a `/todo` launcher command to add or
complete tasks. No external dependencies. See
[`todo/README.md`](todo/README.md).
