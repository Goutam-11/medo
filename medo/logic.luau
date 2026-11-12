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
