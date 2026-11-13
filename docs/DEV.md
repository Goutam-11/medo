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
noctalia msg plugin goutamsharma/medo:core all debug-tick 08:00      # run the notification scheduler at a fake local time
noctalia msg plugin goutamsharma/medo:core all debug-clock-clear     # back to the real clock
noctalia msg plugin goutamsharma/medo:core all debug-notify weekly   # show one notification copy without the clock
noctalia msg plugin goutamsharma/medo:core all debug-reset-state     # forget today's notification keys
noctalia msg plugin goutamsharma/medo:core all debug-reset           # empty list for today
noctalia msg plugin goutamsharma/medo:core all debug-reset-history   # empty history.json
noctalia msg plugin goutamsharma/medo:core all add '{"title":"buy milk","estimate_min":15}'
noctalia msg plugin goutamsharma/medo:core all progress '{"id":"t_…","progress":60}'
noctalia msg plugin goutamsharma/medo:core all park '{"id":"t_…"}'
noctalia msg plugin goutamsharma/medo:core all promote '{"id":"t_…"}'
noctalia msg plugin goutamsharma/medo:core all delete '{"id":"t_…"}'
noctalia msg plugin goutamsharma/medo:core all restore '{"id":"t_…"}'      # Trash → Today
noctalia msg plugin goutamsharma/medo:core all purge '{"id":"t_…"}'        # delete forever
noctalia msg plugin goutamsharma/medo:core all empty-trash
noctalia msg plugin goutamsharma/medo:core all debug-seed-trash            # 3 rows, 0/3/27 days old
```

The panel can be opened on a specific surface, which is also how notifications will land:

```bash
noctalia msg panel-open goutamsharma/medo:panel add              # focus the capture field
noctalia msg panel-open goutamsharma/medo:panel pending          # open the Pending tab
noctalia msg panel-open goutamsharma/medo:panel edit:<id>        # open the editor for a task
noctalia msg panel-open goutamsharma/medo:panel dashboard        # score, streak, next due, sparkline
noctalia msg panel-open goutamsharma/medo:panel reports          # weekly report (requests it)
noctalia msg panel-open goutamsharma/medo:panel reports-monthly  # monthly report
noctalia msg panel-open goutamsharma/medo:panel triage           # the 21:00 decision card
noctalia msg panel-open goutamsharma/medo:panel trash            # Trash tab with counts
noctalia msg panel-open launcher "/medo buy milk @17:00 #errand !high"   # launcher capture
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

## Notifications (Phase 4a)

`core.luau` calls the pure `logic.notifications(now_ms, day, tasks, context, settings, notified)`
on every one-second tick. It returns the notifications that are due **and not already in the
dedupe map**; the service sends them, logs `medo: notify <key> :: <body>`, and saves
`state.json` before the next tick.

- **Settings** (see `docs/PLAN.md` §9): seven `notify_*` switches, `morning_time` 08:00,
  `evening_time` 21:00, `atrisk_time` 15:00, `weekly_day` Sunday, `weekly_time` 20:00,
  `monthly_time` 20:00, `quiet_start` 22:00, `quiet_end` 07:00, `lead_min` 15.
- **Times** are local `HH:MM`. A scheduled notification has a 60-minute window after its time
  (`logic.scheduled_window`), so a sleeping laptop catches up at 08:40 but a restart at lunchtime
  does not replay the morning. Due alerts are the only notification exempt from quiet hours; lead
  and scheduled notices are suppressed inside the window.
- **Dedupe**: `state.json` = `{ schema, day, last_tick_ms, notified = { key = ms } }`. Keys are
  `morning:<day>`, `atrisk:<day>`, `evening:<day>`, `weekly:<day>`, `monthly:<day>`,
  `due:<task id>:<due_ms>` and `lead:<task id>:<due_ms>`. The map is cleared when the logical day
  changes, so a task rescheduled to tomorrow can notify again. A notification never has action
  buttons; the toast is the doorbell.
- **Monthly** on the 1st at 20:00 reviews the month that just ended: the service builds the
  report with `today = yesterday`, so `month_label` is the previous month. **Weekly** reviews the
  week containing the fire day.
- **Debug**: `debug-tick HH:MM` shifts only the scheduler clock (wall-clock delta; do not build an
  epoch from date parts — this Luau's `os.time` treats tables as UTC), `debug-clock-clear` resets
  it, `debug-notify <kind>` shows one copy without touching the state, `debug-reset-state` forgets
  the keys. To screenshot a toast: `focus-workspace 2` to an empty workspace first (a fullscreen
  window hides layer surfaces), `debug-tick`, then `grim` within the 6-second toast timeout.
- **Verification recipe**: seed with `debug-seed-demo`, `debug-reset-state`, `debug-tick 08:00`
  (morning), `debug-tick 15:00` (at-risk; the demo score is 25), `debug-tick 21:00` (evening), then
  add a task due in two minutes and tick ten minutes later (due) or twenty minutes later (lead).
  `grep 'medo: notify' ~/.cache/noctalia/noctalia.log` shows each fire exactly once; a repeat tick
  adds nothing.

## Launcher capture (Phase 4b)

`medo buy milk @17:00 #errand !high` in the launcher adds a task to Today without opening the
panel. The parser is the pure `logic.parse_capture(text, now_ms, now_day)`; the provider
(`medo/quick.luau`) only renders the preview and sends the `add` command the panel would send.

| token | meaning |
| --- | --- |
| `@HH:MM` | next occurrence of that wall clock: today if still ahead, else tomorrow |
| `@tomorrow` | that day at 09:00 (a day token has to remind at a civilised hour) |
| `@mon` … `@sun` (or full names) | next occurrence **strictly after** the logical day, so `@mon` typed on a Monday means the coming Monday, at 09:00 |
| `#tag` | free-form tag, last one wins |
| `!low` `!med` `!high` | priority, case-insensitive, last one wins |

A day token and a clock combine in either order (`@tomorrow @17:00` = `@17:00 @tomorrow`). Every
word that is not a valid token stays in the title, so `@25:00`, `!urgent` or a bare `#` degrade
into text instead of failing; a query that is only tokens has an empty title and the provider
answers with a hint instead of adding anything.

The launcher provider is **not IPC-addressable** (only widget, panel and service entries are), so
verify it through the real surface:

```bash
noctalia msg panel-open launcher "/medo buy milk @17:00 #errand !high"   # prefilled query
grim docs/screenshots/phase4-launcher.png                                # result row + preview
wtype -k Return                                                          # activate
noctalia msg plugin goutamsharma/medo:core all debug-dump                # or read tasks.json
```

`wtype` types into the launcher the way a keyboard does, and Enter activates the highlighted
result; there is no pointer injection on this machine, so a click on the row is not verifiable.
Activation toasts `Sold. "buy milk" is on today's list.` and calls `launcher.setQuery("")`, which
resets the input to the provider root (`/medo`) instead of closing the launcher.

## Bar widget (post-5b)

The bar reads the published view and never writes. Left-click toggles the panel on Today;
right-click opens it on **Pending**.

- **Right-click context.** API 43's `noctalia.togglePanel(panelId)` takes no context argument, so
  the bar writes `panel_context = "pending"` to shared state immediately before toggling, and the
  panel's `onOpen` consumes it once and clears it. A left-click clears any stale value first.
- **Testing without a pointer.** `onRightClick` and `onIpc("pending")` share the same
  `open_pending()` function, so the gesture path can be exercised from the CLI:
  `noctalia msg plugin goutamsharma/medo:bar all pending`. That verifies the state handoff; the
  physical right-click itself is still unverifiable here.
- **Widget settings** (Noctalia widget settings): `glyph`, `show_count` and `show_mascot_dot`.
  The last two default to on. Hiding both falls back to the count — `logic.bar_visibility` encodes
  that rule and is unit-tested. Change them with `noctalia msg config-set widget.medo.show_count
  false` followed by `noctalia msg config-reload`.
- **Tooltip** rows are built in `bar.luau` from `logic.next_due_tooltip` (countdown + title) and
  dropped when nothing is due. Hover cannot be injected, so verify the content through the unit
  tests and the widget's `medo bar tooltip next due:` log line.
- **Screenshots**: the bar auto-hides over a tiled/fullscreen window (`smart_auto_hide`). Focus an
  empty workspace first (`niri msg action focus-workspace 2`), then `grim -g "0,0 1920x48"` and crop
  the left capsule. A screenshot taken over a window captures that window's toolbar, not the bar.

## Text, translations and the copy contract (Phase 5b)

Every user-visible string lives in `medo/translations/en.json` (flat dotted keys) and is resolved
with `noctalia.tr(key, subst)` — `{name}` placeholders — or `noctalia.trp(key, count, subst)` for a
plural pair (`<key>.one` / `<key>.other`, with `{count}` also available).

The rule that keeps `logic.luau` host-free: **the pure layer never builds a sentence.** It returns
a copy *key* plus its numbers, and the entry translates:

| pure output | rendered by |
| --- | --- |
| `notifications()` → `{ body_key = "notify.morning", subst = { planned, carried } }` | `core.luau` |
| `insights()` → `{ key = "insight.carryover", plural = 1, subst = { … } }` | panel (`trp`) and `report_markdown` (via the translator core passes in) |
| `celebration()` → `{ headline_key, line_key, subst = { done, total } }` | panel |
| `triage_summary()` → `{ copy_key, subst = { count } }` | panel |

`tools/check_manifest.py` (`make manifest`) now scans `medo/**/*.luau` for anything that looks like
a translation key and fails when it is missing from `en.json`; `trp` keys must have both plural
forms. That is the guardrail — a typo'd key is a red CI, not a screen full of `panel.foo.bar`.
Known exceptions, deliberately left in English: exported Markdown/JSON documents, debug IPC toasts
and log lines.

Adding a language is a new `translations/<lang>.json`; no code change.

## Trash (Phase 5a)

`view.trash_tasks` is a list of `{ task, deleted_ms, days_left }`, newest deletion first. The panel
sends `restore`, `purge` or `empty-trash`; the service is still the only writer, and rollover is
still the only *automatic* purge.

- `logic.trash_days_left(deleted_ms, now_ms, retention_days)` is `ceil(retention − age)`, so a fresh
  delete shows the full window and `0` means "goes at the next rollover". `logic.purge_trash` only
  removes entries **past** the window, so the countdown and the purge agree at the boundary
  (both directions are unit-tested).
- **Restore** keeps the progress the task had and appends it to Today (`order = #tasks + 1`), so a
  restore never rewrites what was already planned. **Delete forever** removes the row and has no
  per-row undo; the rollover `tasks.json.bak` generations are the only safety net.
- Five tabs share the 460 px panel, so the strip uses a 10 px face and the dashboard tab reads
  **`Stats`** — "Dashboard" clipped at this width, "Pending 1"/"Reports" did not (measured on
  5.4.1, not guessed).
- `debug-seed-trash` adds three rows aged 0/3/27 days for the countdown screenshot.

## Assets, sound and the celebration (Phase 4c)

```
medo/assets/
├── fonts/Baloo2-SemiBold.ttf  + OFL.txt   SIL OFL 1.1, static weight 600 instance
├── mascot/{sleepy,focused,proud,worried}.svg   hand-written source, 64-unit viewBox
├── mascot/{sleepy,focused,proud,worried}.png   rasterised at 128 px (2×)
└── sounds/{chime,jingle,thud}.ogg              0.50 s / 0.74 s / 0.28 s, synthesised
```

`./tools/gen-assets.sh` rebuilds everything from those sources (needs `curl`, `ffmpeg` with
libvorbis, and ImageMagick with an SVG delegate); `--all` forces a fresh font download. The PNGs
and OGGs are committed so a clone ships complete — only the SVGs are hand-edited.

- **Font** — `noctalia.loadFont("assets/fonts/Baloo2-SemiBold.ttf")` returns the family **`Baloo 2`**
  (not the file name). The panel uses it for the title, the big numbers and the celebration copy;
  `fontFamily = nil` silently falls back to the shell font, so a missing file is not an error.
- **Mascot** — `ui.image` takes the plugin-relative path. The panel checks `noctalia.fileExists`
  once per file and falls back to the text face when `mascot_enabled = false` or the PNG is
  missing. `logic.mascot_face(mood, carried)` picks one of the four: proud for 70 %+ and for the
  celebration, focused for 25–69 %, worried when a slow day has carried leftovers, sleepy otherwise.
- **Sound** — names are scoped to **one entry runtime**, so the service loads and plays the cues;
  a panel could not play a name it did not load itself. A task reaching 100 % plays the chime, the
  task that finishes the list plays the jingle *instead* (never both), delete plays the thud, and
  `sounds_enabled = false` skips playback (the files still load). Proof:
  `grep 'sound "jingle"' ~/.cache/noctalia/noctalia.log`.
- **Celebration** — the first state where every task is done stamps `view.celebrate_until`
  (now + 8 s). The service clears the stamp on its next tick and republishes, which is what
  dismisses the card on every open surface; the panel also asks for one-second ticks while the
  card is up, but a panel tick is not guaranteed on 5.4.1 (measured: `setWantsSecondTicks` alone
  did not drive `update()`). There are no animations at API 43, so it is a static card.
  `debug-complete-all` is the seam for the screenshot; a click cannot be injected here, so
  "Back to the list" was verified by code path only.
- **Triage** — `panel-open … triage` renders unfinished Today + Pending with Retry (promote to
  Today), Park (Pending) and Drop (Trash). Notifications carry no action buttons, so the 21:00
  toast is the doorbell: the card is a context, meant to be opened from a niri bind such as
  `Mod+Alt+T`.

## Files

| File | Runs | Notes |
|---|---|---|
| `medo/plugin.toml` | — | manifest; entry ids, `plugin_api = 43`, panel size |
| `medo/core.luau` | service | owns `tasks.json`, rollover, reminders, reports, exports |
| `medo/store.luau` | store | tasks, history, notification state, backups, exports |
| `medo/bar.luau` | bar widget | renders `noctalia.state` view; click opens the panel |
| `medo/panel.luau` | panel | Today / Pending / Dashboard / Reports (Trash in Phase 5) |
| `medo/quick.luau` | launcher | `medo …` capture: previews the parsed fields and sends `add` |
| `medo/assets/` | — | bundled font, mascot PNGs and sound cues (see `tools/gen-assets.sh`) |
| `medo/translations/en.json` | — | every user-visible string: settings, panel, bar, launcher, notifications, insights |
