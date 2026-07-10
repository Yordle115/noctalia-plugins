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
