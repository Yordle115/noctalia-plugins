# Wallpaper Engine — Noctalia v5 plugin

A frontend for [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)
(Steam Workshop / Wallpaper Engine wallpapers on Linux) with the two things the
CLI doesn't give you:

- **Per-monitor selection** — browse your subscribed Workshop wallpapers with
  previews and assign each monitor its own wallpaper (or all at once). One
  process drives all monitors by default.
- **Auto-pause** — wallpapers are paused via SIGSTOP (the process stops
  rendering and drops to ~zero CPU/GPU) **when a fullscreen app is running**
  by default — with transparent/blurred windows the wallpaper stays visible,
  so it keeps animating until it's truly hidden. Prefer maximum GPU savings
  instead? Switch the pause mode to `windows` or `focus` in settings.

Plus: manual pause/resume, restore-on-login, FPS limit, audio mute/volume,
scaling mode, and a raw `extra_args` passthrough.

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes. Built
> against the v5 plugin docs as of July 2026.

---

## How it works

- **One `linux-wallpaperengine` process drives all monitors** (default):
  `linux-wallpaperengine --screen-root DP-1 --bg <ID> --screen-root HDMI-A-1
  --bg <ID> --fps N …` — lighter on RAM/VRAM than one process per monitor.
  Because pausing a single process is all-or-nothing, the pause decision is
  aggregated (table below). Set `process_mode = per-monitor` in settings for
  one process per monitor with fully independent pause.
- The **panel** browses the Workshop directory (each item's `project.json`
  supplies the title + preview image), and relaunches the process when you
  assign wallpapers. Desired state persists in
  `~/.config/noctalia-wpe/state.json`.
- The **bar widget is the supervisor** — every second it checks Hyprland
  state (`hyprctl monitors/workspaces/activewindow -j`) and sends
  `SIGSTOP`/`SIGCONT`, enforces the manual pause flag, and respawns saved
  wallpapers whose process died (login, crash).
  **Add the widget to your bar or auto-pause and restore will not run.**

### Pause modes (Settings → Plugins)

Each monitor "triggers" per the mode; a process pauses based on the monitors
it drives:

| mode | a monitor triggers when… | single process pauses when… |
|---|---|---|
| `fullscreen` (default) | its active workspace has a fullscreen window | **any** monitor triggers |
| `windows` | **any** window is open on its active workspace | **every** monitor triggers (the wallpaper is visible nowhere) |
| `focus` | it holds the currently focused window | **any** monitor triggers |
| `never` | never | never |

`fullscreen` is the default because with window transparency/blur (and bar
gaps) the wallpaper stays partially visible while you work — pausing it there
would just show a frozen frame. `windows`/`focus` trade that visibility for
maximum GPU/battery savings.

In `per-monitor` process mode each monitor's process follows its own trigger
directly.

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
- **Auto-pause mode** — `fullscreen` (default) / `windows` / `focus` / `never`.
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
- In single-process mode, changing one monitor's wallpaper relaunches the
  shared process, so other monitors' wallpapers restart briefly. Use
  `per-monitor` mode if that bothers you (at the cost of one process per
  monitor).
