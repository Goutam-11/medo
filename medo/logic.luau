--!nonstrict
-- medo logic — pure functions only. No noctalia.*, no filesystem, no clock reads
-- except os.date for the local date. Unit tests (tests/logic_test.luau) load
-- this file directly, so anything host-dependent belongs in core.luau or
-- store.luau instead.
--
-- Data shapes (schema 1):
--   task { id, title, notes, tag, priority, estimate_min, due_ms, lead_min,
--          progress, carried, recurrence, status, order, created_ms, completed_ms }
--   doc  { schema, revision, day, rollover_hour, carried_in, streak, tasks, trash }

local M = {}

M.SCHEMA = 1

local PRIORITY_MULT = { low = 1, med = 1.5, high = 2 }

local function clamp_progress(value)
  local progress = tonumber(value) or 0
  if progress < 0 then return 0 end
  if progress > 100 then return 100 end
  return progress
end

local function round(value)
  return math.floor(value + 0.5)
end

-- ── civil dates (timezone-free) ─────────────────────────────────────────────

-- Days since 1970-01-01 for a "YYYY-MM-DD" string; nil when malformed.
function M.to_ordinal(day)
  if type(day) ~= "string" then return nil end
  local y, m, d = day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 3 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.from_ordinal(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return string.format("%04d-%02d-%02d", y, m, d)
end

function M.next_day(day)
  local ordinal = M.to_ordinal(day)
  if not ordinal then return nil end
  return M.from_ordinal(ordinal + 1)
end

function M.days_between(from_day, to_day)
  local a, b = M.to_ordinal(from_day), M.to_ordinal(to_day)
  if not a or not b then return nil end
  return b - a
end

-- ISO weekday: 1 = Monday … 7 = Sunday. 1970-01-01 was a Thursday.
function M.weekday_iso(day)
  local ordinal = M.to_ordinal(day)
  if not ordinal then return nil end
  return (ordinal + 3) % 7 + 1
end

-- ── calendar labels, periods, formatting ────────────────────────────────────

local MONTHS = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}
local WEEKDAYS = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
local WEEKDAYS_SHORT = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Split "YYYY-MM-DD" into numbers; nil when malformed.
function M.day_parts(day)
  if type(day) ~= "string" then return nil end
  local y, m, d = day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  return y, m, d
end

function M.weekday_name(day, short)
  local weekday = M.weekday_iso(day)
  if not weekday then return nil end
  return (short and WEEKDAYS_SHORT or WEEKDAYS)[weekday]
end

-- Monday of the week containing `day` (PLAN open decision 2).
function M.week_start_day(day)
  local ordinal = M.to_ordinal(day)
  local weekday = M.weekday_iso(day)
  if not ordinal or not weekday then return nil end
  return M.from_ordinal(ordinal - (weekday - 1))
end

function M.month_start_day(day)
  local y, m = M.day_parts(day)
  if not y then return nil end
  return string.format("%04d-%02d-01", y, m)
end

function M.month_end_day(day)
  local y, m = M.day_parts(day)
  if not y then return nil end
  local following = m == 12 and string.format("%04d-01-01", y + 1) or string.format("%04d-%02d-01", y, m + 1)
  return M.from_ordinal(M.to_ordinal(following) - 1)
end

-- Inclusive list of day strings. Capped so a typo can never build a huge table.
function M.day_list(start_day, end_day)
  local first, last = M.to_ordinal(start_day), M.to_ordinal(end_day)
  if not first or not last or last < first then return {} end
  local days = {}
  for ordinal = first, math.min(last, first + 366) do
    days[#days + 1] = M.from_ordinal(ordinal)
  end
  return days
end

-- Start and end of the report period containing `day`.
function M.period_range(period, day)
  if period == "weekly" then
    local start_day = M.week_start_day(day)
    if not start_day then return nil end
    return start_day, M.from_ordinal(M.to_ordinal(start_day) + 6)
  elseif period == "monthly" then
    local start_day = M.month_start_day(day)
    if not start_day then return nil end
    return start_day, M.month_end_day(day)
  end
  return nil
end

-- The period immediately before the one that starts at `start_day`.
function M.previous_range(period, start_day)
  local last = M.to_ordinal(start_day)
  if not last then return nil end
  local end_day = M.from_ordinal(last - 1)
  if period == "weekly" then
    return M.week_start_day(end_day), end_day
  elseif period == "monthly" then
    return M.month_start_day(end_day), end_day
  end
  return nil
end

-- "10–16 Nov 2026", "26 Oct – 1 Nov 2026", "28 Dec 2026 – 3 Jan 2027".
function M.range_label(start_day, end_day)
  local y1, m1, d1 = M.day_parts(start_day)
  local y2, m2, d2 = M.day_parts(end_day)
  if not y1 or not y2 then return tostring(start_day) .. " – " .. tostring(end_day) end
  if y1 == y2 and m1 == m2 then
    return string.format("%d–%d %s %d", d1, d2, MONTHS[m1]:sub(1, 3), y1)
  elseif y1 == y2 then
    return string.format("%d %s – %d %s %d", d1, MONTHS[m1]:sub(1, 3), d2, MONTHS[m2]:sub(1, 3), y1)
  end
  return string.format("%d %s %d – %d %s %d", d1, MONTHS[m1]:sub(1, 3), y1, d2, MONTHS[m2]:sub(1, 3), y2)
end

function M.month_label(day)
  local y, m = M.day_parts(day)
  if not y then return tostring(day) end
  return string.format("%s %d", MONTHS[m], y)
end

-- "Mon 9 Nov" — compact and unambiguous inside a report.
function M.day_label(day)
  local y, m, d = M.day_parts(day)
  local weekday = M.weekday_name(day, true)
  if not y or not weekday then return tostring(day) end
  return string.format("%s %d %s", weekday, d, MONTHS[m]:sub(1, 3))
end

-- "45m", "3h", "3h 10m".
function M.fmt_minutes(minutes)
  local value = math.max(0, round(tonumber(minutes) or 0))
  if value < 60 then return string.format("%dm", value) end
  local hours, rest = math.floor(value / 60), value % 60
  if rest == 0 then return string.format("%dh", hours) end
  return string.format("%dh %02dm", hours, rest)
end

-- Countdown copy for the dashboard: "in 2h 10m", "due now", "4m late".
function M.countdown_text(due_ms, now_ms)
  local delta = (tonumber(due_ms) or 0) - (tonumber(now_ms) or 0)
  if math.abs(delta) < 60000 then return "due now" end
  local label = M.fmt_minutes(math.floor(math.abs(delta) / 60000 + 0.5))
  return delta > 0 and ("in " .. label) or (label .. " late")
end

-- ── the logical day ─────────────────────────────────────────────────────────

-- The day label for `now_ms`, where the day starts at `rollover_hour` local
-- time. 03:30 with a 04:00 boundary still belongs to yesterday.
function M.logical_day(now_ms, rollover_hour)
  local hour = math.floor(tonumber(rollover_hour) or 4) % 24
  local shifted = math.floor((tonumber(now_ms) or 0) / 1000) - hour * 3600
  return os.date("%Y-%m-%d", shifted)
end

-- Moving a due time to a later day keeps its wall clock: the planner shifts the
-- absolute time by whole days, which is what a repeat needs.
function M.shift_due(due_ms, from_day, to_day)
  if not due_ms then return nil end
  local delta = M.days_between(from_day, to_day)
  if not delta then return due_ms end
  return math.floor(due_ms + delta * 86400000)
end

-- Parse "HH:MM" (or "H:MM") into the next occurrence of that local wall clock
-- from now_ms. Returns nil when the text is not a time. Wall-clock maths avoids
-- constructing an epoch from date parts (the Luau CLI treats os.time tables as
-- UTC, which would be wrong here).
function M.due_from_clock(text, now_ms)
  local hours, minutes = tostring(text or ""):match("^(%d%d?):(%d%d)$")
  if not hours then return nil end
  hours, minutes = tonumber(hours), tonumber(minutes)
  if hours > 23 or minutes > 59 then return nil end

  local seconds = math.floor((tonumber(now_ms) or 0) / 1000)
  local now_h = tonumber(os.date("%H", seconds)) or 0
  local now_m = tonumber(os.date("%M", seconds)) or 0
  local delta = (hours * 60 + minutes) - (now_h * 60 + now_m)
  if delta < 0 then delta = delta + 1440 end
  return math.floor(seconds + delta * 60) * 1000
end

-- ── weights, score, snapshot ────────────────────────────────────────────────

function M.priority_mult(priority)
  return PRIORITY_MULT[priority or "med"] or 1
end

-- Minutes of planned effort. An explicit estimate wins; otherwise the task is
-- worth `default_estimate` minutes scaled by priority.
function M.weight(task, default_estimate)
  local estimate = tonumber(task and task.estimate_min) or 0
  if estimate > 0 then return estimate end
  return (tonumber(default_estimate) or 20) * M.priority_mult(task and task.priority)
end

-- Assigned tasks are Today's and Done's; Pending tasks were never planned today.
local function assigned(task)
  return task.status ~= "pending"
end

function M.score(tasks, default_estimate)
  local total, earned = 0, 0
  for _, task in ipairs(tasks or {}) do
    if assigned(task) then
      local weight = M.weight(task, default_estimate)
      total = total + weight
      earned = earned + weight * clamp_progress(task.progress) / 100
    end
  end
  if total <= 0 then return 0 end
  return round(earned / total * 100)
end

-- The frozen numbers for one closed day. `closed` stays "ok" unless the caller
-- knows the shell was off (then "missed").
function M.snapshot(day, tasks, carried_in, default_estimate)
  local result = {
    day = day,
    assigned = 0,
    done = 0,
    carried_in = tonumber(carried_in) or 0,
    score = 0,
    effort_assigned = 0,
    effort_done = 0,
    on_time = 0,
    on_time_total = 0,
    avg_progress = 0,
    top3_done = 0,
    by_tag = {},
    closed = "ok",
  }
  local effort_assigned, effort_done = 0, 0
  local progress_sum, open = 0, 0

  for _, task in ipairs(tasks or {}) do
    if assigned(task) then
      local weight = M.weight(task, default_estimate)
      local progress = clamp_progress(task.progress)
      result.assigned = result.assigned + 1
      effort_assigned = effort_assigned + weight
      effort_done = effort_done + weight * progress / 100

      local tag = task.tag
      if type(tag) ~= "string" or tag == "" then tag = "untagged" end
      result.by_tag[tag] = (result.by_tag[tag] or 0) + 1

      if progress >= 100 then
        result.done = result.done + 1
      else
        open = open + 1
        progress_sum = progress_sum + progress
      end

      if task.due_ms then
        result.on_time_total = result.on_time_total + 1
        if progress >= 100 and task.completed_ms and task.completed_ms <= task.due_ms then
          result.on_time = result.on_time + 1
        end
      end
    end
  end

  result.score = M.score(tasks, default_estimate)
  result.effort_assigned = round(effort_assigned)
  result.effort_done = round(effort_done)
  result.avg_progress = open > 0 and round(progress_sum / open) or 0

  -- The focus badge marks the first three tasks in list order; the report's
  -- top-3 hit rate is how many of them reached 100 %.
  local ordered = {}
  for _, task in ipairs(tasks or {}) do
    if assigned(task) then ordered[#ordered + 1] = task end
  end
  table.sort(ordered, function(a, b) return (tonumber(a.order) or 0) < (tonumber(b.order) or 0) end)
  for index = 1, math.min(3, #ordered) do
    if clamp_progress(ordered[index].progress) >= 100 then
      result.top3_done = result.top3_done + 1
    end
  end
  return result
end

-- ── rollover ────────────────────────────────────────────────────────────────

-- A repeat matches the new day when it is daily, or when its weekday list (ISO
-- 1..7) contains it.
function M.repeats_on(task, day)
  local repeat_rule = task and task.recurrence
  if type(repeat_rule) ~= "table" then return false end
  if repeat_rule.kind == "daily" then return true end
  if repeat_rule.kind == "weekdays" then
    local weekday = M.weekday_iso(day)
    for _, candidate in ipairs(repeat_rule.days or {}) do
      if candidate == weekday then return true end
    end
  end
  return false
end

-- What happens to the list when the day closes:
--   * finished tasks are archived (recorded in the snapshot, dropped here),
--   * unfinished tasks move to Pending and gain a carried mark,
--   * pending tasks stay pending,
--   * repeats that match the new day are created fresh unless an open instance
--     with the same title already exists.
-- Returns the snapshot of the closing day and the new task list.
function M.plan_rollover(doc, next_day, now_ms, default_estimate)
  local snapshot = M.snapshot(doc.day, doc.tasks, doc.carried_in, default_estimate)
  local kept, carried, repeats = {}, 0, {}
  local open_titles = {}

  for _, task in ipairs(doc.tasks or {}) do
    if task.status == "today" then
      if clamp_progress(task.progress) >= 100 then
        -- archived into the snapshot; intentionally not carried forward
      else
        task.status = "pending"
        task.carried = (tonumber(task.carried) or 0) + 1
        task.updated_ms = now_ms
        kept[#kept + 1] = task
        open_titles[task.title] = true
        carried = carried + 1
      end
    elseif task.status == "pending" then
      kept[#kept + 1] = task
      open_titles[task.title] = true
    end
    -- "done" tasks are already archived
  end

  for _, task in ipairs(doc.tasks or {}) do
    if type(task.recurrence) == "table" and M.repeats_on(task, next_day) and not open_titles[task.title] then
      local copy = {}
      for key, value in pairs(task) do copy[key] = value end
      copy.id = M.new_id(now_ms)
      copy.progress = 0
      copy.carried = 0
      copy.status = "today"
      copy.completed_ms = nil
      copy.updated_ms = now_ms
      copy.created_ms = now_ms
      copy.due_ms = M.shift_due(task.due_ms, doc.day, next_day)
      kept[#kept + 1] = copy
      open_titles[task.title] = true
      repeats[#repeats + 1] = copy
    end
  end

  for index, task in ipairs(kept) do task.order = index end

  return { snapshot = snapshot, tasks = kept, carried = carried, repeats = repeats }
end

-- Trash entries older than `days` leave for good at rollover.
function M.purge_trash(trash, now_ms, days)
  local keep_days = tonumber(days) or 30
  local threshold = (tonumber(now_ms) or 0) - keep_days * 86400000
  local kept, removed = {}, 0
  for _, entry in ipairs(trash or {}) do
    if (tonumber(entry.deleted_ms) or 0) >= threshold then
      kept[#kept + 1] = entry
    else
      removed = removed + 1
    end
  end
  return kept, removed
end

-- Streak: consecutive closed days scoring at least `threshold` with work on the
-- list. A gap (shell was off) breaks the run rather than being silently bridged.
function M.advance_streak(streak, snapshot, threshold)
  local result = {
    current = tonumber(streak and streak.current) or 0,
    best = tonumber(streak and streak.best) or 0,
    last_counted_day = streak and streak.last_counted_day or nil,
  }
  if snapshot.assigned == 0 then return result end

  local gap = result.last_counted_day and M.days_between(result.last_counted_day, snapshot.day) or nil
  if gap and gap > 1 then result.current = 0 end

  if snapshot.score >= (tonumber(threshold) or 70) then
    result.current = result.current + 1
  else
    result.current = 0
  end
  if result.current > result.best then result.best = result.current end
  result.last_counted_day = snapshot.day
  return result
end

-- ── reports: weekly / monthly summaries ─────────────────────────────────────

local function empty_aggregate()
  return {
    assigned = 0,
    done = 0,
    effort_assigned = 0,
    effort_done = 0,
    on_time = 0,
    on_time_total = 0,
    carryover = 0,
    active_days = 0,
    progress_sum = 0,
    open_count = 0,
    day_score_sum = 0,
    by_tag = {},
  }
end

local function add_snapshot(aggregate, snapshot)
  local assigned_count = tonumber(snapshot.assigned) or 0
  local done_count = tonumber(snapshot.done) or 0
  local open = math.max(0, assigned_count - done_count)

  if assigned_count > 0 then aggregate.active_days = aggregate.active_days + 1 end
  aggregate.assigned = aggregate.assigned + assigned_count
  aggregate.done = aggregate.done + done_count
  aggregate.effort_assigned = aggregate.effort_assigned + (tonumber(snapshot.effort_assigned) or 0)
  aggregate.effort_done = aggregate.effort_done + (tonumber(snapshot.effort_done) or 0)
  aggregate.on_time = aggregate.on_time + (tonumber(snapshot.on_time) or 0)
  aggregate.on_time_total = aggregate.on_time_total + (tonumber(snapshot.on_time_total) or 0)
  aggregate.carryover = aggregate.carryover + open
  aggregate.progress_sum = aggregate.progress_sum + (tonumber(snapshot.avg_progress) or 0) * open
  aggregate.open_count = aggregate.open_count + open
  aggregate.day_score_sum = aggregate.day_score_sum + (tonumber(snapshot.score) or 0)

  for tag, count in pairs(snapshot.by_tag or {}) do
    aggregate.by_tag[tag] = (aggregate.by_tag[tag] or 0) + (tonumber(count) or 0)
  end
end

local function finalize(aggregate)
  local score = aggregate.effort_assigned > 0
    and round(100 * aggregate.effort_done / aggregate.effort_assigned) or 0
  local carryover_rate = aggregate.assigned > 0
    and round(100 * aggregate.carryover / aggregate.assigned) or 0
  local on_time_rate = aggregate.on_time_total > 0
    and round(100 * aggregate.on_time / aggregate.on_time_total) or 0
  local avg_progress = aggregate.open_count > 0
    and round(aggregate.progress_sum / aggregate.open_count) or 0
  local day_score_avg = aggregate.active_days > 0
    and round(aggregate.day_score_sum / aggregate.active_days) or 0

  local tags = {}
  for tag, count in pairs(aggregate.by_tag) do
    tags[#tags + 1] = {
      tag = tag,
      count = count,
      share = aggregate.assigned > 0 and round(100 * count / aggregate.assigned) or 0,
    }
  end
  table.sort(tags, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.tag < b.tag
  end)

  return {
    assigned = aggregate.assigned,
    done = aggregate.done,
    effort_assigned = round(aggregate.effort_assigned),
    effort_done = round(aggregate.effort_done),
    score = score,
    carryover = aggregate.carryover,
    carryover_rate = carryover_rate,
    on_time = aggregate.on_time,
    on_time_total = aggregate.on_time_total,
    on_time_rate = on_time_rate,
    avg_progress = avg_progress,
    active_days = aggregate.active_days,
    day_score_avg = day_score_avg,
    by_tag = tags,
  }
end

-- Aggregate a list of history snapshots (or the report's day slice).
function M.aggregate(snapshots)
  local aggregate = empty_aggregate()
  for _, snapshot in ipairs(snapshots or {}) do
    add_snapshot(aggregate, snapshot)
  end
  return finalize(aggregate)
end

-- The most recent broken streak inside [start_day, end_day], using the whole
-- history for context so a break on the first day of a week still knows the
-- run that preceded it. Only closed days are walked: a live day scoring low is
-- not a break yet.
local function find_streak_break(history_days, start_day, end_day, threshold)
  local rows = {}
  for _, snapshot in ipairs(history_days or {}) do
    if type(snapshot) == "table" and type(snapshot.day) == "string" then rows[#rows + 1] = snapshot end
  end
  table.sort(rows, function(a, b) return a.day < b.day end)

  local run, found = 0, nil
  for _, snapshot in ipairs(rows) do
    local assigned_count = tonumber(snapshot.assigned) or 0
    local score = tonumber(snapshot.score) or 0
    if assigned_count > 0 and score >= threshold then
      run = run + 1
    else
      if assigned_count > 0 and score < threshold and run >= 2
        and snapshot.day >= start_day and snapshot.day <= end_day then
        found = {
          day = snapshot.day,
          run = run,
          left = assigned_count - (tonumber(snapshot.done) or 0),
        }
      end
      run = 0
    end
  end
  return found
end

local function best_weekday(days)
  local totals, counts, samples = {}, {}, {}
  for _, entry in ipairs(days or {}) do
    local assigned_count = tonumber(entry.assigned) or 0
    local weekday = entry.day and M.weekday_iso(entry.day)
    if entry.has_data and assigned_count > 0 and weekday then
      totals[weekday] = (totals[weekday] or 0) + (tonumber(entry.score) or 0)
      counts[weekday] = (counts[weekday] or 0) + 1
      samples[weekday] = samples[weekday] or entry.day
    end
  end

  local best
  for weekday = 1, 7 do
    if counts[weekday] then
      local average = round(totals[weekday] / counts[weekday])
      if not best or average > best.score then
        best = { weekday = weekday, day = samples[weekday], score = average }
      end
    end
  end
  return best
end

-- Deterministic insight rules (PLAN §6.2). No AI, no clock: everything comes
-- from the report's own numbers. At most `limit` rules are shown, in priority
-- order, with the steady-week line when none fires.
function M.insights(report, opts)
  opts = opts or {}
  local threshold = tonumber(opts.threshold) or 70
  local cap = tonumber(opts.cap) or 3
  local limit = math.max(1, tonumber(opts.limit) or 4)
  local rules = {}

  if (report.assigned or 0) > 0 and (report.carryover_rate or 0) > 30 then
    local per_day = report.active_days > 0 and report.assigned / report.active_days or 0
    local excess = math.max(1, round(per_day - cap))
    rules[#rules + 1] = {
      id = "carryover",
      text = string.format(
        "You carried %d of %d tasks. Your plan was ~%d task%s too ambitious — cap it at %d.",
        report.carryover, report.assigned, excess, excess == 1 and "" or "s", cap),
    }
  end

  if report.streak_break then
    local broken = report.streak_break
    rules[#rules + 1] = {
      id = "streak",
      text = string.format("%s broke a %d-day streak at %d task%s left.",
        M.weekday_name(broken.day) or broken.day, broken.run, broken.left,
        broken.left == 1 and "" or "s"),
    }
  end

  if (report.on_time_total or 0) > 0 and (report.assigned or 0) > report.on_time_total then
    local rate_with = report.on_time / report.on_time_total
    local rate_without = (report.done - report.on_time) / (report.assigned - report.on_time_total)
    local lift
    if rate_without <= 0 then
      lift = rate_with > 0 and 100 or 0
    else
      lift = round((rate_with / rate_without - 1) * 100)
    end
    if lift > 20 then
      rules[#rules + 1] = {
        id = "due",
        text = string.format("Tasks with a due time finish %d%% more often. Give the big ones a time.", lift),
      }
    end
  end

  if (report.avg_progress or 0) > 55 then
    rules[#rules + 1] = {
      id = "avg_progress",
      text = string.format(
        "You stop at ~%d%% a lot — those tasks are too big. Split anything over 45 min.",
        report.avg_progress),
    }
  end

  local power = best_weekday(report.days)
  if power and (report.active_days or 0) >= 3 and power.score >= (report.day_score_avg or 0) + 5 then
    rules[#rules + 1] = {
      id = "weekday",
      text = string.format("%ss are your power day. Schedule the scary task there.",
        WEEKDAYS[power.weekday]),
    }
  end

  if #rules == 0 then
    return { {
      id = "steady",
      text = report.period == "monthly"
        and "A steady month. Nothing to improve — suspiciously good."
        or "A steady week. Nothing to improve — suspiciously good.",
    } }
  end

  local selected = {}
  for index = 1, math.min(#rules, limit) do selected[index] = rules[index] end
  return selected
end

-- Build the weekly or monthly report. `today` is the core's logical day; no
-- clock is read here. History is the source for closed days, the caller's live
-- snapshot overrides the current day.
function M.report(history_days, live_snapshot, period, today, opts)
  opts = opts or {}
  local start_day, end_day = M.period_range(period, today)
  if not start_day then return nil end

  local by_day = {}
  for _, snapshot in ipairs(history_days or {}) do
    if type(snapshot) == "table" and type(snapshot.day) == "string"
      and snapshot.day >= start_day and snapshot.day <= end_day and snapshot.day <= today then
      by_day[snapshot.day] = snapshot
    end
  end
  if type(live_snapshot) == "table" and live_snapshot.day == today
    and today >= start_day and today <= end_day then
    local live = {}
    for key, value in pairs(live_snapshot) do live[key] = value end
    live.live = true
    by_day[today] = live
  end

  local elapsed_end = end_day < today and end_day or today
  local days, chart = {}, {}
  local aggregate = empty_aggregate()
  for _, day in ipairs(M.day_list(start_day, elapsed_end)) do
    local snapshot = by_day[day]
    local score = snapshot and (tonumber(snapshot.score) or 0) or 0
    days[#days + 1] = {
      day = day,
      weekday = M.weekday_name(day, true),
      score = score,
      assigned = snapshot and (tonumber(snapshot.assigned) or 0) or 0,
      done = snapshot and (tonumber(snapshot.done) or 0) or 0,
      has_data = snapshot ~= nil,
      live = snapshot and snapshot.live or false,
    }
    chart[#chart + 1] = math.max(0, math.min(1, score / 100))
    if snapshot then add_snapshot(aggregate, snapshot) end
  end

  local summary = finalize(aggregate)

  local best, worst
  for _, entry in ipairs(days) do
    if entry.has_data and entry.assigned > 0 then
      if not best or entry.score > best.score then best = { day = entry.day, score = entry.score } end
      if not worst or entry.score < worst.score then worst = { day = entry.day, score = entry.score } end
    end
  end

  local previous_score = nil
  local previous_start, previous_end = M.previous_range(period, start_day)
  if previous_start then
    local previous_aggregate = empty_aggregate()
    for _, snapshot in ipairs(history_days or {}) do
      if type(snapshot) == "table" and type(snapshot.day) == "string"
        and snapshot.day >= previous_start and snapshot.day <= previous_end then
        add_snapshot(previous_aggregate, snapshot)
      end
    end
    if previous_aggregate.assigned > 0 then
      previous_score = finalize(previous_aggregate).score
    end
  end

  local result = {
    period = period,
    day = today,
    start_day = start_day,
    end_day = end_day,
    label = M.range_label(start_day, end_day),
    month_label = M.month_label(today),
    days = days,
    chart = chart,
  }
  for key, value in pairs(summary) do result[key] = value end
  result.best = best
  result.worst = worst
  result.streak_break = find_streak_break(history_days, start_day, elapsed_end,
    tonumber(opts.threshold) or 70)
  if previous_score then
    result.trend = { score = previous_score, delta = result.score - previous_score }
  end
  result.insights = M.insights(result, opts)
  return result
end

-- Markdown rendering for an export. `generated` is passed in so the output is
-- deterministic under test; core supplies the wall-clock label.
function M.report_markdown(report, generated)
  if type(report) ~= "table" then return "" end
  local lines = {}
  local function line(text) lines[#lines + 1] = text end

  line(string.format("# medo — %s report", report.period or "weekly"))
  line("")
  line(string.format("**%s**%s", report.label or "",
    generated and (" · generated " .. generated) or ""))
  line("")
  line(string.format(
    "**Score %d%%** · %d/%d done · %d carried (%d%%) · on time %d%% · avg at close %d%%",
    report.score or 0, report.done or 0, report.assigned or 0, report.carryover or 0,
    report.carryover_rate or 0, report.on_time_rate or 0, report.avg_progress or 0))
  line("")
  line("| Metric | Value |")
  line("| --- | --- |")
  line(string.format("| Score | %d%% |", report.score or 0))
  line(string.format("| Tasks done | %d / %d |", report.done or 0, report.assigned or 0))
  line(string.format("| Carried over | %d (%d%%) |", report.carryover or 0, report.carryover_rate or 0))
  line(string.format("| On time | %d / %d (%d%%) |",
    report.on_time or 0, report.on_time_total or 0, report.on_time_rate or 0))
  line(string.format("| Avg progress at close | %d%% |", report.avg_progress or 0))
  line(string.format("| Effort | %s done of %s planned |",
    M.fmt_minutes(report.effort_done), M.fmt_minutes(report.effort_assigned)))
  line(string.format("| Best day | %s |", report.best
    and string.format("%s (%d%%)", M.day_label(report.best.day), report.best.score) or "—"))
  line(string.format("| Worst day | %s |", report.worst
    and string.format("%s (%d%%)", M.day_label(report.worst.day), report.worst.score) or "—"))
  if report.trend then
    line(string.format("| Trend | %+d pts vs the previous %s |", report.trend.delta,
      report.period == "monthly" and "month" or "week"))
  end

  line("")
  line("## Days")
  line("")
  line("| Day | Score | Done / assigned |")
  line("| --- | --- | --- |")
  for _, entry in ipairs(report.days or {}) do
    if entry.has_data then
      line(string.format("| %s | %d%% | %d / %d |",
        M.day_label(entry.day), entry.score or 0, entry.done or 0, entry.assigned or 0))
    else
      line(string.format("| %s | — | — |", M.day_label(entry.day)))
    end
  end

  line("")
  line("## Tags")
  line("")
  if #(report.by_tag or {}) == 0 then
    line("- no tagged tasks")
  else
    for _, tag in ipairs(report.by_tag) do
      line(string.format("- %s: %d (%d%%)",
        tag.tag == "untagged" and "untagged" or ("#" .. tag.tag), tag.count, tag.share))
    end
  end

  line("")
  line("## Insights")
  line("")
  for _, insight in ipairs(report.insights or {}) do
    line("- " .. tostring(insight.text))
  end
  line("")
  return table.concat(lines, "\n")
end

-- ── dashboard helpers ───────────────────────────────────────────────────────

-- Last `count` days ending on `today`, oldest first, scores normalized to the
-- 0..1 range ui.graph wants. Missing days (shell off) are zero, never invented.
function M.sparkline(history_days, live_snapshot, today, count)
  local size = math.max(1, math.floor(tonumber(count) or 7))
  local ordinal = M.to_ordinal(today)
  if not ordinal then return {} end

  local by_day = {}
  for _, snapshot in ipairs(history_days or {}) do
    if type(snapshot) == "table" and type(snapshot.day) == "string" then
      by_day[snapshot.day] = snapshot
    end
  end
  if type(live_snapshot) == "table" and type(live_snapshot.day) == "string" then
    by_day[live_snapshot.day] = live_snapshot
  end

  local rows = {}
  for offset = size - 1, 0, -1 do
    local day = M.from_ordinal(ordinal - offset)
    local snapshot = by_day[day]
    local score = snapshot and (tonumber(snapshot.score) or 0) or 0
    rows[#rows + 1] = {
      day = day,
      weekday = M.weekday_name(day, true),
      score = score,
      has_data = snapshot ~= nil,
      value = math.max(0, math.min(1, score / 100)),
    }
  end
  return rows
end

-- The earliest unfinished task with a deadline; overdue counts as due.
function M.next_due(tasks)
  local best
  for _, task in ipairs(tasks or {}) do
    local due = tonumber(task.due_ms)
    if due and due > 0 and task.status ~= "pending" and clamp_progress(task.progress) < 100 then
      if not best or due < best.due_ms then
        best = {
          id = task.id,
          title = task.title,
          due_ms = due,
          progress = clamp_progress(task.progress),
        }
      end
    end
  end
  return best
end

-- Mascot mood for a score. Four bands from PLAN §7.3.
function M.mascot_state(score)
  local value = tonumber(score) or 0
  if value >= 100 then return "celebrating" end
  if value >= 70 then return "proud" end
  if value >= 25 then return "focused" end
  return "sleepy"
end

-- ── notifications ───────────────────────────────────────────────────────────

-- "HH:MM" → minutes since midnight; nil when malformed.
function M.clock_minutes(text)
  local hours, minutes = tostring(text or ""):match("^(%d%d?):(%d%d)$")
  if not hours then return nil end
  hours, minutes = tonumber(hours), tonumber(minutes)
  if hours > 23 or minutes > 59 then return nil end
  return hours * 60 + minutes
end

local function minutes_of_day(now_ms)
  local seconds = math.floor((tonumber(now_ms) or 0) / 1000)
  return (tonumber(os.date("%H", seconds)) or 0) * 60 + (tonumber(os.date("%M", seconds)) or 0)
end

-- A scheduled time has a 60-minute window after its wall clock, so a shell
-- that was asleep at 08:00 still gets the morning digest at 08:40, but a
-- restart at lunchtime does not replay it. Wraps across midnight.
function M.scheduled_window(now_ms, target_text)
  local target = M.clock_minutes(target_text)
  if not target then return false end
  return (minutes_of_day(now_ms) - target) % 1440 < 60
end

-- Quiet hours are inclusive at the start and exclusive at the end; a window
-- that crosses midnight is handled in both directions.
function M.in_quiet_hours(now_ms, start_text, end_text)
  local start_min = M.clock_minutes(start_text)
  local end_min = M.clock_minutes(end_text)
  if not start_min or not end_min or start_min == end_min then return false end
  local minutes = minutes_of_day(now_ms)
  if start_min < end_min then
    return minutes >= start_min and minutes < end_min
  end
  return minutes >= start_min or minutes < end_min
end

function M.morning_notice(today_count, carried_count)
  local planned = tonumber(today_count) or 0
  if planned == 0 then
    return "Morning. Nothing planned yet. Three is a good start."
  end
  return string.format("Morning. %d planned, %d carried. Medo is ready.",
    planned, tonumber(carried_count) or 0)
end

function M.atrisk_notice()
  return "Half the day gone, nothing moved. Still fine."
end

function M.evening_notice(open_count)
  return string.format("%d left. Retry, park or drop?", tonumber(open_count) or 0)
end

function M.due_notice(title, progress)
  return string.format('"%s" is due now (%d%%).', tostring(title or "task"),
    clamp_progress(progress))
end

function M.lead_notice(minutes, title)
  return string.format("%d min to \"%s\".", math.max(1, tonumber(minutes) or 1),
    tostring(title or "task"))
end

function M.weekly_notice(report)
  if type(report) ~= "table" then return "Your week is ready." end
  return string.format("Your week: %d done, %d carried, %d%%.",
    report.done or 0, report.carryover or 0, report.score or 0)
end

function M.monthly_notice(report)
  if type(report) ~= "table" then return "Your month is ready." end
  return string.format("%s in review — %d%% efficiency.",
    report.month_label or "The month", report.score or 0)
end

-- The reminder decision for one tick. It is pure: `now_ms`, the logical day,
-- the tasks, the settings and the persisted dedupe map go in; notifications
-- that are due and not yet fired come out. Weekly/monthly entries carry no
-- body because the caller builds the report they need.
function M.notifications(now_ms, day, tasks, context, settings, notified)
  settings = settings or {}
  context = context or {}
  notified = notified or {}
  local entries = {}
  local quiet = M.in_quiet_hours(now_ms, settings.quiet_start or "22:00", settings.quiet_end or "07:00")
  local notify = settings.notify or {}
  local default_lead = tonumber(settings.lead_min) or 15

  local function fresh(key) return not notified[key] end
  local function add(key, kind, title, body)
    if fresh(key) then
      entries[#entries + 1] = { key = key, kind = kind, title = title, body = body }
    end
  end

  -- Due alerts are the one thing quiet hours never suppress.
  if notify.due ~= false then
    for _, task in ipairs(tasks or {}) do
      local due = tonumber(task.due_ms)
      local progress = clamp_progress(task.progress)
      if due and due > 0 and task.status ~= "pending" and progress < 100
        and now_ms >= due and now_ms - due <= 60 * 60000 then
        add(string.format("due:%s:%d", tostring(task.id), due), "due", "medo",
          M.due_notice(task.title, progress))
      end
    end
  end

  if notify.lead ~= false and not quiet then
    for _, task in ipairs(tasks or {}) do
      local due = tonumber(task.due_ms)
      local progress = clamp_progress(task.progress)
      local lead = tonumber(task.lead_min) or 0
      if lead <= 0 then lead = default_lead end
      if due and due > now_ms and task.status ~= "pending" and progress < 100
        and lead > 0 and due - now_ms <= lead * 60000 then
        add(string.format("lead:%s:%d", tostring(task.id), due), "lead", "medo",
          M.lead_notice(math.floor((due - now_ms) / 60000 + 0.5), task.title))
      end
    end
  end

  if not quiet then
    local today_count = tonumber(context.today_count) or 0
    local open_count = tonumber(context.open_count) or 0
    local carried_count = tonumber(context.carried_count) or 0
    local score = tonumber(context.score) or 0

    if notify.morning ~= false and M.scheduled_window(now_ms, settings.morning_time or "08:00") then
      add("morning:" .. tostring(day), "morning", "medo",
        M.morning_notice(today_count, carried_count))
    end

    if notify.atrisk ~= false and score < 30 and open_count > 0
      and M.scheduled_window(now_ms, settings.atrisk_time or "15:00") then
      add("atrisk:" .. tostring(day), "atrisk", "medo", M.atrisk_notice())
    end

    if notify.evening ~= false and open_count > 0
      and M.scheduled_window(now_ms, settings.evening_time or "21:00") then
      add("evening:" .. tostring(day), "evening", "medo", M.evening_notice(open_count))
    end

    local weekday = M.weekday_iso(day)
    if notify.weekly ~= false and weekday and weekday == tonumber(settings.weekly_day)
      and M.scheduled_window(now_ms, settings.weekly_time or "20:00") then
      add("weekly:" .. tostring(day), "weekly", "medo", nil)
    end

    local _, _, day_of_month = M.day_parts(day)
    if notify.monthly ~= false and day_of_month == 1
      and M.scheduled_window(now_ms, settings.monthly_time or "20:00") then
      add("monthly:" .. tostring(day), "monthly", "medo", nil)
    end
  end

  return entries
end

-- ── ids and small helpers ───────────────────────────────────────────────────

local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"

function M.base36(number)
  local value = math.floor(tonumber(number) or 0)
  if value <= 0 then return "0" end
  local out = ""
  while value > 0 do
    local digit = value % 36
    out = BASE36:sub(digit + 1, digit + 1) .. out
    value = math.floor(value / 36)
  end
  return out
end

-- Stable, sortable-ish id; `suffix` exists so tests are deterministic.
function M.new_id(now_ms, suffix)
  local tail = suffix or string.format("%04x", math.random(0, 0xffff))
  return "t_" .. M.base36(now_ms) .. "_" .. tail
end

function M.clamp_progress(value)
  return clamp_progress(value)
end

function M.default_doc(day, rollover_hour)
  return {
    schema = M.SCHEMA,
    revision = 0,
    day = day,
    rollover_hour = tonumber(rollover_hour) or 4,
    carried_in = 0,
    streak = { current = 0, best = 0, last_counted_day = nil },
    tasks = {},
    trash = {},
  }
end

return M
