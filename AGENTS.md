# AGENTS.md

medo is a day-scoped task manager for **Noctalia v5** on niri: a Luau plugin that
persists tasks, closes the day at a configurable hour, carries leftovers into a
Pending list, and reports weekly/monthly efficiency.

**Current state: Phases 0–3 merged, Phase 4a merged** (reminders and notifications). Phase 4b/4c
(launcher capture, celebration/sounds/triage) and Phase 5 (Trash, i18n, packaging) are next.

## Read first

| File | Why |
| --- | --- |
| [`docs/PLAN.md`](docs/PLAN.md) | The contract: 22 locked decisions, schema, scoring, build phases, open defaults |
| [`docs/DEV.md`](docs/DEV.md) | Dev source, IPC seams, data layout, gotchas that cost hours |
| `.ref/official-plugins/noctalia.d.luau` | The plugin API stub — the only authoritative prop list |
| `~/.cache/noctalia/noctalia.log` | What the shell actually did |

If a change contradicts `PLAN.md`'s decision table, don't make it — or amend the
table in the same PR with the reason. Silent drift is not acceptable.

## Commands

```sh
make check       # the PR gate: manifest + translations, Luau compile, unit tests
make tools       # fetch the pinned Luau toolchain into .tools/ (only on a fresh clone)
make test        # TZ=UTC .tools/luau tests/logic_test.luau
make manifest    # tools/check_manifest.py
make luau        # compile every medo/*.luau
make lint        # noctalia plugins lint medo (needs the running shell)
```

Shell/dev loop:

```sh
noctalia msg plugins list | grep medo              # state + version
noctalia msg config-reload                         # after plugin.toml changes
noctalia plugins lint medo                         # manifest/code cross-check
noctalia msg panel-open goutamsharma/medo:panel    # add | pending | edit:<id>
noctalia msg plugin goutamsharma/medo:core all ping
noctalia msg plugin goutamsharma/medo:core all debug-seed-demo
noctalia msg plugin goutamsharma/medo:core all debug-seed-report
noctalia msg plugin goutamsharma/medo:core all debug-rollover
noctalia msg plugin goutamsharma/medo:core all debug-report weekly
noctalia msg plugin goutamsharma/medo:core all debug-export weekly
noctalia msg plugin goutamsharma/medo:core all debug-tick 08:00
noctalia msg plugin goutamsharma/medo:core all debug-notify weekly
noctalia msg plugin goutamsharma/medo:core all debug-reset-state
noctalia msg plugin goutamsharma/medo:core all debug-dump
grep -iE 'medo|ERR|luau' ~/.cache/noctalia/noctalia.log | tail -20
```

Installed niri binds: `Mod+Shift+M` captures a task (panel opens on the add field),
`Mod+Alt+M` opens the panel.

## Layout and ownership

```
medo/plugin.toml     manifest: id goutamsharma/medo, plugin_api 43, entries, settings
medo/core.luau       [[service]] — owns the document, the logical day, rollover, reminders, commands
medo/store.luau      the ONLY module that touches disk (tasks, history, state, backups, exports)
medo/logic.luau      pure rules: dates, score, snapshot, rollover, streaks, reports, insights, notifications
medo/panel.luau      [[panel]] — Today/Pending/Dashboard/Reports UI; writes nothing, sends commands
medo/bar.luau        [[widget]] — done/total from the shared view
medo/translations/   settings labels (label_key must resolve here)
tests/logic_test.luau  headless tests for logic.luau
tools/check_manifest.py  stdlib validator used by `make check`
docs/                PLAN.md (contract), DEV.md (workflow), screenshots/
```

Rules that keep it sane:

- **Only `core.luau` mutates state**, and only through `store.save`. The panel and
  launcher send intents on `noctalia.state["cmd"]` (`kind`, `rev`, fields); the
  service applies, persists, and republishes `view`. Never write files from an
  entry other than the service.
- **`logic.luau` must stay host-free** (no `noctalia.*`, no file access) so tests
  can load it with plain Luau. Anything clock- or disk-shaped belongs in
  `core.luau`/`store.luau`.
- `store.luau` writes atomically: encode → `.tmp` → rotate current to `.bak` →
  rename. Don't bypass it, and don't put data in `pluginDir()`.

## Platform constraints (verified on this machine)

- Noctalia **5.4.1** → `plugin_api` ceiling **43**. API 44+ is unreleased and the
  shell rejects it. `tools/check_manifest.py` enforces the ceiling.
- A `path` plugin source requires the plugin directory to be named after the id
  suffix (`medo/`). A mismatch fails with a misleading
  `parse error: File could not be opened for reading`.
- Declarative UI has **no animations**, notifications carry **no action buttons**,
  and prop lists are exhaustive per API level — unknown props are skipped silently.
- Colour roles at 43: `surface_container`, `surface_container_high`,
  `primary_container`, `outline_variant`, … `surface_variant` is retired.
- **In-panel keyboard shortcuts do not exist by design.** Panels take keyboard
  focus on demand and inputs swallow printable keys; `capture_keys`/`onKey` were
  removed after they proved unreachable. The keyboard path is the add field plus
  niri binds — do not rebuild shortcuts.
- There is **no pointer injection** tool (wtype is keyboard-only, xdotool is X11).
  Verify UI through rendered screenshots, panel contexts, and service IPC; never
  claim a click or a slider drag was tested.

## Data

`noctalia.pluginDataDir()` → `~/.local/state/noctalia/plugins/data/goutamsharma/medo/`

```
tasks.json         live document (schema 1): day, rollover_hour, carried_in,
                   streak, tasks[], trash[]
tasks.json.bak     previous generation, used when tasks.json is unreadable
history.json       one aggregate snapshot per closed day (see PLAN §5)
state.json         notification dedupe: day + notified keys (Phase 4a)
backups/           tasks-<day>.json, newest 14, written at each rollover
```

Reset for a clean run: disable the plugin, remove that directory (needs one
escalated write outside the workspace), re-enable. Leave the user's real list
empty when you finish testing.

## Testing

- `make test` runs `tests/logic_test.luau` under `TZ=UTC`; keep expectations
  timezone-independent by using the `local_ms()` helper in the test file.
- Prefer pure functions in `logic.luau` for anything worth asserting; add tests in
  the same PR.
- For behaviour that needs the shell: seed with `debug-seed-demo`, drive state
  transitions with IPC, and verify with `debug-dump` plus the JSON on disk.
- Panel screenshots: fullscreen windows hide layer panels — switch to an empty
  workspace (`niri msg action focus-workspace 2`), open the panel, `grim`, then
  return. Crop with `magick`.
- Known unverifiable here: mouse clicks, slider drags, and real 04:00 firing
  (the rollover code path is exercised through `debug-rollover` instead).

## Repo rules

- Trunk-based: `main` is protected (PR required, `check` required, admins
  enforced, no force-push/deletion). Never push to `main`.
- Branch `type/scope`: `feat/`, `fix/`, `chore/`, `docs/`. Squash-merge, delete.
- Conventional Commits; subject ≤ 72 chars, imperative; body explains *why*.
- PR body: `# Why`, `# What changed`, `# Validation and proof` (check → command →
  actual result), `# Risk and rollback`. Screenshots for UI work. State plainly
  what was **not** verified.
- Update `docs/PLAN.md` progress, `docs/DEV.md` and `README.md` when behaviour or
  workflow changes.
- CI is `.github/workflows/ci.yml` (job `check`, pinned Luau 0.746). It runs the
  same `make check` you run locally — green locally means green there.

## Sandbox notes (this machine)

- The session is workspace-write: writes to `~/.local`, `~/.config` or the plugin
  data dir need one `danger-full-access` escalation with a justification.
- Back up user files into `.backup/` (gitignored) before editing them; the niri
  config backup convention is `.backup/niri-config.kdl.<date>`, and edits are
  validated with `niri validate` (niri reloads the file itself).
- `.ref/` holds gitignored clones of the official/community plugin repos — useful
  reference, never commit it.
