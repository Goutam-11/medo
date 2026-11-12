--!nonstrict
-- medo core service — the single writer of the task store.
--
-- Owns the logical day, rollover, persistence and the `view` snapshot the bar
-- and panel render. Every other entry talks to it through noctalia.state; the
-- panel's command channel lands in Phase 2, the IPC commands below are the
-- development and testing surface.

local store = require("./store.luau")
local logic = require("./logic.luau")

local DEFAULTS = {
  rollover_hour = 4,
  default_estimate = 20,
  streak_threshold = 70,
  trash_days = 30,
}

local doc
local last_published = nil

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

local function persist()
  local ok, err = store.save(doc)
  if not ok then
    noctalia.notifyError("medo", "could not save tasks: " .. tostring(err))
  end
  return ok
end

-- ── the published snapshot ──────────────────────────────────────────────────

local function view()
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

  return {
    day = doc.day,
    done = done,
    total = total,
    score = logic.score(doc.tasks, setting("default_estimate")),
    carried = carried,
    pending = pending,
    streak = (doc.streak and doc.streak.current) or 0,
    revision = doc.revision or 0,
    ready = true,
  }
end

local function publish(force)
  if not force and doc.revision == last_published then return end
  last_published = doc.revision
  noctalia.state.set("view", view())
end

-- ── mutations ───────────────────────────────────────────────────────────────

local function add_task(fields)
  fields = fields or {}
  local task = {
    id = logic.new_id(now()),
    title = tostring(fields.title or "untitled"),
    notes = tostring(fields.notes or ""),
    tag = tostring(fields.tag or ""),
    priority = fields.priority or "med",
    estimate_min = tonumber(fields.estimate_min) or 0,
    due_ms = tonumber(fields.due_ms),
    lead_min = tonumber(fields.lead_min) or 0,
    progress = logic.clamp_progress(fields.progress),
    carried = tonumber(fields.carried) or 0,
    recurrence = fields.recurrence,
    status = fields.status or "today",
    order = #doc.tasks + 1,
    created_ms = now(),
    completed_ms = nil,
  }
  if task.progress >= 100 then task.completed_ms = now() end
  doc.tasks[#doc.tasks + 1] = task
  return task
end

local function find_task(id)
  for _, task in ipairs(doc.tasks) do
    if task.id == id then return task end
  end
  return nil
end

local function set_progress(id, progress)
  local task = find_task(id)
  if not task then return false end
  task.progress = logic.clamp_progress(progress)
  task.completed_ms = task.progress >= 100 and (task.completed_ms or now()) or nil
  task.updated_ms = now()
  return true
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

  publish(true)
end

function update()
  local day = today()
  if day ~= doc.day and logic.days_between(doc.day, day) > 0 then
    rollover(day, "scheduled")
  end
  publish()
end

-- ── IPC surface ─────────────────────────────────────────────────────────────

local function summary()
  local snapshot = view()
  return string.format("%s · %d/%d done · %d%% · carried %d · streak %d",
    snapshot.day, snapshot.done, snapshot.total, snapshot.score, snapshot.carried, snapshot.streak)
end

function onIpc(event, payload)
  if event == "ping" then
    noctalia.notify("medo", summary())
  elseif event == "debug-seed-demo" then
    seed_demo()
  elseif event == "debug-rollover" then
    local target = logic.next_day(doc.day)
    local plan = rollover(target, "debug")
    noctalia.notify("medo", string.format("closed %s · carried %d · repeats %d",
      plan.snapshot.day, plan.carried, #plan.repeats))
  elseif event == "debug-dump" then
    noctalia.notify("medo", string.format("%s\n%s\nrev %d · %d tasks · history %s",
      tostring(store.data_path()), summary(), doc.revision or 0, #doc.tasks,
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
      add_task(fields)
      persist()
      publish(true)
      noctalia.notify("medo", string.format("added '%s'", tostring(fields.title or "task")))
    else
      noctalia.notifyError("medo", "add: payload is not JSON")
    end
  elseif event == "progress" and type(payload) == "string" then
    local ok, fields = pcall(noctalia.json.decode, payload)
    if ok and type(fields) == "table" and set_progress(fields.id, fields.progress) then
      persist()
      publish(true)
    else
      noctalia.notifyError("medo", "progress: unknown task or bad payload")
    end
  end
end

noctalia.setUpdateInterval(1000)
boot()
