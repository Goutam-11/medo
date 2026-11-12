--!nonstrict
-- Unit tests for medo/logic.luau. Run with TZ=UTC (make test does) so date
-- expectations are stable on any machine.

local logic = require("../medo/logic")

local passed, failed = 0, 0

local function eq(name, got, want)
  passed = passed + 1
  if got ~= want then
    failed = failed + 1
    print(string.format("FAIL %-38s got=%s want=%s", name, tostring(got), tostring(want)))
  end
end

-- ── civil dates ─────────────────────────────────────────────────────────────

eq("ordinal epoch", logic.to_ordinal("1970-01-01"), 0)
eq("ordinal round trip", logic.from_ordinal(logic.to_ordinal("2026-11-12")), "2026-11-12")
eq("ordinal malformed", logic.to_ordinal("12-11-2026"), nil)
eq("weekday 2026-11-12 (Thu)", logic.weekday_iso("2026-11-12"), 4)
eq("weekday 2026-11-15 (Sun)", logic.weekday_iso("2026-11-15"), 7)
eq("next day month end", logic.next_day("2026-11-30"), "2026-12-01")
eq("next day year end", logic.next_day("2026-12-31"), "2027-01-01")
eq("days between", logic.days_between("2026-11-10", "2026-11-12"), 2)
eq("days between backwards", logic.days_between("2026-11-12", "2026-11-10"), -2)

-- ── the logical day ─────────────────────────────────────────────────────────

local function local_ms(year, month, day, hour, minute)
  -- TZ=UTC in tests: 1 hour table == 3600 epoch seconds == 3600000 ms
  return os.time({ year = year, month = month, day = day, hour = hour, min = minute or 0, sec = 0 }) * 1000
end

eq("03:30 belongs to yesterday", logic.logical_day(local_ms(2026, 11, 12, 3, 30), 4), "2026-11-11")
eq("04:00 starts today", logic.logical_day(local_ms(2026, 11, 12, 4, 0), 4), "2026-11-12")
eq("23:59 stays today", logic.logical_day(local_ms(2026, 11, 12, 23, 59), 4), "2026-11-12")
eq("midnight rollover", logic.logical_day(local_ms(2026, 11, 12, 3, 30), 0), "2026-11-12")

-- "17:00" from 10:30 is 6.5 hours away, same day
local base = local_ms(2026, 11, 12, 10, 30)
eq("due later today", logic.due_from_clock("17:00", base), base + 6 * 3600000 + 30 * 60000)
eq("due already passed rolls to tomorrow", logic.due_from_clock("09:00", base), base + 22 * 3600000 + 30 * 60000)
eq("due malformed", logic.due_from_clock("tea time", base), nil)
eq("due invalid hour", logic.due_from_clock("25:00", base), nil)

-- ── weights and score ───────────────────────────────────────────────────────

eq("weight uses estimate", logic.weight({ estimate_min = 45 }, 20), 45)
eq("weight falls back to priority", logic.weight({ priority = "high" }, 20), 40)
eq("weight honours default estimate", logic.weight({ priority = "med" }, 30), 45)

local scored = {
  { status = "today", progress = 100, estimate_min = 60 },
  { status = "today", progress = 50, estimate_min = 20 },
  { status = "pending", progress = 100, estimate_min = 999 },
}
eq("score ignores pending", logic.score(scored, 20), 88)

-- ── snapshot ────────────────────────────────────────────────────────────────

local day_tasks = {
  { status = "today", progress = 100, estimate_min = 60, due_ms = 1000, completed_ms = 900 },
  { status = "today", progress = 50, estimate_min = 20 },
  { status = "today", progress = 0, estimate_min = 20, due_ms = 5000 },
  { status = "pending", progress = 80, estimate_min = 100 },
}
local snap = logic.snapshot("2026-11-12", day_tasks, 2, 20)
eq("snapshot assigned", snap.assigned, 3)
eq("snapshot done", snap.done, 1)
eq("snapshot effort assigned", snap.effort_assigned, 100)
eq("snapshot effort done", snap.effort_done, 70)
eq("snapshot score", snap.score, 70)
eq("snapshot on time", snap.on_time, 1)
eq("snapshot on time total", snap.on_time_total, 2)
eq("snapshot avg progress of open", snap.avg_progress, 25)
eq("snapshot carried in", snap.carried_in, 2)

-- ── rollover ────────────────────────────────────────────────────────────────

local doc = {
  schema = 1,
  day = "2026-11-12",
  carried_in = 0,
  streak = { current = 1, best = 3, last_counted_day = "2026-11-12" },
  tasks = {
    { id = "t1", title = "half done", status = "today", progress = 40, estimate_min = 20, recurrence = nil, order = 1 },
    { id = "t2", title = "finished", status = "today", progress = 100, estimate_min = 20, order = 2 },
    { id = "t3", title = "parked", status = "pending", progress = 10, estimate_min = 20, carried = 2, order = 3 },
    {
      id = "t4", title = "gym", status = "today", progress = 100, estimate_min = 30,
      recurrence = { kind = "daily" }, due_ms = logic.to_ordinal("2026-11-12") * 86400000 + 18 * 3600000,
      order = 4,
    },
  },
  trash = {},
}

local plan = logic.plan_rollover(doc, "2026-11-13", local_ms(2026, 11, 13, 4, 5), 20)
eq("rollover snapshot day", plan.snapshot.day, "2026-11-12")
eq("rollover carried", plan.carried, 1)
eq("rollover repeat created", #plan.repeats, 1)

local by_title = {}
for _, task in ipairs(plan.tasks) do by_title[task.title] = task end
eq("half done carried", by_title["half done"].status, "pending")
eq("carried counter increments", by_title["half done"].carried, 1)
eq("progress preserved", by_title["half done"].progress, 40)
eq("finished task archived", by_title["finished"], nil)
eq("parked stays pending", by_title["parked"].status, "pending")
eq("repeat instance today", by_title["gym"].status, "today")
eq("repeat instance reset", by_title["gym"].progress, 0)
eq("repeat due shifted a day", by_title["gym"].due_ms, logic.to_ordinal("2026-11-13") * 86400000 + 18 * 3600000)
eq("order reindexed", by_title["gym"].order, #plan.tasks)

-- A repeat whose open instance is still pending must not duplicate.
local doc2 = {
  day = "2026-11-12",
  tasks = {
    { id = "a", title = "gym", status = "today", progress = 0, recurrence = { kind = "daily" }, estimate_min = 30 },
  },
}
local plan2 = logic.plan_rollover(doc2, "2026-11-13", 0, 20)
eq("no duplicate repeat", #plan2.repeats, 0)

-- Weekday repeats only fire on their day: 2026-11-13 is a Friday (5).
local doc3 = {
  day = "2026-11-12",
  tasks = {
    { id = "b", title = "mon/wed", status = "today", progress = 100, estimate_min = 10,
      recurrence = { kind = "weekdays", days = { 1, 3 } } },
  },
}
local plan3 = logic.plan_rollover(doc3, "2026-11-13", 0, 20)
eq("weekday repeat skipped off-day", #plan3.repeats, 0)

-- ── trash, streak, ids ──────────────────────────────────────────────────────

local now = 10 * 86400000
local trash = {
  { deleted_ms = now - 5 * 86400000, task = { title = "recent" } },
  { deleted_ms = now - 40 * 86400000, task = { title = "old" } },
}
local kept, removed = logic.purge_trash(trash, now, 30)
eq("trash keeps recent", #kept, 1)
eq("trash removes old", removed, 1)

local streak = logic.advance_streak({ current = 2, best = 5, last_counted_day = "2026-11-11" },
  { day = "2026-11-12", assigned = 3, score = 80 }, 70)
eq("streak advances", streak.current, 3)
eq("streak best untouched", streak.best, 5)
eq("streak last day", streak.last_counted_day, "2026-11-12")

local broken = logic.advance_streak({ current = 6, best = 6, last_counted_day = "2026-11-05" },
  { day = "2026-11-12", assigned = 3, score = 80 }, 70)
eq("gap breaks streak", broken.current, 1)
eq("gap keeps best", broken.best, 6)

local zero = logic.advance_streak({ current = 4, best = 4, last_counted_day = "2026-11-11" },
  { day = "2026-11-12", assigned = 0, score = 0 }, 70)
eq("empty day does not advance", zero.current, 4)

eq("base36 zero", logic.base36(0), "0")
eq("base36 35", logic.base36(35), "z")
eq("base36 36", logic.base36(36), "10")
eq("id suffix deterministic", logic.new_id(1000, "ab12"), "t_rs_ab12")

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end
