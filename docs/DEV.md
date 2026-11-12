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
noctalia msg plugin goutamsharma/medo:core all debug-seed-report    # 14 closed days + 3 live tasks
noctalia msg plugin goutamsharma/medo:core all debug-dump           # path + counts + streak + closed days
noctalia msg plugin goutamsharma/medo:core all debug-rollover       # close today, carry into tomorrow
noctalia msg plugin goutamsharma/medo:core all debug-backdate 2026-11-09  # lie about the day; restart to test catch-up
noctalia msg plugin goutamsharma/medo:core all debug-report weekly   # build + publish a report
noctalia msg plugin goutamsharma/medo:core all debug-export weekly   # write <export_dir>/medo-weekly-<end>.md
noctalia msg plugin goutamsharma/medo:core all debug-export monthly json  # …and a JSON monthly report
noctalia msg plugin goutamsharma/medo:core all debug-reset           # empty list for today
noctalia msg plugin goutamsharma/medo:core all debug-reset-history   # empty history.json
noctalia msg plugin goutamsharma/medo:core all add '{"title":"buy milk","estimate_min":15}'
noctalia msg plugin goutamsharma/medo:core all progress '{"id":"t_…","progress":60}'
noctalia msg plugin goutamsharma/medo:core all park '{"id":"t_…"}'
noctalia msg plugin goutamsharma/medo:core all promote '{"id":"t_…"}'
noctalia msg plugin goutamsharma/medo:core all delete '{"id":"t_…"}'
```

The panel can be opened on a specific surface, which is also how notifications will land:

```bash
noctalia msg panel-open goutamsharma/medo:panel add              # focus the capture field
noctalia msg panel-open goutamsharma/medo:panel pending          # open the Pending tab
noctalia msg panel-open goutamsharma/medo:panel edit:<id>        # open the editor for a task
noctalia msg panel-open goutamsharma/medo:panel dashboard        # score, streak, next due, sparkline
noctalia msg panel-open goutamsharma/medo:panel reports          # weekly report (requests it)
noctalia msg panel-open goutamsharma/medo:panel reports-monthly  # monthly report
```

Keyboard behaviour, learned the hard way (do not re-litigate this):

- A Noctalia attached panel takes keyboard focus **on demand** — only after a click. There is
  no manifest switch that makes it grab focus on open on niri (`keyboard_focus = "exclusive"`
  did not change the observed behaviour).
- `capture_keys`/`onKey` did fire when the panel happened to hold focus, but that state is not
  reachable reliably, and while an input is focused every printable key goes to the input — so
  in-panel key shortcuts were removed rather than shipped half-working.
- The reliable keyboard path is **capture-first**: `onOpen` focuses the add field, so typing +
  Enter adds a task. Verified end-to-end with typed input.
- Global shortcuts belong in niri, not the plugin. These are installed on this machine:

  ```kdl
  Mod+Shift+M hotkey-overlay-title="medo: capture a task" { spawn-sh "noctalia msg panel-open goutamsharma/medo:panel add"; }
  Mod+Alt+M  hotkey-overlay-title="medo: open today"      { spawn-sh "noctalia msg panel-open goutamsharma/medo:panel"; }
  ```

  `panel-open … add` lands on the panel with the capture field focused, which is the one
  keyboard path that has worked reliably. Re-validate after editing: `niri validate`.

## Reports and exports (Phase 3)

The dashboard reads the published view (`score`, `streak`, `next_due`, `carried_in`,
`sparkline`); the service computes the sparkline from the in-memory copy of `history.json` plus
the live day, so a publish does not read the disk.

Reports are **on demand**, not scheduled (that is Phase 4):

- The panel sends `{ kind = "report", period = "weekly" | "monthly" }` on the command channel.
- `core.luau` aggregates `history.json` + the live snapshot with the pure functions in
  `logic.luau` and publishes the whole report under `view.report`.
- `view.report.for_revision` is the document revision it was built from. When anything changes
  (a slider, a rollover, the seed fixture) the panel sees the mismatch and re-requests, so a
  report never silently shows stale numbers.
- `{ kind = "export", period = …, format = "markdown" | "json" }` rebuilds the report and writes
  `medo-<period>-<end_day>.md|.json` into the `export_dir` setting. Empty (the default) resolves
  to `$XDG_DOCUMENTS_DIR`, then `~/Documents`; `store.write_text` creates the folder. The path of
  the last write is published as `view.last_export` and shown in the Reports footer.

Two platform quirks worth remembering:

- **`ui.graph` smooths its samples.** It is a trend line, not a bar chart: values 0/1 alternating
  render as a soft wave. The report prints the exact score under each day so the numbers stay
  honest; the dashboard sparkline is only a shape.
- **`ui.progress` marker** exists on 5.4.1 (release notes list `marker`/`markerColor`), but the
  bundled `.ref` type stub predates it. The shell accepts it with no skipped-prop warning; keep
  using it for the daily-target line.

The `debug-seed-report` fixture is deterministic and hand-checkable. It writes fourteen closed
days ending yesterday from three weighted tasks (60/30/20 min) and seeds three live tasks; the
comment above `REPORT_PATTERN` in `core.luau` lists the resulting daily scores. On 2026-11-12 the
weekly export lands on: 6/12 done, score 74 %, 6 carried (50 %), on time 2/4 (50 %), avg at close
34 %, best Tue 10 Nov (100 %), worst Mon 9 Nov (44 %) — all derivable from `history.json` plus
`tasks.json`.

## Files

| File | Runs | Notes |
|---|---|---|
| `medo/plugin.toml` | — | manifest; entry ids, `plugin_api = 43`, panel size |
| `medo/core.luau` | service | owns `tasks.json`, rollover, reminders, reports, exports |
| `medo/bar.luau` | bar widget | renders `noctalia.state` view; click opens the panel |
| `medo/panel.luau` | panel | Today / Pending / Dashboard / Reports (Trash in Phase 5) |
| `medo/translations/en.json` | — | settings labels (`label_key` must resolve here) |
