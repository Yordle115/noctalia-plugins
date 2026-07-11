# Wallpaper Engine — Noctalia v5 plugin

A frontend for [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)
(Steam Workshop / Wallpaper Engine wallpapers on Linux) with the two things the
CLI doesn't give you:

- **Per-monitor selection** — browse your subscribed Workshop wallpapers with
  previews and assign each monitor its own wallpaper (or all at once).
- **Auto-pause** — wallpapers are **paused whenever windows are open**
  (SIGSTOP: the process stops rendering and drops to ~zero CPU/GPU), and
  resume the moment the workspace is empty again. Per monitor: a video call
  on one screen pauses that screen's wallpaper only.

Plus: manual pause/resume, restore-on-login, FPS limit, audio mute/volume,
scaling mode, and a raw `extra_args` passthrough.

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes. Built
> against the v5 plugin docs as of July 2026.

---

## How it works

- One `linux-wallpaperengine` process **per monitor** (that's what makes
  per-monitor pause possible), launched as
  `linux-wallpaperengine --screen-root <MON> --bg <ID> --fps N …`.
- The **panel** browses the Workshop directory (each item's `project.json`
  supplies the title + preview image), and spawns/kills processes when you
  assign wallpapers. Desired state persists in
  `~/.config/noctalia-wpe/state.json`.
- The **bar widget is the supervisor** — every second it checks Hyprland
  state (`hyprctl monitors/workspaces/activewindow -j`) and sends
  `SIGSTOP`/`SIGCONT` to each wallpaper process, enforces the manual pause
  flag, and respawns saved wallpapers whose process died (login, crash).
  **Add the widget to your bar or auto-pause and restore will not run.**

### Pause modes (Settings → Plugins)

| mode | behaviour |
|---|---|
| `windows` (default) | pause a monitor's wallpaper while **any** window is open on its active workspace — covers "pause when focused on a window" and stays paused while the wallpaper is covered |
| `focus` | pause only the monitor holding the currently focused window |
| `fullscreen` | pause only when the active workspace has a fullscreen window |
| `never` | no auto-pause |

---

## Requirements

- **linux-wallpaperengine** on `PATH` — on NixOS: `pkgs.linux-wallpaperengine`
- **Steam + Wallpaper Engine** Workshop content (subscribe to wallpapers in
  Steam; they land in `~/.local/share/Steam/steamapps/workshop/content/431960` —
  configurable in settings)
- **Hyprland** (`hyprctl`) for monitor enumeration and auto-pause
- `pgrep`/`pkill` (procps — present on any normal system)

## Install (as a source)

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
noctalia msg plugins enable yordle/wallpaper-engine
```

## Wire it up

**Bar widget (required)** — add `yordle/wallpaper-engine:bar` to a bar section.
Click = open panel, right-click = manual pause/resume toggle.

**Keybind** (Hyprland) — toggle the panel:
```lua
hl.bind("SUPER + W", hl.dsp.exec_cmd("noctalia msg panel-toggle yordle/wallpaper-engine:panel"))
```

## Settings (Settings → Plugins → gear)

- **Workshop content directory** — where Steam puts app 431960 items.
- **Auto-pause mode** — `windows` / `focus` / `fullscreen` / `never`.
- **FPS limit** (default 30), **mute audio** (default on), **volume**.
- **Scaling mode** — `default`, `stretch`, `fit`, `fill`.
- **Restore on login/crash** — the widget respawns saved wallpapers.
- **Extra CLI arguments** — passed verbatim (e.g. `--disable-mouse`).

---

## Known rough edges (alpha API)

- Auto-pause reacts within ~1 second (the widget's poll interval), not
  instantly on focus change.
- Hyprland-only for now: monitor names and window state come from `hyprctl`,
  so other compositors get neither the monitor chips nor auto-pause.
- The wallpaper list caps at 60 clickable rows — use the filter box to narrow
  large collections.
- If your linux-wallpaperengine build misbehaves with multiple instances,
  per-monitor assignment may glitch — test with one monitor first.
