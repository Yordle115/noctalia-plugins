# yordle's Noctalia plugins
## **COMPLETELY AI GENERATED**
A Noctalia v5 plugin **source repo**. Add it as a source in Noctalia and install
plugins from it.

## Add this source

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
```

Then open **Settings → Plugins**, find the plugin below, and enable it.

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes.
> These plugins target the API as documented at docs.noctalia.dev/v5/plugins.

## Plugins in this repo

### Music (YTM + Local) — `yordle/music-yt`
GUI music panel: search YouTube Music **and** local library, play or queue,
manage playlists, now-playing header with thumbnail + transport. Driven through
**Mopidy** via the `mpc` CLI.

See [`music-yt/README.md`](music-yt/README.md) for the required NixOS setup
(`mopidy-mpd` + `mpc`), wiring (bar widget, keybind, `/music-yt` launcher), and
caveats.

**Requirements:** Mopidy running with `mopidy-mpd` + `mopidy-ytmusic`, and `mpc`
on PATH. Full details in the plugin README.

---

## Repo layout (for contributors / future plugins)

```
catalog.toml         # indexes every plugin for listing + compat-check
music-yt/            # subdir name = part of the id after the slash
  plugin.toml        # manifest
  *.luau             # entry scripts
  translations/
```

To add another plugin: make a new subdir matching `<author>/<name>`'s `<name>`,
put its `plugin.toml` + scripts inside, and add a `[[plugin]]` row to
`catalog.toml`. Catalog rows require at least `id` and `name`.
