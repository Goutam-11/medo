# AGENTS.md

medo is a day-scoped task manager for **Noctalia v5** on niri: a Luau plugin that
persists tasks, closes the day at a configurable hour, carries leftovers into a
Pending list, and reports weekly/monthly efficiency.

**Current state (2026-11-13): `main` @ `f6931aa` is `0.2.0` and Phases 0–5b are complete** — the
plugin is enabled in the running shell. No Phase 6 is planned: seven small, independent gaps are
tracked as issues #24–#30 (panel promises, bar polish, week start, import, repeats, licence, the
0.2.0 release). Every branch is cut from `main`; never merge a PR into a feature branch.

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
noctalia msg panel-open goutamsharma/medo:panel    # add | pending | edit:<id> | dashboard | reports
noctalia msg panel-open goutamsharma/medo:panel triage   # the 21:00 decision card
noctalia msg panel-open launcher "/medo buy milk @17:00" # launcher capture (no IPC of its own)
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
noctalia msg plugin goutamsharma/medo:core all debug-complete-all   # celebration card
noctalia msg plugin goutamsharma/medo:core all debug-seed-trash      # 3 trash rows, 0/3/27 days
noctalia msg plugin goutamsharma/medo:core all empty-trash
grep -iE 'medo|ERR|luau' ~/.cache/noctalia/noctalia.log | tail -20
```

Installed niri binds: `Mod+Shift+M` captures a task (panel opens on the add field),
`Mod+Alt+M` opens the panel. Global shortcuts are the compositor's job — the panel has none by
design (decision 16).

## Layout and ownership

```
medo/plugin.toml     manifest: id goutamsharma/medo, plugin_api 43, entries, settings
medo/core.luau       [[service]] — owns the document, the logical day, rollover, reminders, sounds, commands
medo/store.luau      the ONLY module that touches disk (tasks, history, state, backups, exports)
medo/logic.luau      pure rules: dates, score, rollover, streaks, reports, insights, capture, notification keys
medo/panel.luau      [[panel]] — Today/Pending/Stats/Reports/Trash + triage/celebration; writes nothing
medo/bar.luau        [[widget]] — done/total from the shared view
medo/quick.luau      [[launcher_provider]] — `medo …` capture; sends the same `add` command
medo/assets/         bundled font (+OFL), mascot SVG/PNG, sound cues — rebuilt by tools/gen-assets.sh
medo/translations/   en.json: every user-visible string (tr/trp keys; checked by make manifest)
tests/logic_test.luau  headless tests for logic.luau
tools/check_manifest.py  stdlib validator used by `make check` (manifest + translation keys)
tools/gen-assets.sh      font download, SVG→PNG rasterisation, ogg synthesis
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
- **Copy is data**: no user-visible English in `.luau` files. Strings live in
  `translations/en.json`; `logic.luau` returns copy *keys* plus their numbers
  (`body_key`/`key`/`copy_key`/`headline_key`, plus a `plural` count for `trp`)
  and the entry translates. `make manifest` fails when a key is missing.
  Exceptions: exported Markdown/JSON and debug/log text.
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
- **Sound names are scoped to one entry runtime**, so only the service can load and
  play `assets/sounds/*.ogg`; `noctalia.loadFont` returns the family name
  (`Baloo 2` for the bundled SemiBold), not the file name.
- **A panel tick is not guaranteed**: `setWantsSecondTicks` alone did not drive
  `update()` on 5.4.1. A timer that must fire (the 8 s celebration) is cleared by
  the service and republished, not by a panel timer.
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
- PR body follows [`.github/pull_request_template.md`](.github/pull_request_template.md):
  `# Why`, `# What changed`, `# Visuals` (one mermaid diagram), `# Validation and proof`
  (check → command → actual result), `# UI proof` (screenshots **embedded**, not linked
  as paths), `# Risk and rollback`, checklist. State plainly what was **not** verified.
- Stacked PRs: `Closes #N` only auto-closes on the **default branch**, so retarget each
  PR to `main` before merging it. A PR merged into a feature branch lands nowhere.
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
