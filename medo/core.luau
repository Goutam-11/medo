--!nonstrict
-- medo core service — the single writer of the task store.
--
-- Owns the logical day, rollover, persistence and the `view` snapshot the bar
-- and panel render. Other entries never touch disk: the panel sends intents
-- through noctalia.state["cmd"], this service applies them, saves and publishes.

local store = require("./store.luau")
local logic = require("./logic.luau")

local DEFAULTS = {
  rollover_hour = 4,
  default_estimate = 20,
  streak_threshold = 70,
  trash_days = 30,
  cap_enabled = true,
  daily_cap = 3,
}

local doc
local history_days = {}
local report = nil
local last_export = nil
local last_published = nil
local last_cmd_rev = 0

local function now()
  return noctalia.nowMs()
end

local function setting(key)
  local value = noctalia.getConfig(key)
  if value == nil then return DEFAULTS[key] end
  return value
end

local function today()
  return logic.logical_day(now(), setting("rollover_hour"))
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function persist()
  local ok, err = store.save(doc)
  if not ok then
    noctalia.notifyError("medo", "could not save tasks: " .. tostring(err))
  end
  return ok
end

-- ── the published snapshot ──────────────────────────────────────────────────

local function tasks_with(status)
  local rows = {}
  for _, task in ipairs(doc.tasks) do
    if task.status == status then rows[#rows + 1] = task end
  end
  table.sort(rows, function(a, b) return (tonumber(a.order) or 0) < (tonumber(b.order) or 0) end)
  return rows
end

local function counts()
  local done, total, carried, pending = 0, 0, 0, 0
  for _, task in ipairs(doc.tasks) do
    if task.status == "pending" then
      pending = pending + 1
      if (tonumber(task.carried) or 0) > 0 then carried = carried + 1 end
    elseif task.status ~= "trash" then
      total = total + 1
      if logic.clamp_progress(task.progress) >= 100 then done = done + 1 end
    end
  end
  return done, total, carried, pending
end

-- Closed days live in history.json; the service keeps them in memory so the
-- view can build the sparkline and reports without a disk read per publish.
local function refresh_history()
  local data = store.load_history()
  if type(data) == "table" and type(data.days) == "table" then
    history_days = data.days
  else
    history_days = {}
  end
end

-- What the current day looks like if it closed now; also the source of the
-- live score and of the report's final bar.
local function live_snapshot()
  return logic.snapshot(doc.day, doc.tasks, doc.carried_in, setting("default_estimate"))
end

local function view()
  local done, total, carried, pending = counts()
  local snapshot = live_snapshot()
  return {
    day = doc.day,
    done = done,
    total = total,
    score = snapshot.score,
    carried = carried,
    carried_in = tonumber(doc.carried_in) or 0,
    pending_count = pending,
    streak = (doc.streak and doc.streak.current) or 0,
    streak_best = (doc.streak and doc.streak.best) or 0,
    target = tonumber(setting("streak_threshold")) or 70,
    next_due = logic.next_due(doc.tasks),
    sparkline = logic.sparkline(history_days, snapshot, doc.day, 7),
    report = report,
    last_export = last_export,
    revision = doc.revision or 0,
    now = now(),
    ready = true,
    rollover_hour = setting("rollover_hour"),
    cap = { enabled = setting("cap_enabled") ~= false, value = setting("daily_cap") },
    today_tasks = tasks_with("today"),
    pending_tasks = tasks_with("pending"),
    trash_count = #(doc.trash or {}),
  }
end

local function publish(force)
  if not force and doc.revision == last_published then return end
  last_published = doc.revision
  noctalia.state.set("view", view())
end

-- ── reports and exports ─────────────────────────────────────────────────────

local function build_report(period)
  local chosen = period == "monthly" and "monthly" or "weekly"
  local snapshot = logic.report(history_days, live_snapshot(), chosen, doc.day, {
    threshold = tonumber(setting("streak_threshold")) or 70,
    cap = tonumber(setting("daily_cap")) or 3,
    limit = 4,
  })
  if snapshot then
    -- lets the panel notice that a later task change made the report stale
    snapshot.for_revision = doc.revision or 0
  end
  return snapshot
end

-- Render the requested report and write it into export_dir. Markdown is the
-- default (PLAN open decision 7); JSON carries the report object as-is.
local function handle_export(period, format)
  local chosen = period == "monthly" and "monthly" or "weekly"
  local target_format = format == "json" and "json" or "markdown"
  local snapshot = build_report(chosen)
  if not snapshot then
    noctalia.notifyError("medo", "export: could not build the report")
    return false
  end
  report = snapshot

  local dir = store.export_dir(setting("export_dir"))
  local extension = target_format == "json" and "json" or "md"
  local path = string.format("%s/medo-%s-%s.%s", dir, chosen, snapshot.end_day, extension)
  local payload
  if target_format == "json" then
    payload = noctalia.json.encode({
      schema = 1,
      generated_ms = now(),
      report = snapshot,
    }, true)
  else
    payload = logic.report_markdown(snapshot,
      os.date("%Y-%m-%d %H:%M", math.floor(now() / 1000)))
  end
  if not payload then
    noctalia.notifyError("medo", "export: could not encode the report")
    return false
  end

  local ok, err = store.write_text(path, payload)
  if not ok then
    noctalia.notifyError("medo", "export failed: " .. tostring(err))
    return false
  end
  last_export = { path = path, format = target_format, period = chosen, ms = now() }
  noctalia.log("medo: exported " .. path)
  noctalia.notify("medo", "exported " .. path)
  publish(true)
  return true
end

-- ── mutations (each returns whether the document changed) ───────────────────

local function find_task(id)
  for _, task in ipairs(doc.tasks) do
    if task.id == id then return task end
  end
  return nil
end

local function add_task(fields)
  fields = fields or {}
  local title = trim(fields.title)
  if title == "" then return false end
  local due = tonumber(fields.due_ms)
  local task = {
    id = logic.new_id(now()),
    title = title,
    notes = tostring(fields.notes or ""),
    tag = trim(fields.tag),
    priority = fields.priority or "med",
    estimate_min = tonumber(fields.estimate_min) or 0,
    due_ms = (due and due > 0) and due or nil,
    lead_min = tonumber(fields.lead_min) or 0,
    progress = logic.clamp_progress(fields.progress),
    carried = tonumber(fields.carried) or 0,
    recurrence = fields.recurrence,
    status = fields.status == "pending" and "pending" or "today",
    order = #doc.tasks + 1,
    created_ms = now(),
    completed_ms = nil,
  }
  if task.progress >= 100 then task.completed_ms = now() end
  doc.tasks[#doc.tasks + 1] = task
  return true
end

local function set_progress(id, progress)
  local task = find_task(id)
  if not task then return false end
  task.progress = logic.clamp_progress(progress)
  task.completed_ms = task.progress >= 100 and (task.completed_ms or now()) or nil
  task.updated_ms = now()
  return true
end

local function set_status(id, status)
  local task = find_task(id)
  if not task or task.status == status then return false end
  task.status = status
  task.updated_ms = now()
  if status == "today" then
    task.order = #doc.tasks + 1
  end
  return true
end

local function delete_task(id)
  for index, task in ipairs(doc.tasks) do
    if task.id == id then
      table.remove(doc.tasks, index)
      doc.trash = doc.trash or {}
      doc.trash[#doc.trash + 1] = { task = task, deleted_ms = now() }
      return true
    end
  end
  return false
end

local function edit_task(fields)
  local task = find_task(fields.id)
  if not task then return false end
  if type(fields.title) == "string" and trim(fields.title) ~= "" then task.title = trim(fields.title) end
  if fields.estimate_min ~= nil then task.estimate_min = tonumber(fields.estimate_min) or 0 end
  if fields.due_ms ~= nil then
    local due = tonumber(fields.due_ms) or 0
    task.due_ms = due > 0 and due or nil
  end
  if type(fields.tag) == "string" then task.tag = trim(fields.tag) end
  if type(fields.priority) == "string" then task.priority = fields.priority end
  if type(fields.notes) == "string" then task.notes = fields.notes end
  task.updated_ms = now()
  return true
end

local function commit(changed)
  if changed then
    persist()
    publish(true)
  end
  return changed
end

-- ── rollover ────────────────────────────────────────────────────────────────

local function rollover(target_day, reason)
  local plan = logic.plan_rollover(doc, target_day, now(), setting("default_estimate"))
  local purged
  doc.tasks = plan.tasks
  doc.trash, purged = logic.purge_trash(doc.trash, now(), setting("trash_days"))
  doc.carried_in = plan.carried
  doc.streak = logic.advance_streak(doc.streak, plan.snapshot, setting("streak_threshold"))
  doc.day = target_day
  doc.closed_days = (tonumber(doc.closed_days) or 0) + 1

  store.append_history(plan.snapshot)
  refresh_history()
  report = nil
  store.backup(doc, plan.snapshot.day)
  persist()
  publish(true)

  noctalia.log(string.format(
    "medo: closed %s (%s) score=%d carried=%d purged=%s",
    plan.snapshot.day, tostring(reason), plan.snapshot.score, plan.carried, tostring(purged)
  ))
  return plan
end

-- ── boot ────────────────────────────────────────────────────────────────────

local function seed_demo()
  doc.tasks = {}
  doc.carried_in = 1
  add_task({ title = "Finish the store", estimate_min = 60, priority = "high", progress = 40, due_ms = now() + 2 * 3600000 })
  add_task({ title = "Read the plan", estimate_min = 20, progress = 0 })
  add_task({ title = "Buy milk", estimate_min = 15, tag = "life", progress = 0 })
  add_task({ title = "Old idea", estimate_min = 30, status = "pending", carried = 2, progress = 20 })
  persist()
  publish(true)
  noctalia.notify("medo", string.format("seeded %d tasks for %s", #doc.tasks, doc.day))
end

-- ── report fixture (debug) ──────────────────────────────────────────────────
--
-- 14 closed days ending yesterday, then three live tasks. Progress lists are
-- (60 min, 30 min, 20 min) so a day's score is hand-checkable from the weights:
--   100/60/0 → 71, 100/60/100 → 89, 100/100/100 → 100, 80/0/0 → 44,
--   100/100/60 → 93, 100/0/0 → 55, 100/100/0 → 82.
local REPORT_PATTERN = {
  { 100, 60, 0 }, { 100, 60, 100 }, { 100, 100, 100 }, { 80, 0, 0 },
  { 100, 100, 60 }, { 100, 0, 0 }, { 100, 100, 0 }, { 100, 60, 0 },
  { 100, 60, 100 }, { 100, 100, 100 }, { 100, 100, 0 }, { 80, 0, 0 },
  { 100, 100, 100 }, { 100, 100, 60 },
}

local FIXTURE_TASKS = {
  { title = "Deep work", estimate_min = 60, tag = "work" },
  { title = "Review", estimate_min = 30, tag = "work" },
  { title = "Inbox zero", estimate_min = 20, tag = "life" },
}

local function fixture_day_tasks(day, progress_list)
  local y, m, d = day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  local due = os.time({
    year = tonumber(y), month = tonumber(m), day = tonumber(d),
    hour = 17, min = 0, sec = 0,
  }) * 1000
  local tasks = {}
  for index, spec in ipairs(FIXTURE_TASKS) do
    local progress = progress_list[index] or 0
    tasks[#tasks + 1] = {
      id = logic.new_id(logic.to_ordinal(day) * 10 + index, string.format("%04x", index)),
      title = spec.title,
      notes = "",
      tag = spec.tag,
      priority = "med",
      estimate_min = spec.estimate_min,
      due_ms = index == 1 and due or nil,
      lead_min = 0,
      progress = progress,
      carried = 0,
      recurrence = nil,
      status = "today",
      order = index,
      created_ms = due - 8 * 3600000,
      completed_ms = progress >= 100 and (due - 3600000) or nil,
    }
  end
  return tasks
end

local function seed_report()
  local today_ordinal = logic.to_ordinal(doc.day)
  if not today_ordinal then return end
  local days = {}
  for index = 1, #REPORT_PATTERN do
    local day = logic.from_ordinal(today_ordinal - #REPORT_PATTERN + index - 1)
    days[#days + 1] = logic.snapshot(day, fixture_day_tasks(day, REPORT_PATTERN[index]), 0,
      setting("default_estimate"))
  end
  store.save_history({ schema = 1, days = days })
  refresh_history()

  doc.tasks = {}
  doc.carried_in = 2
  add_task({
    title = "Ship phase 3", estimate_min = 90, progress = 60, tag = "work",
    priority = "high", carried = 1, due_ms = now() + 90 * 60000,
  })
  add_task({ title = "Review the report", estimate_min = 30, progress = 100, tag = "work", carried = 1 })
  add_task({ title = "Water plants", estimate_min = 15, progress = 0, tag = "life" })

  -- replay the seed through the real streak rule so the dashboard number is
  -- consistent with the history it is showing
  local streak = { current = 0, best = 0, last_counted_day = nil }
  for _, snapshot in ipairs(days) do
    streak = logic.advance_streak(streak, snapshot, setting("streak_threshold"))
  end
  doc.streak = streak
  report = nil

  persist()
  publish(true)
  noctalia.notify("medo", string.format("report fixture: %d closed days + %d live tasks (streak %d)",
    #days, #doc.tasks, streak.current))
end

local function boot()
  local loaded, err = store.load()
  if loaded then
    doc = loaded
  else
    if err == "corrupt" then
      noctalia.notifyError("medo", "tasks.json is unreadable and no backup recovered it; starting a fresh list")
    end
    doc = logic.default_doc(today(), setting("rollover_hour"))
    persist()
  end

  -- catch up a day (or several) that passed while the shell was off
  local day = today()
  if day > doc.day and logic.days_between(doc.day, day) > 0 then
    rollover(day, "catch-up")
  elseif day < doc.day then
    -- clock moved backwards; trust the clock and keep the list
    doc.day = day
    persist()
  end

  refresh_history()
  publish(true)
end

function update()
  local day = today()
  if day ~= doc.day and logic.days_between(doc.day, day) > 0 then
    rollover(day, "scheduled")
  end
  publish()
end

-- ── the panel's command channel ─────────────────────────────────────────────

-- Panel intents arrive as { kind, rev, ... }. `rev` is monotonic per panel
-- session, so a duplicated delivery is applied once.
local function apply_command(cmd)
  if type(cmd) ~= "table" then return end
  local rev = tonumber(cmd.rev) or 0
  if rev <= last_cmd_rev then return end
  last_cmd_rev = rev

  local kind = cmd.kind
  local changed = false
  if kind == "add" then
    changed = add_task(cmd)
  elseif kind == "progress" then
    changed = set_progress(cmd.id, cmd.progress)
  elseif kind == "complete" then
    changed = set_progress(cmd.id, 100)
  elseif kind == "reopen" then
    changed = set_progress(cmd.id, 0)
  elseif kind == "park" then
    changed = set_status(cmd.id, "pending")
  elseif kind == "promote" then
    changed = set_status(cmd.id, "today")
  elseif kind == "delete" then
    changed = delete_task(cmd.id)
  elseif kind == "edit" then
    changed = edit_task(cmd)
  elseif kind == "report" then
    report = build_report(cmd.period)
    publish(true)
    return
  elseif kind == "export" then
    handle_export(cmd.period, cmd.format)
    return
  end
  commit(changed)
end

noctalia.state.watch("cmd", apply_command)

-- ── IPC surface (development and testing) ───────────────────────────────────

local function summary()
  local done, total, carried, pending = counts()
  return string.format("%s · %d/%d done · %d%% · pending %d (carried %d) · streak %d",
    doc.day, done, total, logic.score(doc.tasks, setting("default_estimate")),
    pending, carried, (doc.streak and doc.streak.current) or 0)
end

function onIpc(event, payload)
  if event == "ping" then
    noctalia.notify("medo", summary())
  elseif event == "debug-seed-demo" then
    seed_demo()
  elseif event == "debug-seed-report" then
    seed_report()
  elseif event == "debug-rollover" then
    local target = logic.next_day(doc.day)
    local plan = rollover(target, "debug")
    noctalia.notify("medo", string.format("closed %s · carried %d · repeats %d",
      plan.snapshot.day, plan.carried, #plan.repeats))
  elseif event == "debug-report" and type(payload) == "string" then
    report = build_report(payload)
    publish(true)
    if report then
      noctalia.notify("medo", string.format("%s %s · %d%% · %d/%d · %d insight(s)",
        report.period, report.label, report.score, report.done, report.assigned,
        #report.insights))
    else
      noctalia.notifyError("medo", "report: unknown period")
    end
  elseif event == "debug-export" and type(payload) == "string" then
    local period, format = payload:match("^%s*(%a+)%s*(%a*)")
    handle_export(period, format)
  elseif event == "debug-reset-history" then
    store.save_history({ schema = 1, days = {} })
    refresh_history()
    report = nil
    publish(true)
    noctalia.notify("medo", "history cleared")
  elseif event == "debug-dump" then
    noctalia.notify("medo", string.format("%s\n%s\nrev %d · %d tasks · %d closed days\n%s",
      tostring(store.data_path()), summary(), doc.revision or 0, #doc.tasks, #history_days,
      tostring(store.history_path())))
  elseif event == "debug-backdate" and type(payload) == "string" then
    -- deliberately lies about the day so a restart exercises catch-up rollover
    doc.day = payload
    persist()
    noctalia.notify("medo", "day backdated to " .. payload .. " (restart the plugin to test catch-up)")
  elseif event == "debug-reset" then
    doc = logic.default_doc(today(), setting("rollover_hour"))
    persist()
    publish(true)
    noctalia.notify("medo", "list reset")
  elseif event == "add" and type(payload) == "string" then
    local ok, fields = pcall(noctalia.json.decode, payload)
    if ok and type(fields) == "table" then
      commit(add_task(fields))
      noctalia.notify("medo", string.format("added '%s'", tostring(fields.title or "task")))
    else
      noctalia.notifyError("medo", "add: payload is not JSON")
    end
  elseif (event == "park" or event == "promote") and type(payload) == "string" then
    local ok, fields = pcall(noctalia.json.decode, payload)
    if ok and type(fields) == "table" then
      local status = event == "park" and "pending" or "today"
      if not commit(set_status(fields.id, status)) then
        noctalia.notifyError("medo", event .. ": unknown task or bad payload")
      end
    end
  elseif event == "delete" and type(payload) == "string" then
    local ok, fields = pcall(noctalia.json.decode, payload)
    if ok and type(fields) == "table" then
      if not commit(delete_task(fields.id)) then
        noctalia.notifyError("medo", "delete: unknown task or bad payload")
      end
    end
  elseif event == "progress" and type(payload) == "string" then
    local ok, fields = pcall(noctalia.json.decode, payload)
    if ok and type(fields) == "table" then
      if not commit(set_progress(fields.id, fields.progress)) then
        noctalia.notifyError("medo", "progress: unknown task or bad payload")
      end
    end
  end
end

noctalia.setUpdateInterval(1000)
boot()
