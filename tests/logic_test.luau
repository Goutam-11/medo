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

-- ── calendar ranges and labels ──────────────────────────────────────────────

eq("week starts Monday", logic.week_start_day("2026-11-12"), "2026-11-09")
eq("week start on Sunday", logic.week_start_day("2026-11-15"), "2026-11-09")
eq("week range", logic.period_range("weekly", "2026-11-12"), "2026-11-09")
eq("week range end", select(2, logic.period_range("weekly", "2026-11-12")), "2026-11-15")
eq("month range", logic.period_range("monthly", "2026-11-12"), "2026-11-01")
eq("month end", logic.month_end_day("2026-11-12"), "2026-11-30")
eq("month end leap february", logic.month_end_day("2028-02-10"), "2028-02-29")
eq("month end december", logic.month_end_day("2026-12-05"), "2026-12-31")
eq("previous week start", logic.previous_range("weekly", "2026-11-09"), "2026-11-02")
eq("previous week end", select(2, logic.previous_range("weekly", "2026-11-09")), "2026-11-08")
eq("previous month start", logic.previous_range("monthly", "2026-11-01"), "2026-10-01")
eq("previous month end", select(2, logic.previous_range("monthly", "2026-11-01")), "2026-10-31")
eq("period range rejects typo", logic.period_range("daily", "2026-11-12"), nil)

-- ── calendar ranges with a configurable week start (issue #26) ──────────────
-- 2026-11-09 is a Monday, so 2026-11-09..15 is the Mon-start week and
-- 2026-11-08..14 the Sun-start week that contains the same mid-week days.

eq("week start index defaults Monday", logic.week_start_index(nil), 1)
eq("week start index accepts a string", logic.week_start_index("7"), 7)
eq("week start index clamps out of range", logic.week_start_index(9), 1)
eq("week start index keeps Monday", logic.week_start_index(1), 1)
eq("week start Sunday from a Thursday", logic.week_start_day("2026-11-12", 7), "2026-11-08")
eq("week start Sunday from a Sunday", logic.week_start_day("2026-11-15", 7), "2026-11-15")
eq("week start Sunday from a Monday", logic.week_start_day("2026-11-09", 7), "2026-11-08")
eq("week start Monday from a Sunday", logic.week_start_day("2026-11-15", 1), "2026-11-09")
eq("week start mid-week same for both", logic.week_start_day("2026-11-11", 1), "2026-11-09")
eq("week start mid-week Sunday", logic.week_start_day("2026-11-11", 7), "2026-11-08")

eq("sunday week range", logic.period_range("weekly", "2026-11-12", 7), "2026-11-08")
eq("sunday week range end", select(2, logic.period_range("weekly", "2026-11-12", 7)), "2026-11-14")
eq("monday week range explicit", logic.period_range("weekly", "2026-11-12", 1), "2026-11-09")
eq("sunday week range label",
  logic.range_label(logic.period_range("weekly", "2026-11-12", 7)), "8–14 Nov 2026")
eq("sunday previous week start", logic.previous_range("weekly", "2026-11-08", 7), "2026-11-01")
eq("sunday previous week end", select(2, logic.previous_range("weekly", "2026-11-08", 7)), "2026-11-07")

-- 2026-12-01 is a Tuesday: the week straddles the month boundary for both
-- starts, and the monthly range ignores week_start entirely.
eq("month boundary monday start", logic.period_range("weekly", "2026-12-01", 1), "2026-11-30")
eq("month boundary monday end", select(2, logic.period_range("weekly", "2026-12-01", 1)), "2026-12-06")
eq("month boundary sunday start", logic.period_range("weekly", "2026-12-01", 7), "2026-11-29")
eq("month boundary sunday end", select(2, logic.period_range("weekly", "2026-12-01", 7)), "2026-12-05")
eq("month boundary sunday label",
  logic.range_label(logic.period_range("weekly", "2026-12-01", 7)), "29 Nov – 5 Dec 2026")
eq("monthly range ignores sunday start", logic.period_range("monthly", "2026-12-01", 7), "2026-12-01")
eq("monthly end ignores sunday start",
  select(2, logic.period_range("monthly", "2026-12-01", 7)), "2026-12-31")
eq("day list length", #logic.day_list("2026-11-09", "2026-11-15"), 7)
eq("day list backwards", #logic.day_list("2026-11-15", "2026-11-09"), 0)

eq("range same month", logic.range_label("2026-11-09", "2026-11-15"), "9–15 Nov 2026")
eq("range across months", logic.range_label("2026-10-26", "2026-11-01"), "26 Oct – 1 Nov 2026")
eq("range across years", logic.range_label("2026-12-28", "2027-01-03"), "28 Dec 2026 – 3 Jan 2027")
eq("month label", logic.month_label("2026-11-12"), "November 2026")
eq("day label", logic.day_label("2026-11-09"), "Mon 9 Nov")

eq("fmt minutes under an hour", logic.fmt_minutes(45), "45m")
eq("fmt minutes whole hours", logic.fmt_minutes(60), "1h")
eq("fmt minutes remainder", logic.fmt_minutes(190), "3h 10m")
eq("fmt minutes zero", logic.fmt_minutes(0), "0m")
eq("countdown future", logic.countdown_text(10 * 3600000 + 30 * 60000, 9 * 3600000), "in 1h 30m")
eq("countdown now", logic.countdown_text(5000, 0), "due now")
eq("countdown late", logic.countdown_text(0, 4 * 60000), "4m late")

-- ── snapshot extras ─────────────────────────────────────────────────────────

local tagged = logic.snapshot("2026-11-12", {
  { status = "today", progress = 100, estimate_min = 10, tag = "work", order = 1 },
  { status = "today", progress = 0, estimate_min = 10, tag = "", order = 2 },
  { status = "today", progress = 100, estimate_min = 10, tag = "life", order = 3 },
  { status = "today", progress = 100, estimate_min = 10, tag = "work", order = 4 },
  { status = "pending", progress = 100, estimate_min = 10, tag = "work", order = 5 },
}, 0, 20)
eq("snapshot tag counts", tagged.by_tag.work, 2)
eq("snapshot untagged bucket", tagged.by_tag.untagged, 1)
eq("snapshot ignores pending in tags", tagged.by_tag.work + tagged.by_tag.life + tagged.by_tag.untagged, 4)
eq("snapshot top3 done", tagged.top3_done, 2)

-- ── focus badge (PLAN §3.4) ─────────────────────────────────────────────────

local function ids(list)
  return table.concat(list, ",")
end

eq("focus ids fewer than three", ids(logic.focus_ids({
  { id = "a", status = "today", order = 2 },
  { id = "b", status = "today", order = 1 },
})), "b,a")
eq("focus ids first three in list order", ids(logic.focus_ids({
  { id = "a", status = "today", order = 1 },
  { id = "b", status = "today", order = 2 },
  { id = "c", status = "today", order = 3 },
  { id = "d", status = "today", order = 4 },
})), "a,b,c")
eq("focus ids skip pending", ids(logic.focus_ids({
  { id = "parked", status = "pending", order = 1 },
  { id = "a", status = "today", order = 2 },
  { id = "b", status = "done", order = 3 },
})), "a,b")
eq("focus ids keep done tasks in the top three", ids(logic.focus_ids({
  { id = "a", status = "today", order = 1, progress = 100 },
  { id = "b", status = "today", order = 2, progress = 40 },
  { id = "c", status = "done", order = 3, progress = 100 },
  { id = "d", status = "today", order = 4, progress = 0 },
})), "a,b,c")
eq("focus ids empty", #logic.focus_ids({}), 0)
eq("focus ids handles no tasks", #logic.focus_ids(), 0)

-- ── overdue banner (PLAN §7.2) ──────────────────────────────────────────────

local overdue_tasks = {
  { id = "late", status = "today", progress = 0, due_ms = 1000 },
  { id = "exact", status = "today", progress = 0, due_ms = 2000 },
  { id = "done", status = "today", progress = 100, due_ms = 1000 },
  { id = "pending", status = "pending", progress = 0, due_ms = 1000 },
  { id = "future", status = "today", progress = 0, due_ms = 3000 },
  { id = "none", status = "today", progress = 0 },
}
eq("overdue count", logic.overdue_count(overdue_tasks, 2000), 1)
eq("overdue boundary exactly due", logic.overdue_count({
  { status = "today", progress = 0, due_ms = 2000 },
}, 2000), 0)
eq("overdue one millisecond late", logic.overdue_count({
  { status = "today", progress = 0, due_ms = 1999 },
}, 2000), 1)
eq("overdue excludes done tasks", logic.overdue_count({
  { status = "today", progress = 100, due_ms = 1 },
}, 1000), 0)
eq("overdue excludes pending tasks", logic.overdue_count({
  { status = "pending", progress = 0, due_ms = 1 },
}, 1000), 0)
eq("overdue without a deadline", logic.overdue_count({
  { status = "today", progress = 0 },
}, 1000), 0)
eq("overdue empty", logic.overdue_count(nil, 1000), 0)

-- ── reports: hand-computed week (Mon 9 – Sun 15 Nov 2026) ───────────────────

local function history_snapshot(day, assigned, done, effort_assigned, effort_done,
    on_time, on_time_total, avg_progress, by_tag)
  return {
    day = day,
    assigned = assigned,
    done = done,
    carried_in = 0,
    score = effort_assigned > 0 and math.floor(100 * effort_done / effort_assigned + 0.5) or 0,
    effort_assigned = effort_assigned,
    effort_done = effort_done,
    on_time = on_time,
    on_time_total = on_time_total,
    avg_progress = avg_progress,
    by_tag = by_tag or {},
    closed = "ok",
  }
end

-- 7–8 Nov are context for the streak that Monday breaks and for the trend.
local report_history = {
  history_snapshot("2026-11-07", 2, 1, 100, 90, 0, 0, 80, { work = 2 }),
  history_snapshot("2026-11-08", 2, 1, 100, 80, 0, 0, 80, { work = 2 }),
  history_snapshot("2026-11-09", 4, 2, 100, 50, 1, 2, 40, { work = 3, life = 1 }),
  history_snapshot("2026-11-10", 2, 2, 60, 60, 1, 1, 0, { work = 2 }),
  history_snapshot("2026-11-11", 3, 0, 90, 0, 0, 1, 60, { life = 3 }),
}
local report_live = history_snapshot("2026-11-12", 3, 1, 90, 60, 1, 2, 50, { work = 2, life = 1 })

local weekly = logic.report(report_history, report_live, "weekly", "2026-11-12", {
  threshold = 70, cap = 3, limit = 4,
})
eq("weekly label", weekly.label, "9–15 Nov 2026")
eq("weekly assigned", weekly.assigned, 12)
eq("weekly done", weekly.done, 5)
eq("weekly effort", weekly.effort_assigned .. "/" .. weekly.effort_done, "340/170")
eq("weekly score", weekly.score, 50)
eq("weekly carryover", weekly.carryover, 7)
eq("weekly carryover rate", weekly.carryover_rate, 58)
eq("weekly on time", weekly.on_time, 3)
eq("weekly on time total", weekly.on_time_total, 6)
eq("weekly on time rate", weekly.on_time_rate, 50)
eq("weekly avg progress", weekly.avg_progress, 51)
eq("weekly active days", weekly.active_days, 4)
eq("weekly best day", weekly.best.day .. " " .. weekly.best.score, "2026-11-10 100")
eq("weekly worst day", weekly.worst.day .. " " .. weekly.worst.score, "2026-11-11 0")
eq("weekly trend delta", weekly.trend.delta, -35)
eq("weekly chart length", #weekly.chart, 4)
eq("weekly chart monday", weekly.chart[1], 0.5)
eq("weekly chart tuesday", weekly.chart[2], 1)
eq("weekly chart wednesday", weekly.chart[3], 0)
eq("weekly chart thursday", weekly.chart[4], 0.67)
eq("weekly tags", #weekly.by_tag, 2)
eq("weekly top tag", weekly.by_tag[1].tag .. " " .. weekly.by_tag[1].count, "work 7")
eq("weekly top tag share", weekly.by_tag[1].share, 58)
eq("weekly live day marked", weekly.days[4].live, true)

eq("weekly insight count", #weekly.insights, 4)
eq("weekly insight carryover key", weekly.insights[1].key, "insight.carryover")
eq("weekly insight carryover plural", weekly.insights[1].plural, 1)
eq("weekly insight carryover numbers", weekly.insights[1].subst.carried, 7)
eq("weekly insight carryover cap", weekly.insights[1].subst.cap, 3)
eq("weekly insight streak key", weekly.insights[2].key, "insight.streak")
eq("weekly insight streak plural", weekly.insights[2].plural, 2)
eq("weekly insight streak weekday", weekly.insights[2].subst.weekday, "Monday")
eq("weekly insight due key", weekly.insights[3].key, "insight.due")
eq("weekly insight due lift", weekly.insights[3].subst.lift, 50)
eq("weekly insight weekday key", weekly.insights[4].key, "insight.weekday")
eq("weekly insight weekday name", weekly.insights[4].subst.weekday, "Tuesday")

local capped = logic.report(report_history, report_live, "weekly", "2026-11-12", { limit = 2 })
eq("insight limit count", #capped.insights, 2)
eq("insight limit keeps priority", capped.insights[1].id .. "/" .. capped.insights[2].id,
  "carryover/streak")

-- ── reports: the same week starting on Sunday (issue #26) ───────────────────
-- Sunday 8 – Saturday 14 Nov: the four Monday-start days plus the 8th, and the
-- trend now compares against the previous Sun-start week (1–7 Nov).
local sunday_week = logic.report(report_history, report_live, "weekly", "2026-11-12", {
  week_start = 7, threshold = 70, cap = 3, limit = 4,
})
eq("sunday week label", sunday_week.label, "8–14 Nov 2026")
eq("sunday week start day", sunday_week.start_day, "2026-11-08")
eq("sunday week end day", sunday_week.end_day, "2026-11-14")
eq("sunday week published start", sunday_week.week_start, 7)
eq("sunday week first day", sunday_week.days[1].day, "2026-11-08")
eq("sunday week first weekday", sunday_week.days[1].weekday, "Sun")
eq("sunday week last elapsed day", sunday_week.days[#sunday_week.days].day, "2026-11-12")
eq("sunday week day count", #sunday_week.days, 5)
eq("sunday week chart length", #sunday_week.chart, 5)
eq("sunday week assigned", sunday_week.assigned, 14)
eq("sunday week done", sunday_week.done, 6)
eq("sunday week score", sunday_week.score, 57)
eq("sunday week best day", sunday_week.best.day, "2026-11-10")
eq("sunday week trend delta", sunday_week.trend.delta, -33)
eq("sunday week carryover insight", sunday_week.insights[1].key, "insight.carryover")

-- The Monday-start report is unchanged when the setting is passed explicitly,
-- and a completed week is still seven days for either start.
local monday_week = logic.report(report_history, report_live, "weekly", "2026-11-12", {
  week_start = 1, threshold = 70, cap = 3, limit = 4,
})
eq("monday explicit chart length", #monday_week.chart, #weekly.chart)
eq("monday explicit label", monday_week.label, "9–15 Nov 2026")
eq("sunday completed week chart length",
  #logic.report(report_history, report_live, "weekly", "2026-11-14", { week_start = 7 }).chart, 7)
eq("monday completed week chart length",
  #logic.report(report_history, report_live, "weekly", "2026-11-15", { week_start = 1 }).chart, 7)

-- Monthly reports ignore week_start: same range, same label, same chart length.
local sunday_month = logic.report(report_history, report_live, "monthly", "2026-11-12", {
  week_start = 7, threshold = 70, cap = 3, limit = 4,
})
eq("monthly label ignores sunday start", sunday_month.label, "1–30 Nov 2026")
eq("monthly chart length ignores sunday start", #sunday_month.chart, 12)
eq("monthly first day ignores sunday start", sunday_month.days[1].day, "2026-11-01")
eq("monthly totals ignore sunday start", sunday_month.assigned, 16)

-- ── reports: the same fixture as a month (1–12 Nov) ─────────────────────────

local monthly = logic.report(report_history, report_live, "monthly", "2026-11-12", {
  threshold = 70, cap = 3, limit = 4,
})
eq("monthly label", monthly.label, "1–30 Nov 2026")
eq("monthly assigned", monthly.assigned, 16)
eq("monthly done", monthly.done, 7)
eq("monthly score", monthly.score, 63)
eq("monthly carryover", monthly.carryover, 9)
eq("monthly carryover rate", monthly.carryover_rate, 56)
eq("monthly on time rate", monthly.on_time_rate, 50)
eq("monthly avg progress", monthly.avg_progress, 58)
eq("monthly active days", monthly.active_days, 6)
eq("monthly day score average", monthly.day_score_avg, 65)
eq("monthly best day", monthly.best.day, "2026-11-10")
eq("monthly worst day", monthly.worst.day, "2026-11-11")
eq("monthly no earlier month", monthly.trend, nil)
eq("monthly chart length", #monthly.chart, 12)
eq("monthly chart first", monthly.chart[1], 0)
eq("monthly chart last", monthly.chart[12], 0.67)
eq("monthly insight avg progress key", monthly.insights[4].key, "insight.avg_progress")
eq("monthly insight avg progress number", monthly.insights[4].subst.progress, 58)

-- ── reports: empty range, steady rule, markdown ─────────────────────────────

local empty_live = history_snapshot("2026-11-12", 0, 0, 0, 0, 0, 0, 0, {})
local empty_week = logic.report({}, empty_live, "weekly", "2026-11-12", {})
eq("empty report assigned", empty_week.assigned, 0)
eq("empty report active days", empty_week.active_days, 0)
eq("empty report icon", #empty_week.insights, 1)
eq("empty report steady", empty_week.insights[1].id, "steady")
eq("empty report key", empty_week.insights[1].key, "insight.steady.week")
eq("empty monthly key",
  logic.report({}, empty_live, "monthly", "2026-11-12", {}).insights[1].key,
  "insight.steady.monthly")
eq("report rejects unknown period", logic.report({}, empty_live, "yearly", "2026-11-12", {}), nil)

local calm_days = {}
for day_number = 9, 13 do
  calm_days[#calm_days + 1] = {
    day = string.format("2026-11-%02d", day_number),
    has_data = true, assigned = 2, done = 2, score = 80,
  }
end
local steady = logic.insights({
  period = "weekly", assigned = 10, done = 10, carryover = 0, carryover_rate = 0,
  on_time = 0, on_time_total = 0, avg_progress = 10, active_days = 5,
  day_score_avg = 80, days = calm_days,
}, {})
eq("steady rule with data", steady[1].id, "steady")

local markdown = logic.report_markdown(weekly, "2026-11-12 18:04")
eq("markdown title", markdown:find("# medo — weekly report", 1, true) ~= nil, true)
eq("markdown range", markdown:find("**9–15 Nov 2026** · generated 2026-11-12 18:04", 1, true) ~= nil, true)
eq("markdown score row", markdown:find("| Score | 50% |", 1, true) ~= nil, true)
eq("markdown carried row", markdown:find("| Carried over | 7 (58%) |", 1, true) ~= nil, true)
eq("markdown best row", markdown:find("| Best day | Tue 10 Nov (100%) |", 1, true) ~= nil, true)
eq("markdown tag", markdown:find("- #work: 7 (58%)", 1, true) ~= nil, true)
eq("markdown insight key without a translator", markdown:find("- insight.carryover", 1, true) ~= nil, true)
-- the service passes noctalia.tr, so the export gets the real copy
local translated = logic.report_markdown(weekly, "2026-11-12 09:00",
  function(key, subst, count)
    if count then return string.format("%s(%d|%s)", key, count, tostring(subst.carried)) end
    return key
  end)
eq("markdown insight translated", translated:find("- insight.carryover(1|7)", 1, true) ~= nil, true)
eq("markdown day table", markdown:find("| Mon 9 Nov | 50% | 2 / 4 |", 1, true) ~= nil, true)

-- ── aggregate helper ────────────────────────────────────────────────────────

local aggregate = logic.aggregate({ report_history[3], report_live })
eq("aggregate assigned", aggregate.assigned, 7)
eq("aggregate effort score", aggregate.score, 58)
eq("aggregate avg progress", aggregate.avg_progress, 45)

-- ── dashboard helpers ───────────────────────────────────────────────────────

local due_tasks = {
  { id = "late", title = "Late", status = "today", due_ms = 1000, progress = 40 },
  { id = "done", title = "Done", status = "today", due_ms = 500, progress = 100 },
  { id = "parked", title = "Parked", status = "pending", due_ms = 200, progress = 0 },
  { id = "later", title = "Later", status = "today", due_ms = 5000, progress = 10 },
}
local next_due = logic.next_due(due_tasks)
eq("next due skips done and pending", next_due.id, "late")
eq("next due keeps the deadline", next_due.due_ms, 1000)
eq("next due none when clear", logic.next_due({ { status = "today", progress = 100, due_ms = 1 } }), nil)

-- ── bar tooltip and capsule settings (PLAN decision 20, §9) ─────────────────

local tooltip_row = logic.next_due_tooltip(next_due, 0)
eq("tooltip next due countdown", tooltip_row.when, "due now")
eq("tooltip next due title", tooltip_row.title, "Late")
eq("tooltip next due late copy", logic.next_due_tooltip(next_due, 1000 + 4 * 60000).when, "4m late")
eq("tooltip drops when nothing is due", logic.next_due_tooltip(nil, 0), nil)
eq("tooltip drops without a deadline", logic.next_due_tooltip({ title = "no time" }, 0), nil)
eq("tooltip tolerates a missing title", logic.next_due_tooltip({ due_ms = 60000 }, 0).title, "")

local both = logic.bar_visibility(nil, nil)
eq("bar defaults show both", both.count, true)
eq("bar defaults show the dot", both.dot, true)
local count_only = logic.bar_visibility(true, false)
eq("bar count only keeps the count", count_only.count, true)
eq("bar count only hides the dot", count_only.dot, false)
local dot_only = logic.bar_visibility(false, true)
eq("bar dot only hides the count", dot_only.count, false)
eq("bar dot only keeps the dot", dot_only.dot, true)
local fallback = logic.bar_visibility(false, false)
eq("bar fallback restores the count", fallback.count, true)
eq("bar fallback leaves the dot off", fallback.dot, false)

local spark = logic.sparkline(report_history, report_live, "2026-11-12", 7)
eq("sparkline length", #spark, 7)
eq("sparkline first day", spark[1].day, "2026-11-06")
eq("sparkline last day", spark[7].day, "2026-11-12")
eq("sparkline gap is zero", spark[1].value, 0)
eq("sparkline gap flag", spark[1].has_data, false)
eq("sparkline saturday", spark[2].value, 0.9)
eq("sparkline tuesday", spark[5].value, 1)
eq("sparkline live", spark[7].value, 0.67)

eq("mascot sleepy low", logic.mascot_state(0), "sleepy")
eq("mascot sleepy edge", logic.mascot_state(24), "sleepy")
eq("mascot focused low", logic.mascot_state(25), "focused")
eq("mascot focused edge", logic.mascot_state(69), "focused")
eq("mascot proud low", logic.mascot_state(70), "proud")
eq("mascot proud edge", logic.mascot_state(99), "proud")
eq("mascot celebrating", logic.mascot_state(100), "celebrating")
eq("mascot clamps high", logic.mascot_state(120), "celebrating")
eq("mascot handles nil", logic.mascot_state(nil), "sleepy")

-- mascot_face maps the mood to one of the four bundled PNGs
eq("face sleepy", logic.mascot_face("sleepy", 0), "sleepy")
eq("face sleepy with carried", logic.mascot_face("sleepy", 2), "worried")
eq("face focused ignores carried", logic.mascot_face("focused", 3), "focused")
eq("face proud", logic.mascot_face("proud", 0), "proud")
eq("face celebrating uses proud art", logic.mascot_face("celebrating", 0), "proud")

-- celebration eligibility + PLAN §3.5 copy
local party = logic.celebration(4, 4)
eq("celebration eligible", party.eligible, true)
eq("celebration headline key", party.headline_key, "celebration.headline")
eq("celebration line key", party.line_key, "celebration.line")
eq("celebration line numbers", party.subst.done .. "/" .. party.subst.total, "4/4")
eq("celebration partial", logic.celebration(3, 4).eligible, false)
eq("celebration empty day", logic.celebration(0, 0).eligible, false)
eq("celebration clamps", logic.celebration(5, 4).eligible, true)

-- triage summary counts unfinished Today and Pending rows
local triage_list = {
  { id = "a", status = "today", progress = 0 },
  { id = "b", status = "today", progress = 100 },
  { id = "c", status = "pending", progress = 30 },
  { id = "d", status = "pending", progress = 0 },
}
local triage = logic.triage_summary(triage_list)
eq("triage open", triage.open, 1)
eq("triage pending", triage.pending, 2)
eq("triage copy key", triage.copy_key, "triage.copy.open")
eq("triage copy count", triage.subst.count, 1)
eq("triage copy idle", logic.triage_summary({ { status = "today", progress = 100 } }).copy_key,
  "triage.copy.done")
eq("triage copy waiting", logic.triage_summary({ { status = "pending", progress = 0 } }).copy_key,
  "triage.copy.pending")
eq("triage empty", logic.triage_summary({}).copy_key, "triage.copy.done")

-- ── notifications ───────────────────────────────────────────────────────────

eq("clock minutes", logic.clock_minutes("08:30"), 510)
eq("clock minutes single digit", logic.clock_minutes("8:05"), 485)
eq("clock minutes malformed", logic.clock_minutes("8:5"), nil)
eq("clock minutes invalid hour", logic.clock_minutes("24:00"), nil)

local function at(hour, minute, day)
  return local_ms(2026, 11, day or 12, hour, minute)
end

eq("window at target", logic.scheduled_window(at(8, 0), "08:00"), true)
eq("window 59 min after", logic.scheduled_window(at(8, 59), "08:00"), true)
eq("window 60 min after", logic.scheduled_window(at(9, 0), "08:00"), false)
eq("window before target", logic.scheduled_window(at(7, 59), "08:00"), false)
eq("window crosses midnight", logic.scheduled_window(at(0, 10, 13), "23:30"), true)
eq("window invalid clock", logic.scheduled_window(at(8, 0), "tea"), false)

eq("quiet at start", logic.in_quiet_hours(at(22, 0), "22:00", "07:00"), true)
eq("quiet after midnight", logic.in_quiet_hours(at(3, 0), "22:00", "07:00"), true)
eq("quiet at end", logic.in_quiet_hours(at(7, 0), "22:00", "07:00"), false)
eq("quiet before start", logic.in_quiet_hours(at(21, 59), "22:00", "07:00"), false)
eq("quiet simple window", logic.in_quiet_hours(at(9, 30), "08:00", "10:00"), true)
eq("quiet empty window", logic.in_quiet_hours(at(9, 30), "22:00", "22:00"), false)

local function notify_settings(overrides)
  local settings = {
    morning_time = "08:00", evening_time = "21:00", atrisk_time = "15:00",
    weekly_day = "7", weekly_time = "20:00", monthly_time = "20:00",
    quiet_start = "22:00", quiet_end = "07:00", lead_min = 15,
    notify = {
      morning = true, evening = true, due = true, lead = true,
      weekly = true, monthly = true, atrisk = true,
    },
  }
  for key, value in pairs(overrides or {}) do
    if key == "notify" then
      for flag, enabled in pairs(value) do settings.notify[flag] = enabled end
    else
      settings[key] = value
    end
  end
  return settings
end

local notify_tasks = {
  { id = "write", title = "Write", status = "today", progress = 40, due_ms = local_ms(2026, 11, 12, 10, 0) },
  { id = "done", title = "Done", status = "today", progress = 100, due_ms = local_ms(2026, 11, 12, 10, 0) },
  { id = "parked", title = "Parked", status = "pending", progress = 0, due_ms = local_ms(2026, 11, 12, 10, 0) },
}
local notify_context = { today_count = 2, open_count = 1, carried_count = 1, score = 40 }

local function only_kind(entries, kind)
  return #entries == 1 and entries[1].kind == kind
end

local morning = logic.notifications(at(8, 0), "2026-11-12", notify_tasks, notify_context,
  notify_settings(), {})
eq("morning fires in window", only_kind(morning, "morning"), true)
eq("morning body key", morning[1].body_key, "notify.morning")
eq("morning planned", morning[1].subst.planned, 2)
eq("morning carried", morning[1].subst.carried, 1)
eq("morning key", morning[1].key, "morning:2026-11-12")
eq("morning at minute 59", only_kind(logic.notifications(at(8, 59), "2026-11-12",
  notify_tasks, notify_context, notify_settings(), {}), "morning"), true)
eq("morning outside window", #logic.notifications(at(9, 0), "2026-11-12",
  notify_tasks, notify_context, notify_settings(), {}), 0)
eq("morning deduped", #logic.notifications(at(8, 0), "2026-11-12",
  notify_tasks, notify_context, notify_settings(), { ["morning:2026-11-12"] = 1 }), 0)
eq("morning disabled", #logic.notifications(at(8, 0), "2026-11-12",
  notify_tasks, notify_context, notify_settings({ notify = { morning = false } }), {}), 0)
eq("morning empty day", logic.notifications(at(8, 0), "2026-11-12", {},
  { today_count = 0, open_count = 0, carried_count = 0, score = 0 },
  notify_settings(), {})[1].body_key, "notify.morning.empty")

local at_risk = logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 2, open_count = 1, carried_count = 0, score = 20 }, notify_settings(), {})
eq("at risk fires below 30", only_kind(at_risk, "atrisk"), true)
eq("at risk key", at_risk[1].body_key, "notify.atrisk")
eq("at risk above threshold", #logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 2, open_count = 1, carried_count = 0, score = 40 }, notify_settings(), {}), 0)
eq("at risk needs open work", #logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 0, open_count = 0, carried_count = 0, score = 0 }, notify_settings(), {}), 0)

local evening = logic.notifications(at(21, 0), "2026-11-12", {},
  { today_count = 3, open_count = 2, carried_count = 0, score = 40 }, notify_settings(), {})
eq("evening fires", only_kind(evening, "evening"), true)
eq("evening key", evening[1].body_key, "notify.evening")
eq("evening count", evening[1].subst.count, 2)
eq("evening quiet hours", #logic.notifications(at(22, 30), "2026-11-12", {},
  { today_count = 3, open_count = 2, carried_count = 0, score = 40 },
  notify_settings({ evening_time = "22:00" }), {}), 0)
eq("evening needs open work", #logic.notifications(at(21, 0), "2026-11-12", {},
  { today_count = 0, open_count = 0, carried_count = 0, score = 0 }, notify_settings(), {}), 0)

local weekly = logic.notifications(at(20, 0, 15), "2026-11-15", {}, notify_context,
  notify_settings(), {})
eq("weekly fires Sunday", only_kind(weekly, "weekly"), true)
eq("weekly body built later", weekly[1].body, nil)
eq("weekly off day", #logic.notifications(at(20, 0, 16), "2026-11-16", {}, notify_context,
  notify_settings(), {}), 0)
eq("weekly custom day", only_kind(logic.notifications(at(20, 0, 16), "2026-11-16", {},
  notify_context, notify_settings({ weekly_day = "1" }), {}), "weekly"), true)
eq("weekly deduped", #logic.notifications(at(20, 0, 15), "2026-11-15", {}, notify_context,
  notify_settings(), { ["weekly:2026-11-15"] = 1 }), 0)

local monthly = logic.notifications(at(20, 0, 1), "2026-12-01", {}, notify_context,
  notify_settings(), {})
eq("monthly fires on the 1st", only_kind(monthly, "monthly"), true)
eq("monthly off day", #logic.notifications(at(20, 0, 2), "2026-12-02", {}, notify_context,
  notify_settings(), {}), 0)

local lead = logic.notifications(at(9, 45), "2026-11-12", notify_tasks, notify_context,
  notify_settings(), {})
eq("lead fires in window", only_kind(lead, "lead"), true)
eq("lead key", lead[1].body_key, "notify.lead")
eq("lead minutes", lead[1].subst.minutes, 15)
eq("lead title", lead[1].subst.title, "Write")
eq("lead too early", #logic.notifications(at(9, 44), "2026-11-12", notify_tasks,
  notify_context, notify_settings(), {}), 0)
eq("lead silent in quiet hours", #logic.notifications(at(6, 50), "2026-11-12", {
  { id = "early", title = "Early", status = "today", progress = 0, due_ms = local_ms(2026, 11, 12, 7, 0) },
}, notify_context, notify_settings(), {}), 0)

local override_lead = {
  { id = "short", title = "Short", status = "today", progress = 0, lead_min = 5,
    due_ms = local_ms(2026, 11, 12, 10, 0) },
}
eq("task lead overrides default", only_kind(logic.notifications(at(9, 56), "2026-11-12",
  override_lead, notify_context, notify_settings(), {}), "lead"), true)
eq("task lead blocks early", #logic.notifications(at(9, 50), "2026-11-12",
  override_lead, notify_context, notify_settings(), {}), 0)

local due = logic.notifications(at(10, 5), "2026-11-12", notify_tasks, notify_context,
  notify_settings(), {})
eq("due fires after deadline", only_kind(due, "due"), true)
eq("due key", due[1].body_key, "notify.due")
eq("due progress", due[1].subst.progress, 40)
eq("due title", due[1].subst.title, "Write")
eq("due deduped per task", #logic.notifications(at(10, 5), "2026-11-12", notify_tasks,
  notify_context, notify_settings(), { ["due:write:" .. local_ms(2026, 11, 12, 10, 0)] = 1 }), 0)
eq("due stale after 60 min", #logic.notifications(at(11, 1), "2026-11-12", notify_tasks,
  notify_context, notify_settings(), {}), 0)
eq("due exempt from quiet hours", only_kind(logic.notifications(at(22, 30), "2026-11-12", {
  { id = "late", title = "Late", status = "today", progress = 10,
    due_ms = local_ms(2026, 11, 12, 22, 25) },
}, { today_count = 1, open_count = 1, carried_count = 0, score = 10 },
  notify_settings(), {}), "due"), true)


-- ── launcher capture tokens ─────────────────────────────────────────────────
--
-- now is Thursday 2026-11-12 10:30; every expectation below is hand-computed
-- from that wall clock with TZ=UTC.

local capture_now = local_ms(2026, 11, 12, 10, 30)
local capture_day = "2026-11-12"

local function capture(text)
  return logic.parse_capture(text, capture_now, capture_day)
end

local plain = capture("buy milk")
eq("capture plain title", plain.title, "buy milk")
eq("capture plain due", plain.due_ms, nil)
eq("capture plain tag", plain.tag, nil)
eq("capture plain priority", plain.priority, nil)
eq("capture plain preview", logic.capture_preview(plain), "")

eq("capture time title", capture("buy milk @17:00").title, "buy milk")
eq("capture time due", capture("buy milk @17:00").due_ms, local_ms(2026, 11, 12, 17, 0))
eq("capture time label", capture("buy milk @17:00").due_label, "today 17:00")
eq("capture time already passed", capture("buy milk @09:00").due_ms, local_ms(2026, 11, 13, 9, 0))
eq("capture time passed label", capture("buy milk @09:00").due_label, "tomorrow 09:00")
eq("capture single digit hour", capture("standup @9:05").due_ms, local_ms(2026, 11, 13, 9, 5))
eq("capture leading token", capture("@17:00 buy milk").title, "buy milk")

eq("capture tomorrow due", capture("buy milk @tomorrow").due_ms, local_ms(2026, 11, 13, 9, 0))
eq("capture tomorrow label", capture("buy milk @tomorrow").due_label, "tomorrow 09:00")
eq("capture tomorrow removes token", capture("@tomorrow buy milk").title, "buy milk")

local tomorrow_time = capture("buy milk @tomorrow @17:00")
eq("capture day + time", tomorrow_time.due_ms, local_ms(2026, 11, 13, 17, 0))
eq("capture time then day", capture("buy milk @17:00 @tomorrow").due_ms, local_ms(2026, 11, 13, 17, 0))
eq("capture day + time title", tomorrow_time.title, "buy milk")

-- 2026-11-12 is a Thursday (ISO 4); @mon is the coming Monday, @thu is a week out
eq("capture next monday", capture("plan @mon").due_ms, local_ms(2026, 11, 16, 9, 0))
eq("capture monday label", capture("plan @mon").due_label, "Mon 09:00")
eq("capture same weekday is next week", capture("plan @thu").due_ms, local_ms(2026, 11, 19, 9, 0))
eq("capture full weekday name", capture("plan @saturday").due_ms, local_ms(2026, 11, 14, 9, 0))
eq("capture weekday + time", capture("plan @fri @18:30").due_ms, local_ms(2026, 11, 13, 18, 30))

eq("capture tag", capture("buy milk #errand").tag, "errand")
eq("capture tag removes token", capture("buy milk #errand").title, "buy milk")
eq("capture tag keeps dash", capture("#side-project write").tag, "side-project")
eq("capture last tag wins", capture("#first #second buy").tag, "second")

eq("capture priority", capture("buy milk !high").priority, "high")
eq("capture priority case", capture("buy milk !LOW").priority, "low")
eq("capture unknown bang stays in title", capture("buy milk !urgent").title, "buy milk !urgent")
eq("capture unknown bang priority", capture("buy milk !urgent").priority, nil)

local mixed = capture("buy milk @17:00 #errand !high")
eq("capture mixed title", mixed.title, "buy milk")
eq("capture mixed tag", mixed.tag, "errand")
eq("capture mixed priority", mixed.priority, "high")
eq("capture mixed due", mixed.due_ms, local_ms(2026, 11, 12, 17, 0))
eq("capture mixed preview", logic.capture_preview(mixed), "today 17:00 · #errand · high")

local malformed = capture("@25:00 buy !wow # milk")
eq("capture malformed keeps text", malformed.title, "@25:00 buy !wow # milk")
eq("capture malformed no due", malformed.due_ms, nil)
eq("capture malformed no tag", malformed.tag, nil)

local tokens_only = capture("@17:00 #work")
eq("capture tokens only title", tokens_only.title, "")
eq("capture tokens only due", tokens_only.due_ms, local_ms(2026, 11, 12, 17, 0))
eq("capture tokens only tag", tokens_only.tag, "work")

eq("capture empty text", capture("").title, "")
eq("capture whitespace", capture("   ").title, "")
eq("capture preserves word order", capture("milk buy @17:00").title, "milk buy")

-- the label compares calendar dates, so a due at 01:30 with a 04:00 rollover is
-- still "today" rather than yesterday
eq("capture due day label next weekday", logic.due_day_label(local_ms(2026, 11, 15, 9, 0), capture_now), "Sun 09:00")

-- ── trash window ────────────────────────────────────────────────────────────

local day_ms = 86400000
eq("trash fresh", logic.trash_days_left(0, 0, 30), 30)
eq("trash three days", logic.trash_days_left(0, 3 * day_ms, 30), 27)
eq("trash rounds up", logic.trash_days_left(0, 29.5 * day_ms, 30), 1)
eq("trash at the window", logic.trash_days_left(0, 30 * day_ms, 30), 0)
eq("trash past the window", logic.trash_days_left(0, 40 * day_ms, 30), 0)
eq("trash custom retention", logic.trash_days_left(0, day_ms, 7), 6)
eq("trash default retention", logic.trash_days_left(0, 0, nil), 30)

-- the countdown and the purge must agree about the boundary: 0 days left is
-- "goes tonight", and purge only removes an entry *past* the window
local inside, inside_removed = logic.purge_trash({ { deleted_ms = 0, task = {} } }, 29.9 * day_ms, 30)
eq("trash inside window kept", #inside, 1)
eq("trash inside window removed", inside_removed, 0)
local outside, outside_removed = logic.purge_trash({ { deleted_ms = 0, task = {} } }, 30.5 * day_ms, 30)
eq("trash outside window kept", #outside, 0)
eq("trash outside window removed", outside_removed, 1)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end
