# medo

A cute, day-scoped task manager for **Noctalia v5** on niri.

> The day closes itself: carry-overs are deliberate, progress is honest, and every week
> tells you how you actually worked.

**Status:** planning — the blueprint is locked in [docs/DESIGN.md](docs/DESIGN.md).
Implementation starts with Phase 0 (scaffold + dev install).

## What it does

- **Today / Pending / Dashboard / Reports / Trash** — three lists that carry the whole day.
- **Progress that means something** — a per-task 0–100 % slider (100 % = done) and an
  effort-weighted daily score, so a 2-hour task counts more than three one-minute ticks.
- **04:00 rollover with a human decision** — leftovers land in Pending with a `carried ×N`
  badge, and a 21:00 triage lets you retry, park or drop instead of letting a backlog rot.
- **Weekly and monthly reports** — completion, carryover, on-time rate, average progress at
  close, streaks, plus rule-based "what to improve" lines.
- **Reminders and digests** — morning plan, due-time and lead-time nudges, at-risk ping,
  weekly report toast, all quiet-hours aware.
- **Capture from the launcher** — `medo buy milk @17:00 #errand !high`.
- **A blob on the bar** — `2/5` plus Medo, who has opinions about your day.

## Layout

```
plugin/     the Noctalia plugin (Luau): manifest, service, panel, bar widget, launcher provider
docs/       DESIGN.md (blueprint) · DEV.md (dev source + testing, arrives with Phase 0)
tools/      asset generation (mascot, sounds) and validation
```

## Requirements

- Noctalia **5.4.1+** — medo targets `plugin_api = 43`
- niri (or any compositor Noctalia supports)
- Fedora 44 is the reference machine

## Install

Not published yet. Development install instructions land in `docs/DEV.md` with Phase 0.

## License

TBD.
