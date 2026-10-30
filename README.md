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

### Discord Voice (local fork) — `raycursive/discord-voice`
Fork of the community plugin [`raycursive/discord-voice`](https://github.com/noctalia-dev/community-plugins/tree/main/discord-voice)
v0.3.3 (MIT): bar widget and panel for the Discord desktop client's voice
session, plus `toggle-mute`, `toggle-deafen` and `toggle-screenshare` IPC
events for compositor keybinds, and silent renewal of an expired Discord token.
It keeps the upstream id, so this source replaces the community copy.
**Requires** `python3` and the Discord desktop client. See
[`discord-voice/README.md`](discord-voice/README.md).

```fish
noctalia msg plugin raycursive/discord-voice:bridge all toggle-mute
noctalia msg plugin raycursive/discord-voice:bridge all toggle-deafen
noctalia msg plugin raycursive/discord-voice:bridge all toggle-screenshare
```
