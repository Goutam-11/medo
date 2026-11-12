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
eq("weekly insight carryover", weekly.insights[1].text,
  "You carried 7 of 12 tasks. Your plan was ~1 task too ambitious — cap it at 3.")
eq("weekly insight streak", weekly.insights[2].text,
  "Monday broke a 2-day streak at 2 tasks left.")
eq("weekly insight due", weekly.insights[3].text,
  "Tasks with a due time finish 50% more often. Give the big ones a time.")
eq("weekly insight weekday", weekly.insights[4].text,
  "Tuesdays are your power day. Schedule the scary task there.")

local capped = logic.report(report_history, report_live, "weekly", "2026-11-12", { limit = 2 })
eq("insight limit count", #capped.insights, 2)
eq("insight limit keeps priority", capped.insights[1].id .. "/" .. capped.insights[2].id,
  "carryover/streak")

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
eq("monthly insight avg progress", monthly.insights[4].text,
  "You stop at ~58% a lot — those tasks are too big. Split anything over 45 min.")

-- ── reports: empty range, steady rule, markdown ─────────────────────────────

local empty_live = history_snapshot("2026-11-12", 0, 0, 0, 0, 0, 0, 0, {})
local empty_week = logic.report({}, empty_live, "weekly", "2026-11-12", {})
eq("empty report assigned", empty_week.assigned, 0)
eq("empty report active days", empty_week.active_days, 0)
eq("empty report icon", #empty_week.insights, 1)
eq("empty report steady", empty_week.insights[1].id, "steady")
eq("empty report copy", empty_week.insights[1].text,
  "A steady week. Nothing to improve — suspiciously good.")
eq("empty monthly copy", logic.report({}, empty_live, "monthly", "2026-11-12", {}).insights[1].text,
  "A steady month. Nothing to improve — suspiciously good.")
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
eq("markdown insight", markdown:find("You carried 7 of 12 tasks.", 1, true) ~= nil, true)
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
eq("celebration headline", party.headline, "Nothing left on the list. Go touch grass.")
eq("celebration line", party.line, "4/4. Medo is doing a little dance.")
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
eq("triage copy", triage.copy, "1 left today. Retry, park or drop?")
eq("triage copy idle", logic.triage_summary({ { status = "today", progress = 100 } }).copy,
  "Nothing left today. Medo is impressed.")
eq("triage copy waiting", logic.triage_summary({ { status = "pending", progress = 0 } }).copy,
  "Nothing left today. Pending can wait for tomorrow.")
eq("triage empty", logic.triage_summary({}).copy, "Nothing left today. Medo is impressed.")

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
eq("morning copy", morning[1].body, "Morning. 2 planned, 1 carried. Medo is ready.")
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
  notify_settings(), {})[1].body, "Morning. Nothing planned yet. Three is a good start.")

local at_risk = logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 2, open_count = 1, carried_count = 0, score = 20 }, notify_settings(), {})
eq("at risk fires below 30", only_kind(at_risk, "atrisk"), true)
eq("at risk copy", at_risk[1].body, "Half the day gone, nothing moved. Still fine.")
eq("at risk above threshold", #logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 2, open_count = 1, carried_count = 0, score = 40 }, notify_settings(), {}), 0)
eq("at risk needs open work", #logic.notifications(at(15, 0), "2026-11-12", {},
  { today_count = 0, open_count = 0, carried_count = 0, score = 0 }, notify_settings(), {}), 0)

local evening = logic.notifications(at(21, 0), "2026-11-12", {},
  { today_count = 3, open_count = 2, carried_count = 0, score = 40 }, notify_settings(), {})
eq("evening fires", only_kind(evening, "evening"), true)
eq("evening copy", evening[1].body, "2 left. Retry, park or drop?")
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
eq("lead copy", lead[1].body, '15 min to "Write".')
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
eq("due copy", due[1].body, '"Write" is due now (40%).')
eq("due deduped per task", #logic.notifications(at(10, 5), "2026-11-12", notify_tasks,
  notify_context, notify_settings(), { ["due:write:" .. local_ms(2026, 11, 12, 10, 0)] = 1 }), 0)
eq("due stale after 60 min", #logic.notifications(at(11, 1), "2026-11-12", notify_tasks,
  notify_context, notify_settings(), {}), 0)
eq("due exempt from quiet hours", only_kind(logic.notifications(at(22, 30), "2026-11-12", {
  { id = "late", title = "Late", status = "today", progress = 10,
    due_ms = local_ms(2026, 11, 12, 22, 25) },
}, { today_count = 1, open_count = 1, carried_count = 0, score = 10 },
  notify_settings(), {}), "due"), true)

eq("weekly copy", logic.weekly_notice({ done = 18, carryover = 6, score = 71 }),
  "Your week: 18 done, 6 carried, 71%.")
eq("monthly copy", logic.monthly_notice({ month_label = "October 2026", score = 71 }),
  "October 2026 in review — 71% efficiency.")

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

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end
