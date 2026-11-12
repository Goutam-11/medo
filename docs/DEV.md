# medo — development notes

How to run, poke and debug the plugin on this machine (Noctalia 5.4.1, niri, Fedora 44).

## One-time setup

```bash
# register this repo as a local plugin source (path sources have no revisions)
noctalia msg plugins source add medo-dev path ~/personal-projects/medo
noctalia msg plugins enable goutamsharma/medo
```

Put medo on a bar (Noctalia's settings UI can do this too):

```toml
# ~/.local/state/noctalia/settings.toml
[bar.default]
start = [ "launcher", "wallpaper", "workspaces", "hyusk", "medo" ]

[widget.medo]
type = "goutamsharma/medo:bar"
```

## Layout rule (learned the hard way)

A `path` source points at a **directory of plugin directories**, and each plugin directory
**must be named after the id suffix**. `medo/` with id `goutamsharma/medo` works;
`plugin/` with the same id fails to enable with:

```
cannot enable 'goutamsharma/medo': parse error: File could not be opened for reading
```

That message is a path-resolution failure, not a syntax error — no Lua error is involved.

## Gates

```bash
make check     # manifest + translations + Luau compile + tests; exactly what CI runs
make tools     # only: fetch Luau 0.746 into .tools/
make lint      # noctalia plugins lint (needs the shell)
```

`tools/check_manifest.py` enforces the rules CI cares about: id shape, semver, `plugin_api`
ceiling, entry files that exist and are non-empty, settable types, panel sizing, and that every
`label_key`/`description_key` resolves in `translations/en.json`.

## Dev loop

- Edit any `.luau` file → the shell hot-reloads that entry (watchers are logged).
- Edit `plugin.toml` (entries, settings, panel size) → `noctalia msg config-reload`.
- Lint the manifest against the code before committing: `noctalia plugins lint medo`.
- Log: `~/.cache/noctalia/noctalia.log`. Useful greps:
  - `grep -iE 'medo|<entry>.luau' ~/.cache/noctalia/noctalia.log`
  - `grep -iE '\[ERR\]|cannot enable|parse error' …`
- Never assume a prop exists: the host silently skips props newer than `plugin_api`, and the
  shell's ceiling is **43** on 5.4.1.

## IPC cheat-sheet

```bash
noctalia msg plugins list | grep medo          # state + version
noctalia msg plugin goutamsharma/medo:core all ping       # service → toast
noctalia msg plugin goutamsharma/medo:bar all refresh      # force a widget repaint
noctalia msg panel-toggle goutamsharma/medo:panel          # open/close the panel
noctalia msg panel-close
noctalia msg config-reload
noctalia msg plugins disable goutamsharma/medo
noctalia msg plugins source list
```

## Visual checks

```bash
grim -g "0,0 1768x48" /tmp/bar.png   # the bar strip (geometry: `noctalia msg outputs`? see log)
grim /tmp/screen.png                 # full screen, for panel work
```

The bar geometry on this machine is 1768x48 in the log; adjust to the current output.

## Testing without waiting for time to pass

The service exposes test seams over IPC so the day boundary can be exercised without touching
the clock:

```bash
noctalia msg plugin goutamsharma/medo:core all debug-seed-demo      # 3 today + 1 carried fixture
noctalia msg plugin goutamsharma/medo:core all debug-dump           # path + counts + streak
noctalia msg plugin goutamsharma/medo:core all debug-rollover       # close today, carry into tomorrow
noctalia msg plugin goutamsharma/medo:core all debug-backdate 2026-11-09  # lie about the day; restart to test catch-up
noctalia msg plugin goutamsharma/medo:core all debug-reset          # empty list for today
noctalia msg plugin goutamsharma/medo:core all add '{"title":"buy milk","estimate_min":15}'
noctalia msg plugin goutamsharma/medo:core all progress '{"id":"t_…","progress":60}'
```

State lives in `~/.local/state/noctalia/plugins/data/goutamsharma/medo/`:
`tasks.json` (live doc), `tasks.json.bak` (previous generation), `history.json` (closed days),
`backups/tasks-<day>.json` (last 14 rollovers). Delete the directory to start over.

Unit tests are plain Luau and run under `TZ=UTC` so date expectations hold anywhere:

```bash
make test        # TZ=UTC .tools/luau tests/logic_test.luau
```

## Files

| File | Runs | Notes |
|---|---|---|
| `medo/plugin.toml` | — | manifest; entry ids, `plugin_api = 43`, panel size |
| `medo/core.luau` | service | owns `tasks.json`, rollover, reminders, reports |
| `medo/bar.luau` | bar widget | renders `noctalia.state` view; click opens the panel |
| `medo/panel.luau` | panel | five tabs, slider, keyboard |
| `medo/translations/en.json` | — | settings labels (`label_key` must resolve here) |
