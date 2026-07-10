# To-Do — Noctalia v5 plugin

A simple persistent to-do list for Noctalia v5. No external dependencies —
tasks live in a JSON file and everything runs inside the shell.

Three entry points:
- **Panel** — Active / Done tabs, an add-task input, per-task pin (floats to
  the top), complete, and delete.
- **Bar widget** — shows the open-task count; click toggles the panel.
  Tooltip previews the first few open tasks.
- **Launcher** `/todo <text>` — offers an "Add: <text>" row plus any matching
  open tasks (activating one marks it done). `/todo` alone lists open tasks.

Tasks are stored in `~/.config/noctalia-todo/todos.json`, shared by all three
entry points. The panel reloads it on every open, and the bar widget re-reads
it every ~5s, so launcher additions show up everywhere.

> ⚠️ Noctalia's plugin API is **alpha** and subject to breaking changes. Built
> against the v5 plugin docs as of July 2026.

---

## Install (as a source)

```fish
noctalia msg plugins source add yordle git https://github.com/Yordle115/noctalia-plugins
noctalia msg plugins enable yordle/todo
```

## Wire it up

**Bar widget** — add `yordle/todo:bar` to a bar section in your Noctalia bar
config.

**Keybind** (Hyprland) — toggle the panel:
```lua
hl.bind("SUPER + T", hl.dsp.exec_cmd("noctalia msg panel-toggle yordle/todo:panel"))
```

**Launcher** — type `/todo <task>` once the plugin is enabled.

## Settings (Settings → Plugins → gear)

- **Bar widget**: show open-task count on/off.

---

## Known rough edges (alpha API)

- Per-row buttons use a fixed pool of 60 handlers; each tab shows at most 60
  clickable rows and notes "…and N more" past that.
- Writes are last-write-wins: editing from the panel and the launcher at the
  exact same moment can drop one change (rare in practice — the panel reloads
  the file every time it opens).
- No due dates or reminders yet — candidates for a future version.
