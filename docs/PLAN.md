# medo — plan

A cute, day-scoped task manager for **Noctalia v5** on niri. Planned via a 22-question
grilling session on 2026-11-12.

**One-liner:** medo closes your day for you — carry-overs are deliberate, progress is honest,
and every week tells you how you actually worked.

---

## 1. Decisions (locked)

| # | Decision | Choice |
|---|---|---|
| 1 | Platform | Upgrade to **Noctalia 5.4.1**, target **`plugin_api = 43`** (44–53 are unreleased) |
| 2 | Entry points | `[[service]]` + `[[widget]]` + `[[panel]]` + `[[launcher_provider]]` |
| 3 | Data | `noctalia.pluginDataDir()` JSON + export/import |
| 4 | Day boundary | Configurable rollover hour, **default 04:00** |
| 5 | Rollover | Auto-carry → Pending with `carried ×N`, plus **21:00 evening triage** |
| 6 | Progress | Per-task slider 0–100 %, **100 % = done**, daily score weighted by estimate |
| 7 | Look | Noctalia palette (M3 roles) + rounded sticker cards + **Medo blob mascot** |
| 8 | Tabs | Today / Pending / Dashboard / Reports / Trash |
| 9 | Task fields | title, estimate, due time, priority, notes, tags |
| 10 | Time model | Due time + reminder lead offsets (no blocks, no timers) |
| 11 | Notifications | All six: evening, morning, due, lead, at-risk, weekly |
| 12 | Daily cap | **Soft cap at 3**, top-3 get a focus badge, 4th+ asks "sure?" |
| 13 | Reports | Auto **Sun 20:00** weekly + **1st 20:00** monthly, Reports tab + toast |
| 14 | Carry-over | Keep progress %, badge how many times it was carried |
| 15 | Repeats | Daily / selected-weekdays, recreated at rollover |
| 16 | Keyboard | Full keyboard-first panel |
| 17 | Metrics | Effort-weighted score + carryover + on-time + avg progress at close + insights |
| 18 | Trash | Soft delete, restore anytime, auto-purge after 30 days |
| 19 | Pending | Pending = carried tasks needing a decision + parked (someday) tasks |
| 20 | Bar widget | `done/total` + small Medo glyph, tooltip = next due task |
| 21 | Quick add | Launcher provider with inline tokens: `medo buy milk @17:00 #errand !high` |
| 22 | Packaging | Local now, publish-ready structure (`translations/en.json`, README, validator-clean) |

---

## 2. Platform constraints that shaped the design

Verified against the installed shell, the plugin docs (v5.4.1) and the official plugin API stub.

- **Plugin API 43** is the ceiling on 5.4.1. Anything from 44 up (palette format 2, `onSuspend`,
  media player, nightlight…) is "unreleased" and will be **rejected**.
- **No animations or transitions** exist in the declarative UI. "Cute" must come from rounded
  shapes, a mascot image, playful copy, colour roles and sound. The "celebration" is a static
  card + jingle, not confetti physics.
- **Notifications carry no action buttons** (`noctalia.notify(title, body)` only). Triage must
  therefore open the panel; the toast is the doorbell, not the menu.
- **Panels can auto-size** (`height = "content"`, API 42) with `max_height` — the list can grow
  without a fixed-height void.
- **`ui.progress` has a `marker`** on 5.4.1 (target line on the track) and **mouse-wheel adjusts
  plugin sliders** — both directly useful.
- **Keyboard**: `capture_keys` only delivers printable chords, and only while no `ui.input` has
  focus. `Escape` can never be captured; `Return` belongs to inputs. Shortcuts must degrade
  gracefully.
- **Assets**: `noctalia.loadFont()` registers a bundled TTF; `noctalia.sound.load()` +
  `sound.play()` play bundled `.ogg` (respects `[audio].sound_volume`); `ui.image` takes a local
  path — **PNG for the mascot**, since SVG rendering depends on Qt plugins we don't want to bet on.
- **`noctalia.pluginDataDir()`** is a per-plugin, owner-only (0700) directory that survives plugin
  updates. Never persist inside `pluginDir()` — git-installed plugins get their runtime copy
  rewritten on update.
- `noctalia.state` is shared across a plugin's entries but **memory-only**; the service re-reads
  disk on load.

---

## 3. Product model

### 3.1 The three lists

| List | Meaning | How tasks get there |
|---|---|---|
| **Today** | Committed for this logical day | Added today, promoted from Pending, "retry tomorrow" after triage, repeats |
| **Pending** | Awaiting a decision | Rollover without triage, deliberate park, "not today" |
| **Trash** | Soft-deleted | Delete action, triage "drop" |

Done tasks stay in Today with a strike-through and a completion time until rollover, then move to
history (not Trash).

### 3.2 The day

- A **logical day** is `now - rollover_hour`, so work at 01:30 still counts as "yesterday".
- Rollover runs on the first service tick after the boundary, so a sleeping laptop catches up
  exactly once (no matter how many days were missed).
- Rollover, in order:
  1. snapshot the closing day into `history.json` (or mark it `missed` if the shell was off),
  2. archive completed tasks (keep their completion time for on-time math),
  3. unfinished Today tasks → Pending with `carried = carried + 1`, progress preserved,
  4. recreate repeats that match the new day,
  5. purge Trash older than 30 days,
  6. write a dated backup of `tasks.json` (keep last 14),
  7. recompute streak, publish the new view to the bar.

### 3.3 Evening triage (21:00, configurable)

The one place medo asks a question instead of guessing:

> **2 left today.** Retry tomorrow, park, or drop?

- **Retry** → stays committed, appears in tomorrow's Today with `carried ×1`.
- **Park** → Pending, no due date, visible in the morning digest.
- **Drop** → Trash.
- Ignore it → rollover puts everything in Pending (the safe default). Nothing is ever silently
  deleted, and nothing silently rots into an invisible backlog — Pending shows up in the morning
  digest with a count and a badge.

### 3.4 Soft cap

Adding a 4th task today shows an inline "Today already has 3 — add anyway?" with the top three
marked ⭐. The cap is advisory, never blocking, and is a setting.

### 3.5 Celebration

When every task reaches 100 %: panel swaps to a celebration card (proud Medo, `Nothing left on
the list. Go touch grass.` / `4/4. Medo is doing a little dance.`), plays the jingle, and settles
back after ~8 s or on any click.

---

## 4. Architecture

```
                    ┌──────────────────────────────┐
                    │  [[service]] core.luau        │   single writer
                    │  tick 1s: rollover, reminders │
                    │  events: commands from others │
                    └──────────┬───────────────────┘
                               │ read/write
                     ~/.local/state/noctalia/plugin-data/goutamsharma/medo/
                       tasks.json · history.json · state.json · backups/
                               │
        noctalia.state.set("view", …)  ← shared, in-memory, per plugin
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   [[widget]] bar.luau   [[panel]] panel.luau   [[launcher_provider]] quick.luau
   done/total + glyph     five tabs, slider     inline-token capture
```

**Rules**

1. Only the service writes data files. The panel and launcher send intents by calling
   `noctalia.state.set("cmd", { rev = nowMs(), kind = “…”, … })`; the service watches `cmd` and
   applies it. The widget and panel render from `noctalia.state.get("view")`.
2. `rev` is monotonic (`nowMs()`), so reloads and duplicate deliveries are idempotent.
3. **Fallback** if cross-entry `state.watch` proves unreliable during Phase 1: the panel appends a
   command to `outbox.json` and the service drains it each tick. Same payloads, one file hop.
4. Writes are **atomic**: write `tasks.json.tmp`, then `renameFile()`. A crash never leaves a
   half-written day.
5. Every entry can be poked over IPC for development:
   `noctalia msg plugin goutamsharma/medo:core all debug-rollover`.

### 4.1 Entries and ids

| Entry | id | Address |
|---|---|---|
| service | `core` | `goutamsharma/medo:core` |
| bar widget | `bar` | `goutamsharma/medo:bar` |
| panel | `panel` | `goutamsharma/medo:panel` (width 460, `height = "content"`, `max_height = 760`, `attached`) |
| launcher provider | `quick` | prefix `medo`, `include_in_global_search = false` |

---

## 5. Data model (schema v1)

### `tasks.json`

```json
{
  "schema": 1,
  "revision": 145,
  "day": "2026-11-12",
  "streak": { "current": 6, "best": 14, "last_counted_day": "2026-11-11" },
  "tasks": [
    {
      "id": "t_1763k9_a1b2",
      "title": "Finish medo blueprint",
      "notes": "",
      "tag": "work",
      "priority": "high",
      "estimate_min": 45,
      "due_ms": 1762956000000,
      "lead_min": 15,
      "progress": 40,
      "carried": 1,
      "recurrence": null,
      "status": "today",
      "order": 0,
      "created_ms": 1762900000000,
      "completed_ms": null
    }
  ],
  "trash": [
    { "task": { "...": "..." }, "deleted_ms": 1762900000000 }
  ]
}
```

- `status`: `today` | `pending` | `done` (done until rollover archives it)
- `recurrence`: `null` | `{ "kind": "daily" }` | `{ "kind": "weekdays", "days": [1,3,5] }`
  (1 = Monday, matching `os.date("*t")`)
- `priority`: `low` | `med` | `high` → weight multiplier 1 / 1.5 / 2 **only when no estimate**
- `due_ms` is wall-clock epoch ms, same base as `noctalia.nowMs()`; a due date on another day is
  allowed (shown as `Fri 14:00`)
- ids are `t_<base36 time>_<4 random hex>` — stable across edits, no counters

### `history.json`

```json
{ "schema": 1, "days": [
  { "day": "2026-11-11", "assigned": 5, "done": 3, "carried_in": 2,
    "score": 61, "effort_assigned": 180, "effort_done": 105,
    "on_time": 2, "on_time_total": 3, "avg_progress": 64,
    "top3_done": 2, "by_tag": { "work": 3, "life": 1 },
    "closed": "ok" }
]}
```

`closed`: `ok` | `missed` (shell was off at the boundary — recorded as a gap, never invented).

### `state.json` (volatile-ish, service-owned)

```json
{ "day": "2026-11-12", "last_tick_ms": 0, "notified": { "due:t_…": 176…, "evening": "2026-11-12" } }
```

Dedupe keys stop restarts from re-firing the same toast.

---

## 6. Scoring, streaks, reports

### 6.1 Weights and the daily score

```
weight(task)  = estimate_min > 0 ? estimate_min : (default_estimate × priority_multiplier)
score(day)    = round(100 × Σ(progress/100 × weight) / Σ weight)   over tasks assigned that day
```

- The score is **live** (updates as you drag sliders) and frozen into history at rollover.
- `effort_done`/`effort_assigned` are the same sums unnormalised (minutes of planned work).
- **On-time**: task had `due_ms` and `completed_ms ≤ due_ms`; `on_time_total` counts only tasks
  that had a deadline.
- **Avg progress at close**: mean progress of tasks that were not finished when the day closed —
  this is the "almost" number that tells you whether tasks are too big.
- **Streak**: consecutive closed days with `score ≥ streak_threshold` (default 70) and ≥ 1 task
  assigned. A `missed` day breaks it.

### 6.2 Weekly report (Sunday 20:00)

- Header: score, tasks done/assigned, carried, on-time %, streak.
- Seven-day bar chart (`ui.graph`, one bar per day), effort-weighted.
- Best/worst day, by-tag split, top-3 hit rate.
- **Insights** — deterministic rules, no AI, each with its supporting number:
  | Rule | Copy (example) |
  |---|---|
  | carryover > 30 % | `You carried 11 of 24 tasks. Your plan was ~2 tasks too ambitious — cap it at 3.` |
  | due tasks > 20 % more likely done | `Tasks with a due time finish 24 % more often. Give the big ones a time.` |
  | avg progress at close > 55 % | `You stop at ~60 % a lot — those tasks are too big. Split anything over 45 min.` |
  | best weekday | `Tuesdays are your power day. Schedule the scary task there.` |
  | streak broken | `Wednesday broke a 6-day streak at 2 tasks left.` |
  | zero insights | `A steady week. Nothing to improve — suspiciously good.` |

### 6.3 Monthly report (1st, 20:00)

Same metrics aggregated, plus: trend vs previous month, week-by-week table, top tags, total
planned vs completed effort, longest streak, and a "what changed" line. Export as Markdown.

---

## 7. Interaction design

### 7.1 Bar widget

```
 ⬤ 2/5       ← Medo glyph (colour by score band) + done/total, tooltip: "3h 10m left · next 18:00 report"
```

- Click → toggle panel. Middle → settings (Noctalia default). Right-click → quick add input? (No —
  panel stays the capture surface; right-click opens Pending tab.)
- Colours: `on_surface_variant` when idle, `primary` while tasks remain, `tertiary` when all done.

### 7.2 Panel

```
┌──────────────────────────────────────────────────────────┐
│ ( ◕‿◕ )  Thursday, 12 Nov        [61%] 🔥6      ⚙  ✕    │  header, mascot line below
│  “five things. we eat them one at a time.”               │
├──────────────────────────────────────────────────────────┤
│  Today 2/5 │ Pending 3 │ Dashboard │ Reports │ Trash 1   │  tab strip w/ counts
├──────────────────────────────────────────────────────────┤
│  ⭐ Big 3                                                │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ● Finish medo blueprint      18:00   [▓▓▓▓░░] 40% │  │  slider inline
│  │ ● Review PR #42              —       [▓▓░░░░] 25% │  │
│  │ ○ Gym                        —       [░░░░░░]  0% │  │
│  └────────────────────────────────────────────────────┘  │
│  Other                                                   │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ○ Buy milk            17:00  carried ×2  [░░░] 0%  │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌ + add a task…              [45m] [17:00] [#work] ┐   │
│  └───────────────────────────────────────────────────┘   │
│  5 tasks · 3h 10m planned · 2 carried · 1 due soon       │
└──────────────────────────────────────────────────────────┘
```

- **Row**: priority dot, title (strike-through when done), due chip (red when overdue), carried
  badge, inline slider, completion check. Hover reveals edit / park / delete.
- **Slider**: 0–100 in steps of 5, wheel works, `onDragEnd` persists. Reaching 100 completes the
  row (strike, chime, moved to the done section) — dragging back below 100 un-completes.
- **Add row**: title input (`focus` on new), estimate select (15/30/45/60/90/…), time input,
  tag select, priority cycle. Enter adds, keeps focus for the next capture.
- **Keyboard**: `n` focus add, `/` filter, `j`/`k` move selection, `space` toggle done,
  `1`–`5` tabs, `w`/`s` ±5 % on the selected row, `e` edit, `Delete` trash. All best-effort
  (unavailable while an input is focused — documented in the panel footer hint).
- **Empty states** carry the voice:
  - Today empty → `Nothing planned yet. Three is a good number to start.`
  - Pending empty → `No leftovers. Medo is pleasantly surprised.`
  - Trash empty → `Nothing thrown away. Look at you.`
- **Overdue banner**: `2 tasks are late. Not judging. (a little.)`

### 7.3 Dashboard

- Score ring (large `ui.progress` + number, plus `marker` at today's target), streak, next due
  task with countdown, 7-day sparkline (`ui.graph`), carried-in count.
- Mascot reaction line tied to score: sleeping < 25, focused < 70, proud < 100, dancing at 100.

### 7.4 Reports

- Segmented Weekly / Monthly, date range label, metric tiles, chart, insights list, then
  `Export Markdown` / `Export JSON` writing into the configured export folder.
- Empty state: `Reports need a few closed days. Come back Sunday.`

### 7.5 Trash

- Rows with delete date and "auto-purge in N days", Restore, Delete forever.
- Footer: `Trash empties itself after 30 days.` (setting)

### 7.6 Launcher capture

```
medo buy milk @17:00 #errand !high
     └ title       └time  └tag   └priority
```

- Parsed tokens are shown as a subtitle preview before Enter; unparsed text stays in the title.
- `@tomorrow`, `@mon`, `@18:30` accepted for the date, `!low/!med/!high`, `#tag` free-form
  (autocompletes from existing tags in the subtitle).
- Result action: add to Today, toast `Sold. "buy milk" is on today's list.`; keeps the launcher
  open for the next task (`launcher.setQuery("")`).

---

## 8. Visual system

- **Palette (API 43 roles only)**: `surface`, `surface_container`, `surface_container_high`,
  `primary`, `primary_container`, `on_primary_container`, `secondary`, `tertiary`, `error`,
  `outline_variant`, `on_surface`, `on_surface_variant`. No hard-coded hex except priority dots
  mapped to `error` / `tertiary` / `outline_variant`.
- **Shape**: 12–14 px radii on cards, 8 on chips, 2 px gaps inside groups, 10 px between groups.
- **Type**: bundled `Baloo 2 SemiBold` (OFL) for headers, mascot lines and big numbers; shell font
  for body so it always matches the desktop.
- **Mascot**: hand-drawn blob, 4 states — `sleepy`, `focused`, `proud`, `worried` — shipped as PNG
  at 2× (128 px) with an SVG source in `assets/mascot/`.
- **Sound**: `sounds/chime.ogg` (completion), `sounds/jingle.ogg` (all done), `sounds/thud.ogg`
  (delete/drop), synthesised with ffmpeg, short (< 0.8 s), low volume, toggle in settings.
- **Copy**: warm, gently teasing, never guilt-tripping. Never "You failed"; always "carried",
  "left over", "tomorrow".

---

## 9. Settings schema

| key | type | default | purpose |
|---|---|---|---|
| `rollover_hour` | int 0–23 | 4 | logical day boundary |
| `cap_enabled` | bool | true | soft cap on today's list |
| `daily_cap` | int 1–10 | 3 | the cap value |
| `default_estimate` | int | 20 | minutes, when a task has none |
| `lead_min` | int | 15 | default reminder lead |
| `notify_morning` / `evening` / `due` / `lead` / `weekly` / `monthly` / `atrisk` | bool | all true | per-notification toggles |
| `morning_time` / `evening_time` / `atrisk_time` | string `HH:MM` | 08:00 / 21:00 / 15:00 | schedule |
| `weekly_day` / `weekly_time` | select / string | Sunday / 20:00 | report cadence |
| `monthly_time` | string | 20:00 | report cadence (1st) |
| `week_start` | select | Monday | charts and ranges |
| `streak_threshold` | int 0–100 | 70 | score that keeps a streak |
| `quiet_start` / `quiet_end` | string | 22:00 / 07:00 | suppress non-due notifications |
| `sounds_enabled` | bool | true | chime/jingle/thud |
| `mascot_enabled` | bool | true | hide the blob if you want quiet |
| `export_dir` | folder | `$XDG_DOCUMENTS_DIR` (else `~/Documents`) | report/backup exports |
| `trash_days` | int 1–365 | 30 | auto-purge window |

Widget settings: `glyph` (default `checklist`), `show_count`, `show_mascot_dot`.

---

## 10. Notifications

| When | Copy | Notes |
|---|---|---|
| 08:00 | `Morning. 3 planned, 2 carried. Medo is ready.` | opens panel Today |
| due | `"Finish report" is due now (40 %).` | skipped if done |
| lead | `15 min to "Finish report".` | one per task |
| 15:00 | `Half the day gone, nothing moved. Still fine.` | only if score < 30 and work remains |
| 21:00 | `2 left. Retry, park or drop?` | opens panel on the triage card |
| Sun 20:00 | `Your week: 18 done, 6 carried, 71 %.` | opens Reports |
| 1st 20:00 | `October in review — 71 % efficiency.` | opens Reports |

Rules: quiet hours suppress everything except due alerts; dedupe keys in `state.json`; reminders
older than 60 min are dropped, not replayed after a suspend; at most one at-risk ping per day.

---

## 11. Files

```
medo/
├── medo/
│   ├── plugin.toml
│   ├── core.luau            service: store, rollover, reminders, reports, commands
│   ├── store.luau           schema, load/save, atomic writes, backups, migrations
│   ├── logic.luau           pure functions: day math, score, streak, insights, token parser
│   ├── panel.luau           panel: tabs, rows, slider, keyboard
│   ├── bar.luau             bar widget
│   ├── quick.luau           launcher provider
│   ├── assets/
│   │   ├── fonts/Baloo2-SemiBold.ttf (+ OFL.txt)
│   │   ├── mascot/{sleepy,focused,proud,worried}.png (+ .svg)
│   │   └── sounds/{chime,jingle,thud}.ogg
│   ├── translations/en.json
│   └── README.md
├── docs/
│   ├── PLAN.md              this file
│   └── DEV.md               dev source, IPC, testing
│   └── DEV.md               dev source setup, IPC cheat-sheet, testing
├── tools/
│   ├── gen-assets.sh        mascot rasterisation + sound synthesis
│   └── validate.sh          noctalia plugins lint + manifest checks
└── .ref/                    upstream reference clones (gitignored)
```

Pure logic in `logic.luau` is `require`-able and testable headlessly. `store.luau` owns every
write so the on-disk format has exactly one implementation.

**Noctalia plugin source** for development: add `~/personal-projects/medo/plugin` as a **path
source** (or drop into `~/.local/share/noctalia/plugins/goutamsharma/medo/`), enable once,
then `.luau` edits hot-reload. Writing outside the workspace needs one approval.

---

## 12. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A prop from a newer API is silently skipped | Implement against the **43-era stub**; run `noctalia plugins lint`; grep the shell log for skipped/invalid props each phase |
| `ui.image` can't render SVG | Ship rasterised PNGs at 2×; keep SVG as the editable source |
| Cross-entry `state.watch` isn't reliable for panel→service | Phase 1 fallback: `outbox.json` drained by the service each tick |
| Panel loses keyboard shortcuts once an input gets focus | Documented hint row; `/` and `n` re-focus inputs, mouse always works |
| Clock jumps, suspend/resume (no `onSuspend` at 43) | Every tick recomputes the logical day and reminder windows from `nowMs()`; stale reminders expire after 60 min |
| Corrupted or half-written JSON | Atomic tmp+rename, schema version field, `.bak` restore path, backups kept 14 rollovers |
| Panel height jumps while dragging a slider | `max_height` + inner `ui.scroll` for long lists |
| Re-firing toasts after a plugin reload | Dedupe keys persisted in `state.json` |
| Repeats duplicate after a missed rollover | Recreate at most once per new day; skip if an unfinished instance exists |
| Carried tasks pile up invisibly | Pending shows a count badge on the bar tab, morning digest names the count, badges show `×N` |

---

## 13. Build plan

| Phase | Scope | Acceptance |
|---|---|---|
| **0. Scaffold** | manifest, four entries, dev source, hello-world bar widget | shell accepts `plugin_api = 43`; widget renders; IPC pokes work; log clean |
| **1. Store + core** | `store.luau`, `logic.luau`, service commands, persistence, atomic writes, backups | tasks survive reload; `debug-rollover` advances the day correctly with a seeded fixture |
| **2. Panel: Today + Pending** | add/edit/park/delete/reorder, slider, completion, keyboard, cap prompt | CRUD round-trips through the service; slider persists; done section behaves |
| **3. Dashboard + Reports** | score, streak, sparkline, weekly/monthly, history snapshots, export | numbers match a hand-checked fixture; report renders with no history gracefully |
| **4. Life** | notifications, launcher capture, celebration, sounds, mascot assets, triage card | each notification fires once at the right local time; `medo …@17:00` parses |
| **5. Polish** | Trash tab, i18n, README, validator, packaging notes | `noctalia plugins lint` clean; community-ready layout |

**Progress:** Phase 0 complete (2026-11-12) — the plugin loads on Noctalia 5.4.1, the bar shows
`0/0`, and the panel opens. Evidence: `docs/screenshots/phase0-*.png`.

Phase 1 complete (2026-11-12) — the store persists across plugin restarts, the logical day rolls
over at the configured hour (including catch-up after downtime), unfinished tasks carry into
Pending with a `carried` counter, repeats are recreated, history and 14 backups are written, and
52 unit tests cover the pure logic. Evidence: `docs/screenshots/phase1-panel.png`.

Phase 2 complete (2026-11-12) — Today and Pending render with inline progress sliders, capture
with estimate/time/tag, inline editing (title, estimate, due, tag, priority, notes), park/promote,
delete to Trash and the soft-cap prompt. The panel talks to the service only through
`noctalia.state["cmd"]`. Keyboard is capture-first (the add field takes focus on open); in-panel shortcuts were
removed because panels only take keyboard focus on demand and inputs swallow printable keys —
global shortcuts belong in niri instead.
Evidence: `docs/screenshots/phase2-{today,pending,editor}.png`.

Phase 3 complete (2026-11-12) — Dashboard and Reports ship. The dashboard has a large score
card (a `ui.progress` with a `marker` at the streak target — Noctalia has no ring primitive), the
streak, next-due task with countdown, carried-in count, a 7-day `ui.graph` sparkline and a mascot
line in four score bands. Reports switch weekly/monthly, aggregate `history.json` plus the live day
(effort-weighted score, carryover, on-time, average progress at close, best/worst day, tag split)
and render deterministic insights; the per-day chart prints the exact score under each point
because the 5.4.1 `ui.graph` smooths its samples. Export writes `medo-<period>-<end>.md|json` into
`export_dir`. Pure logic grew to 174 unit tests (from 56), including a hand-computed two-period
fixture with exact insight copy.
Evidence: `docs/screenshots/phase3-{dashboard,reports-weekly,reports-monthly,reports-empty}.png`.

Phase 4a complete (2026-11-12) — the reminder scheduler: all sixteen notification settings, the
`state.json` dedupe file, the pure decision in `logic.luau` (60-minute catch-up window, quiet
hours that exempt due alerts, at-risk once per day, per-task lead overrides), and the 08:00
morning, 15:00 at-risk, 21:00 evening, due, lead, weekly and monthly toasts. The service applies
the list and persists each key so a restart never repeats a toast. `debug-tick`, `debug-notify`,
`debug-clock-clear` and `debug-reset-state` make the whole thing testable without waiting for the
clock. Pure logic grew to 226 tests. Evidence: `docs/screenshots/phase4-{evening,weekly-toast,atrisk-toast}.png`.

Each phase ends with: reload the plugin, verify in the running shell, check the log, and a note in
`docs/DEV.md`.

---

## 14. Open micro-decisions (defaults I'll take unless you object)

1. Streak counts a day at **score ≥ 70** (setting exists).
2. Week starts **Monday** in charts and weekly ranges.
3. Monthly report fires the **1st at 20:00**; weekly on **Sunday 20:00**.
4. Done tasks stay visible in Today until rollover (struck through, collapsible group).
5. Tags are free-form, suggestions come from existing tags; no fixed taxonomy.
6. Estimate is optional; without one, weight falls back to priority × 20 min.
7. Reports export **Markdown** by default, JSON on request.
8. Trash purge runs **at rollover**, not hourly.
9. No cloud sync, no multi-device, no time-tracking in v1.
10. The plugin id is `goutamsharma/medo` — rename before publishing if you prefer another handle.
