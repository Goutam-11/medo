--!nonstrict
-- medo panel — Today and Pending, with the progress slider and keyboard-first
-- actions. The panel never touches disk: every change goes to the core service
-- as a command on noctalia.state["cmd"], and the service publishes a new view.

local logic = require("./logic.luau")

-- Bundled assets (Phase 4c). The font registers once per entry; a missing file
-- or `mascot_enabled = false` falls back to the shell font and the text mascot.
local HEADER_FONT = noctalia.loadFont("assets/fonts/Baloo2-SemiBold.ttf")

-- Every user-visible string comes from translations/en.json (see
-- tools/check_manifest.py, which fails on a key that is not there).
local function tr(key, subst)
  return noctalia.tr(key, subst)
end
local asset_checked = {}

local function asset(name)
  if asset_checked[name] == nil then
    asset_checked[name] = noctalia.fileExists(name) and name or false
  end
  return asset_checked[name] or nil
end

local function mascot_image(state, size)
  if noctalia.getConfig("mascot_enabled") == false then return nil end
  local path = asset("assets/mascot/" .. state .. ".png")
  if not path then return nil end
  return ui.image({ path = path, width = size, height = size, fit = "contain" })
end

local ESTIMATES = { 15, 30, 45, 60, 90 }
local ESTIMATE_LABELS = { "15m", "30m", "45m", "60m", "90m" }
local PRIORITIES = { "low", "med", "high" }

local view = { today_tasks = {}, pending_tasks = {}, cap = { enabled = true, value = 3 } }
local tab = "today"
local period = "weekly"
local last_report_request = nil
local selected = 1
local overrides = {}
local editing = nil
local add = { title = "", estimate = 30, time = "", tag = "" }
local add_focus = false
local add_epoch = 0
local cap_pending = nil
local seq = 0

-- ── channel + helpers ───────────────────────────────────────────────────────

local function send(kind, fields)
  fields = fields or {}
  seq = seq + 1
  fields.kind = kind
  fields.rev = noctalia.nowMs() * 1000 + (seq % 1000)
  noctalia.state.set("cmd", fields)
end

local function read_view()
  local snapshot = noctalia.state.get("view")
  if type(snapshot) == "table" then view = snapshot end
  if type(view.today_tasks) ~= "table" then view.today_tasks = {} end
  if type(view.pending_tasks) ~= "table" then view.pending_tasks = {} end
  if type(view.trash_tasks) ~= "table" then view.trash_tasks = {} end
  if type(view.cap) ~= "table" then view.cap = { enabled = true, value = 3 } end
end

local function current_rows()
  if tab == "pending" then return view.pending_tasks end
  return view.today_tasks
end

local function estimate_index(minutes)
  local value = tonumber(minutes) or 0
  local best = 2
  for index, candidate in ipairs(ESTIMATES) do
    if value == candidate then return index end
    if value > candidate then best = math.min(#ESTIMATES, index + 1) end
  end
  return best
end

local function priority_index(priority)
  for index, candidate in ipairs(PRIORITIES) do
    if candidate == priority then return index end
  end
  return 2
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function progress_of(task)
  return tonumber(overrides[task.id]) or tonumber(task.progress) or 0
end

local function due_text(task)
  if not task.due_ms then return nil end
  local seconds = task.due_ms / 1000
  local clock = os.date("%H:%M", seconds)
  if os.date("%Y-%m-%d", seconds) ~= view.day then
    return os.date("%a", seconds) .. " " .. clock
  end
  return clock
end

local function is_overdue(task)
  return task.due_ms ~= nil and task.due_ms < (view.now or noctalia.nowMs()) and progress_of(task) < 100
end

local function priority_color(priority)
  if priority == "high" then return "error" end
  if priority == "med" then return "tertiary" end
  return "outline_variant"
end

local function mascot()
  local total = view.total or 0
  local done = view.done or 0
  if total > 0 and done >= total then return "(≧▽≦)" end
  if (view.carried or 0) > 0 then return "(´･_･`)" end
  if total == 0 then return "( ◕‿◕ )" end
  if (view.score or 0) >= 70 then return "(•̀ᴗ•́)" end
  return "(´･ᴗ･`)"
end

-- The blob when the artwork is available, the text face otherwise.
local function mascot_node(size, fontSize)
  local face = logic.mascot_face(logic.mascot_state(view.score), view.carried)
  return mascot_image(face, size) or ui.label({ text = mascot(), fontSize = fontSize, color = "primary" })
end

local function tagline()
  local total = view.total or 0
  local done = view.done or 0
  if total == 0 then return tr("panel.tagline.empty") end
  if done >= total then return tr("panel.tagline.done") end
  if (view.carried or 0) > 0 then return tr("panel.tagline.carried", { count = view.carried }) end
  if (view.score or 0) >= 70 then return tr("panel.tagline.rolling") end
  return tr("panel.tagline.start")
end

-- ── dashboard ───────────────────────────────────────────────────────────────

local MASCOT_COPY = {
  sleepy = "panel.mascot.sleepy",
  focused = "panel.mascot.focused",
  proud = "panel.mascot.proud",
  celebrating = "panel.mascot.celebrating",
}

local function stat_card(label, value, sub, color)
  return ui.column({
    gap = 1,
    padding = 6,
    radius = 10,
    fill = "surface_container",
    flexGrow = 1,
  }, {
    ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
    ui.label({
      text = value,
      fontSize = 14,
      fontWeight = "bold",
      color = color or "on_surface",
      maxLines = 1,
    }),
    ui.label({ text = sub or " ", fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function dashboard_body()
  local score = tonumber(view.score) or 0
  local target = tonumber(view.target) or 70
  local mood = logic.mascot_state(score)
  local mood_color = score >= 70 and "tertiary" or (score >= 25 and "primary" or "on_surface_variant")

  local score_card = ui.column({ gap = 6, padding = 12, radius = 12, fill = "surface_container" }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.label({
        text = string.format("%d%%", score),
        fontSize = 40,
        fontWeight = "bold",
        color = mood_color,
        fontFamily = HEADER_FONT,
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.todays_score"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
          text = tr("panel.done_of", { done = view.done or 0, total = view.total or 0, target = target }),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
    }),
    ui.progress({
      progress = math.max(0, math.min(1, score / 100)),
      marker = math.max(0, math.min(1, target / 100)),
      markerColor = "tertiary",
      fill = "primary",
      track = "surface_container_high",
      height = 10,
      radius = 5,
    }),
  })

  local due = view.next_due
  local due_value, due_sub = tr("panel.nothing_due"), tr("panel.clear_runway")
  if type(due) == "table" and due.due_ms then
    -- read the clock here, not view.now: the 30 s dashboard tick keeps the
    -- countdown honest while the panel stays open
    due_value = logic.countdown_text(due.due_ms, noctalia.nowMs())
    due_sub = due.title or tr("panel.task")
  end

  local stats = ui.row({ gap = 6, align = "stretch" }, {
    stat_card(tr("panel.streak"), "🔥 " .. tostring(view.streak or 0),
      tr("panel.best", { score = view.streak_best or 0 }), "tertiary"),
    stat_card(tr("panel.next_due"), due_value, due_sub),
    stat_card(tr("panel.carried_in"), tostring(view.carried_in or 0), tr("panel.waiting_yesterday")),
  })

  local spark = view.sparkline or {}
  local values, day_labels = {}, {}
  for _, entry in ipairs(spark) do
    values[#values + 1] = entry.value or 0
    day_labels[#day_labels + 1] = ui.label({
      text = (entry.weekday or ""):sub(1, 1),
      fontSize = 8,
      flexGrow = 1,
      textAlign = "center",
      color = entry.has_data and "on_surface_variant" or "outline_variant",
    })
  end
  local spark_card = ui.column({ gap = 4, padding = 10, radius = 10, fill = "surface_container" }, {
    ui.row({ align = "center" }, {
      ui.label({ text = tr("panel.last_7_days"), fontSize = 9, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = tr("panel.score_per_day"), fontSize = 9, color = "on_surface_variant" }),
    }),
    ui.graph({ values = values, height = 54, color = "primary", fillOpacity = 0.22, lineWidth = 2 }),
    ui.row({ gap = 0 }, day_labels),
  })

  local mood_card = ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "primary_container" }, {
    mascot_node(52, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({
        text = tr(MASCOT_COPY[mood] or MASCOT_COPY.sleepy),
        fontSize = 12,
        color = "on_primary_container",
        maxLines = 2,
      }),
      ui.label({ text = tagline(), fontSize = 9, color = "on_primary_container", maxLines = 1 }),
    }),
  })

  return ui.column({ gap = 8 }, { score_card, stats, spark_card, mood_card })
end

-- ── reports ─────────────────────────────────────────────────────────────────

local function has_report()
  local snapshot = view.report
  return type(snapshot) == "table"
    and snapshot.period == period
    and snapshot.day == view.day
    and snapshot.for_revision == view.revision
end

-- Reports are on demand: the panel asks the service, the service publishes the
-- snapshot back into the view. `last_report_request` stops a re-render loop
-- while the round-trip is in flight.
local function request_report(force)
  if tab ~= "reports" then return end
  local key = tostring(period) .. "@" .. tostring(view.day) .. "@" .. tostring(view.revision)
  if not force and (has_report() or last_report_request == key) then return end
  last_report_request = key
  send("report", { period = period })
end

local function period_toggle()
  local function period_button(id, label)
    return ui.button({
      text = label,
      variant = period == id and "secondary" or "ghost",
      selected = period == id,
      controlSize = "sm",
      width = 92,
      onClick = function()
        if period ~= id then
          period = id
          last_report_request = nil
          request_report(true)
          render()
        end
      end,
    })
  end
  local range = tr("panel.counting")
  if has_report() then range = view.report.label or range end
  return ui.row({ gap = 4, align = "center" }, {
    period_button("weekly", tr("panel.weekly")),
    period_button("monthly", tr("panel.monthly")),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = range, fontSize = 10, color = "on_surface_variant" }),
  })
end

local function metrics_grid(report)
  local trend = tr("panel.no_earlier")
  if type(report.trend) == "table" then
    trend = tr("panel.trend", {
      delta = report.trend.delta,
      period = report.period == "monthly" and tr("panel.month") or tr("panel.week"),
    })
  end
  local best = "—"
  if report.best then
    best = tr("panel.day_score", {
      weekday = logic.weekday_name(report.best.day, true) or "",
      score = report.best.score,
    })
  end
  local worst = tr("panel.no_bad_days")
  if report.worst then
    worst = tr("panel.worst", {
      weekday = logic.weekday_name(report.worst.day, true) or "",
      score = report.worst.score,
    })
  end
  local on_time = report.on_time_total > 0 and string.format("%d%%", report.on_time_rate) or "—"

  local function row(left, right)
    return ui.row({ gap = 6, align = "stretch" }, { left, right })
  end

  return ui.column({ gap = 5 }, {
    row(
      stat_card(tr("panel.score"), string.format("%d%%", report.score), trend,
        report.score >= 70 and "tertiary" or "primary"),
      stat_card(tr("panel.done"), string.format("%d/%d", report.done, report.assigned),
        tr("panel.effort_of", {
          done = logic.fmt_minutes(report.effort_done),
          assigned = logic.fmt_minutes(report.effort_assigned),
        }))),
    row(
      stat_card(tr("panel.carried"), tostring(report.carryover),
        tr("panel.of_tasks", { rate = report.carryover_rate })),
      stat_card(tr("panel.on_time"), on_time,
        tr("panel.deadline_note", { done = report.on_time, total = report.on_time_total }))),
    row(
      stat_card(tr("panel.avg_close"), string.format("%d%%", report.avg_progress), tr("panel.unfinished")),
      stat_card(tr("panel.best_day"), best, worst, "tertiary")),
  })
end

local function tags_card(report)
  local rows = {}
  local shown = math.min(#(report.by_tag or {}), 4)
  for index = 1, shown do
    local tag = report.by_tag[index]
    rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = tag.tag == "untagged" and tr("panel.untagged") or ("#" .. tag.tag),
        width = 88,
        fontSize = 10,
        maxLines = 1,
      }),
      ui.progress({
        progress = math.max(0, math.min(1, (tag.share or 0) / 100)),
        height = 5,
        radius = 3,
        fill = "primary",
        track = "surface_container_high",
        flexGrow = 1,
      }),
      ui.label({
        text = string.format("%d · %d%%", tag.count, tag.share),
        width = 64,
        fontSize = 9,
        textAlign = "end",
        color = "on_surface_variant",
      }),
    })
  end
  if #(report.by_tag or {}) > shown then
    local extra = #report.by_tag - shown
    rows[#rows + 1] = ui.label({
      text = noctalia.trp("panel.more_tags", extra, { count = extra }),
      fontSize = 9,
      color = "on_surface_variant",
    })
  end
  return ui.column({ gap = 5, padding = 8, radius = 10, fill = "surface_container" }, {
    ui.label({ text = tr("panel.tags"), fontSize = 9, color = "on_surface_variant" }),
    ui.column({ gap = 4 }, rows),
  })
end

-- Insights carry a key, its numbers and (for the two plural rules) the count
-- trp needs; the copy itself lives in translations/en.json.
local function insight_text(insight)
  if insight.plural then
    return noctalia.trp(insight.key, insight.plural, insight.subst)
  end
  return tr(insight.key, insight.subst)
end

local function insights_card(report)
  local rows = {}
  for _, insight in ipairs(report.insights or {}) do
    rows[#rows + 1] = ui.row({ gap = 8, align = "start" }, {
      ui.glyph({ name = "bulb", size = 14, color = "tertiary" }),
      ui.label({
        text = insight_text(insight),
        fontSize = 11,
        flexGrow = 1,
        maxLines = 3,
        color = "on_surface",
      }),
    })
  end
  return ui.column({ gap = 4, padding = 8, radius = 10, fill = "surface_container" }, {
    ui.label({ text = tr("panel.improve"), fontSize = 9, color = "on_surface_variant" }),
    ui.column({ gap = 4 }, rows),
  })
end

local function chart_card(report)
  local labels = {}
  for _, entry in ipairs(report.days or {}) do
    -- ui.graph smooths its samples, so the exact score sits under each point
    -- instead of being read off the curve.
    local text
    if period == "weekly" then
      text = string.format("%s %d%%", (entry.weekday or ""):sub(1, 1), entry.score or 0)
    else
      text = (entry.day:sub(9, 10):gsub("^0", ""))
    end
    labels[#labels + 1] = ui.label({
      text = text,
      fontSize = 8,
      flexGrow = 1,
      textAlign = "center",
      color = entry.has_data and "on_surface_variant" or "outline_variant",
    })
  end
  return ui.column({ gap = 3, padding = 8, radius = 10, fill = "surface_container" }, {
    ui.graph({ values = report.chart or {}, height = 44, color = "primary", fillOpacity = 0.2, lineWidth = 2 }),
    ui.row({ gap = 0 }, labels),
  })
end

local function reports_body()
  local children = { period_toggle() }
  local report_view = view.report

  if type(report_view) ~= "table" or report_view.period ~= period or report_view.day ~= view.day then
    children[#children + 1] = ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({ text = tr("panel.counting_days"), fontSize = 12, color = "on_surface_variant" }),
    })
  elseif (report_view.active_days or 0) == 0 then
    children[#children + 1] = ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({
        text = tr("panel.reports_empty"),
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.label({
        text = tr("panel.reports_empty_sub"),
        fontSize = 9,
        color = "on_surface_variant",
      }),
    })
  else
    children[#children + 1] = metrics_grid(report_view)
    children[#children + 1] = chart_card(report_view)
    children[#children + 1] = tags_card(report_view)
    children[#children + 1] = insights_card(report_view)
  end

  return ui.column({ gap = 6 }, children)
end

-- ── rows ────────────────────────────────────────────────────────────────────

local function badge(text, color)
  return ui.label({ text = text, fontSize = 10, color = color or "on_surface_variant" })
end

-- forward declaration: rows embed the editor, which is defined below them
local editor_node

local function row_node(task, index)
  local done = progress_of(task) >= 100
  local selected_row = index == selected
  local due = due_text(task)
  local actions = {}

  if tab == "pending" then
    actions[#actions + 1] = ui.button({
      glyph = "calendar-plus",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.plan_today"),
      onClick = function() send("promote", { id = task.id }) end,
    })
  end
  actions[#actions + 1] = ui.button({
    glyph = "pencil",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.tip.edit"),
    onClick = function()
      editing = {
        id = task.id,
        epoch = (editing and editing.epoch or 0) + 1,
        draft = {
          title = task.title,
          estimate = estimate_index(task.estimate_min),
          due = due and due:match("^%d%d:%d%d$") and due or "",
          tag = task.tag or "",
          priority = priority_index(task.priority),
          notes = task.notes or "",
        },
      }
      render()
    end,
  })
  actions[#actions + 1] = ui.button({
    glyph = "trash",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.tip.delete"),
    onClick = function() send("delete", { id = task.id }) end,
  })

  local top = {
    ui.glyph({
      name = done and "circle-check" or "circle",
      size = 14,
      color = done and "tertiary" or priority_color(task.priority),
    }),
    ui.label({
      text = task.title,
      fontSize = 13,
      flexGrow = 1,
      maxLines = 1,
      color = done and "on_surface_variant" or "on_surface",
    }),
  }
  if due then top[#top + 1] = badge(due, is_overdue(task) and "error" or "on_surface_variant") end
  if (tonumber(task.carried) or 0) > 0 then top[#top + 1] = badge("×" .. tostring(task.carried), "tertiary") end
  if task.tag and task.tag ~= "" then top[#top + 1] = badge("#" .. task.tag, "on_surface_variant") end
  for _, action in ipairs(actions) do top[#top + 1] = action end

  local children = {
    ui.row({ gap = 6, align = "center" }, top),
    ui.row({ gap = 8, align = "center" }, {
      ui.slider({
        key = "slider-" .. task.id,
        min = 0,
        max = 100,
        step = 5,
        value = progress_of(task),
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(value)
          overrides[task.id] = tonumber(value) or 0
          render()
        end,
        onDragEnd = function()
          send("progress", { id = task.id, progress = progress_of(task) })
        end,
      }),
      ui.label({
        text = string.format("%3d%%", math.floor(progress_of(task) + 0.5)),
        fontSize = 11,
        width = 40,
        textAlign = "end",
        color = done and "tertiary" or "on_surface_variant",
      }),
    }),
  }

  if editing and editing.id == task.id then
    children[#children + 1] = editor_node(task)
  end

  return ui.column({
    key = "row-" .. task.id,
    gap = 6,
    padding = 8,
    radius = 10,
    fill = selected_row and "surface_container_high" or "surface_container",
    border = selected_row and "primary" or nil,
    borderWidth = selected_row and 1 or 0,
  }, children)
end

-- ── editor ──────────────────────────────────────────────────────────────────

editor_node = function(task)
  local draft = editing.draft
  local epoch = editing.epoch

  local function field_changed(setter)
    return function(value) setter(value) end
  end

  local pending_button = ui.button({
    text = tab == "today" and tr("panel.move_pending") or tr("panel.plan_today"),
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      send(tab == "today" and "park" or "promote", { id = task.id })
      editing = nil
      render()
    end,
  })

  local cancel = ui.button({
    text = tr("panel.cancel"),
    variant = "ghost",
    controlSize = "sm",
    onClick = function() editing = nil; render() end,
  })

  local function save_draft()
    local due_ms = 0
    if trim(draft.due) ~= "" then
      due_ms = logic.due_from_clock(trim(draft.due), noctalia.nowMs()) or 0
    end
    send("edit", {
      id = task.id,
      title = draft.title,
      estimate_min = ESTIMATES[draft.estimate] or 0,
      due_ms = due_ms,
      tag = draft.tag,
      priority = PRIORITIES[draft.priority] or "med",
      notes = draft.notes,
    })
    editing = nil
    render()
  end

  local save = ui.button({
    text = tr("panel.save"),
    variant = "primary",
    controlSize = "sm",
    onClick = save_draft,
  })

  return ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_container_highest" }, {
    ui.input({
      key = "edit-title-" .. epoch,
      value = draft.title,
      placeholder = tr("panel.field.title"),
      controlSize = "sm",
      focus = true,
      onChange = field_changed(function(value) draft.title = value end),
      onSubmit = function(value)
        draft.title = value
        save_draft()
      end,
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.select({
        key = "edit-est-" .. epoch,
        options = ESTIMATE_LABELS,
        selectedIndex = (draft.estimate or 1) - 1,
        width = 76,
        controlSize = "sm",
        onChange = function(index) draft.estimate = tonumber(index) + 1 end,
      }),
      ui.input({
        key = "edit-due-" .. epoch,
        value = draft.due,
        placeholder = "17:00",
        width = 70,
        controlSize = "sm",
        onChange = field_changed(function(value) draft.due = value end),
      }),
      ui.input({
        key = "edit-tag-" .. epoch,
        value = draft.tag,
        placeholder = tr("panel.field.tag"),
        width = 84,
        controlSize = "sm",
        onChange = field_changed(function(value) draft.tag = value end),
      }),
      ui.select({
        key = "edit-pri-" .. epoch,
        options = {
          tr("panel.priority.low"),
          tr("panel.priority.med"),
          tr("panel.priority.high"),
        },
        selectedIndex = (draft.priority or 2) - 1,
        width = 76,
        controlSize = "sm",
        onChange = function(index) draft.priority = tonumber(index) + 1 end,
      }),
    }),
    ui.input({
      key = "edit-notes-" .. epoch,
      value = draft.notes,
      placeholder = tr("panel.field.notes"),
      multiline = true,
      height = 52,
      controlSize = "sm",
      onChange = field_changed(function(value) draft.notes = value end),
    }),
    ui.row({ gap = 6, align = "center" }, { pending_button, ui.spacer({ flexGrow = 1 }), cancel, save }),
  })
end

-- ── add form ────────────────────────────────────────────────────────────────

local function submit_add()
  local title = trim(add.title)
  if title == "" then return end
  local due_ms
  if trim(add.time) ~= "" then
    due_ms = logic.due_from_clock(trim(add.time), noctalia.nowMs())
  end
  local fields = { title = title, estimate_min = add.estimate, tag = trim(add.tag), due_ms = due_ms }

  local today_count = #(view.today_tasks or {})
  if view.cap.enabled and today_count >= (tonumber(view.cap.value) or 3) then
    cap_pending = fields
    -- rebuild the field unfocused so the prompt is the active surface
    add_focus = false
    add_epoch = add_epoch + 1
    render()
    return
  end

  send("add", fields)
  add = { title = "", estimate = 30, time = "", tag = "" }
  add_epoch = add_epoch + 1
  add_focus = true
  render()
end

local function add_form()
  local children = {
    ui.input({
      key = "add-title-" .. add_epoch,
      value = add.title,
      placeholder = tr("panel.add_placeholder"),
      flexGrow = 1,
      controlSize = "sm",
      focus = add_focus,
      onChange = function(value) add.title = value end,
      onSubmit = function(value)
        add.title = value
        submit_add()
      end,
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.select({
        key = "add-est-" .. add_epoch,
        options = ESTIMATE_LABELS,
        selectedIndex = estimate_index(add.estimate) - 1,
        width = 76,
        controlSize = "sm",
        onChange = function(index) add.estimate = ESTIMATES[tonumber(index) + 1] or 30 end,
      }),
      ui.input({
        key = "add-time-" .. add_epoch,
        value = add.time,
        placeholder = "17:00",
        width = 70,
        controlSize = "sm",
        onChange = function(value) add.time = value end,
      }),
      ui.input({
        key = "add-tag-" .. add_epoch,
        value = add.tag,
        placeholder = tr("panel.field.tag"),
        width = 84,
        controlSize = "sm",
        onChange = function(value) add.tag = value end,
      }),
      ui.button({
        text = tr("panel.add"),
        variant = "primary",
        controlSize = "sm",
        flexGrow = 1,
        onClick = submit_add,
      }),
    }),
  }

  if cap_pending then
    children[#children + 1] = ui.column({ gap = 6, padding = 8, radius = 8, fill = "primary_container" }, {
      ui.label({
        text = tr("panel.cap_prompt", { count = view.cap.value or 3 }),
        fontSize = 11,
        color = "on_primary_container",
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.button({
          text = tr("panel.add_anyway"),
          variant = "primary",
          controlSize = "sm",
          onClick = function()
            send("add", cap_pending)
            cap_pending = nil
            add = { title = "", estimate = 30, time = "", tag = "" }
            add_epoch = add_epoch + 1
            add_focus = true
            render()
          end,
        }),
        ui.button({
          text = tr("panel.not_now"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            cap_pending = nil
            render()
          end,
        }),
      }),
    })
  end

  return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_container" }, children)
end

-- ── celebration (Phase 4c) ──────────────────────────────────────────────────

local dismissed_celebration = 0

-- The service stamps `celebrate_until` (now + 8 s) the first time every task is
-- done; the card shows until then, until "Back to the list", or until the stamp
-- changes. No animation exists at API 43, so this is a static card with a timer.
local function celebrating()
  local until_ms = tonumber(view.celebrate_until) or 0
  if until_ms <= 0 or until_ms <= noctalia.nowMs() then return false end
  return dismissed_celebration < until_ms
end

local function celebration_body()
  local card = logic.celebration(view.done, view.total)
  local children = { mascot_image("proud", 96) or ui.label({ text = "(≧▽≦)", fontSize = 52, color = "tertiary" }) }
  children[#children + 1] = ui.label({
    text = tr(card.headline_key),
    fontSize = 20,
    fontWeight = "bold",
    textAlign = "center",
    fontFamily = HEADER_FONT,
    maxLines = 2,
  })
  children[#children + 1] = ui.label({
    text = tr(card.line_key, card.subst),
    fontSize = 13,
    textAlign = "center",
    color = "on_surface_variant",
  })
  children[#children + 1] = ui.button({
    text = tr("panel.back_to_list"),
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      dismissed_celebration = tonumber(view.celebrate_until) or 0
      render()
    end,
  })
  return ui.column({ gap = 10, padding = 24, radius = 14, fill = "surface_container", align = "center" }, children)
end

-- ── evening triage (Phase 4c) ───────────────────────────────────────────────
--
-- Notifications carry no action buttons, so the 21:00 toast is the doorbell and
-- this card is the surface: `noctalia msg panel-open goutamsharma/medo:panel triage`.

local triage_ignored = {}

local function triage_tasks()
  local rows = {}
  for _, task in ipairs(view.today_tasks or {}) do
    if progress_of(task) < 100 and not triage_ignored[task.id] then rows[#rows + 1] = task end
  end
  for _, task in ipairs(view.pending_tasks or {}) do
    if not triage_ignored[task.id] then rows[#rows + 1] = task end
  end
  return rows
end

local function triage_row(task)
  local due = due_text(task)
  local top = {
    ui.glyph({ name = "circle", size = 14, color = priority_color(task.priority) }),
    ui.label({ text = task.title, fontSize = 13, flexGrow = 1, maxLines = 1 }),
    badge(task.status == "pending" and tr("panel.status.pending") or tr("panel.status.today"),
      "on_surface_variant"),
  }
  if due then top[#top + 1] = badge(due, is_overdue(task) and "error" or "on_surface_variant") end
  if (tonumber(task.carried) or 0) > 0 then top[#top + 1] = badge("×" .. tostring(task.carried), "tertiary") end

  local function act(kind)
    return function()
      send(kind, { id = task.id })
      -- answered rows leave the card immediately; the service republishes the
      -- view a moment later for the rows that really changed state
      triage_ignored[task.id] = true
      render()
    end
  end

  local buttons = {
    ui.button({
      text = tr("panel.triage.retry"),
      variant = "primary",
      controlSize = "sm",
      tooltip = tr("panel.triage.retry_tip"),
      onClick = act("promote"),
    }),
  }
  if task.status ~= "pending" then
    buttons[#buttons + 1] = ui.button({
      text = tr("panel.triage.park"),
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.triage.park_tip"),
      onClick = act("park"),
    })
  end
  buttons[#buttons + 1] = ui.spacer({ flexGrow = 1 })
  buttons[#buttons + 1] = ui.button({
    text = tr("panel.triage.drop"),
    variant = "destructive",
    controlSize = "sm",
    tooltip = tr("panel.triage.drop_tip"),
    onClick = act("delete"),
  })

  return ui.column({ gap = 6, padding = 8, radius = 10, fill = "surface_container" }, {
    ui.row({ gap = 6, align = "center" }, top),
    ui.row({ gap = 6, align = "center" }, buttons),
  })
end

local function triage_body()
  local rows = triage_tasks()
  local summary = logic.triage_summary(rows)
  local children = {
    ui.column({ gap = 3, padding = 12, radius = 12, fill = "primary_container" }, {
      ui.label({ text = tr("panel.triage.title"), fontSize = 10, color = "on_primary_container" }),
      ui.label({ text = tr(summary.copy_key, summary.subst), fontSize = 13,
        color = "on_primary_container", maxLines = 2 }),
    }),
  }
  if #rows == 0 then
    children[#children + 1] = ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({ text = tr("panel.triage.empty"), fontSize = 12, color = "on_surface_variant" }),
    })
  else
    for _, task in ipairs(rows) do children[#children + 1] = triage_row(task) end
    children[#children + 1] = ui.label({
      text = tr("panel.triage.hint"),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 2,
    })
  end
  return ui.column({ gap = 6 }, children)
end

-- ── trash (Phase 5a) ────────────────────────────────────────────────────────
--
-- Rows come from the service (`view.trash_tasks`, newest deletion first, each
-- with the days its restore window has left). The panel only sends `restore`,
-- `purge` and `empty-trash`; rollover is still the only automatic purge.

local function trash_row(entry)
  local task = entry.task or {}
  local days = tonumber(entry.days_left) or 0
  local window
  if days <= 0 then
    window = tr("panel.trash.tonight")
  else
    window = noctalia.trp("panel.trash.purges", days, { count = days })
  end
  local deleted = "?"
  if entry.deleted_ms and entry.deleted_ms > 0 then
    deleted = os.date("%d %b", math.floor(entry.deleted_ms / 1000))
  end

  return ui.column({ gap = 6, padding = 8, radius = 10, fill = "surface_container" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "trash", size = 13, color = "on_surface_variant" }),
      ui.label({ text = task.title or "untitled", fontSize = 13, flexGrow = 1, maxLines = 1 }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = tr("panel.trash.deleted", { date = deleted, window = window }),
        fontSize = 10,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.button({
        text = tr("panel.restore"),
        variant = "primary",
        controlSize = "sm",
        tooltip = tr("panel.restore_tip"),
        onClick = function()
          send("restore", { id = task.id })
          render()
        end,
      }),
      ui.button({
        text = tr("panel.delete_forever"),
        variant = "destructive",
        controlSize = "sm",
        tooltip = tr("panel.delete_forever_tip"),
        onClick = function()
          send("purge", { id = task.id })
          render()
        end,
      }),
    }),
  })
end

local function trash_body()
  local rows = view.trash_tasks or {}
  if #rows == 0 then
    return ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({ text = tr("panel.empty.trash"), fontSize = 12, color = "on_surface_variant" }),
      ui.label({
        text = tr("panel.empty.trash_sub"),
        fontSize = 9,
        color = "on_surface_variant",
      }),
    })
  end
  local children = {}
  for _, entry in ipairs(rows) do children[#children + 1] = trash_row(entry) end
  return ui.column({ gap = 6 }, children)
end

-- ── header, tabs, bodies, footer ────────────────────────────────────────────

local function header()
  return ui.row({ gap = 10, align = "center" }, {
    mascot_node(30, 18),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("plugin.name"), fontSize = 17, fontWeight = "bold", fontFamily = HEADER_FONT }),
        ui.label({ text = view.day or "…", fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = string.format("%d%%", view.score or 0), fontSize = 11, color = "primary" }),
        ui.label({ text = "🔥" .. tostring(view.streak or 0), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = tagline(), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "adjustments",
      variant = "ghost",
      tooltip = tr("panel.tip.settings"),
      onClick = function() noctalia.openSettings() end,
    }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.tip.close"),
      onClick = function() panel.close() end }),
  })
end

local function tab_strip()
  local function tab_button(id, label, count)
    local text = label
    if count then text = string.format("%s %d", label, count) end
    return ui.button({
      text = text,
      variant = tab == id and "secondary" or "ghost",
      selected = tab == id,
      controlSize = "sm",
      -- five tabs at the 460 px panel width: the smaller face keeps "Pending 1"
      -- and "Reports" whole instead of clipped (measured, not guessed)
      fontSize = 10,
      flexGrow = 1,
      onClick = function()
        if tab ~= id then
          tab = id
          selected = 1
          cap_pending = nil
          if id == "reports" then request_report(true) end
          render()
        end
      end,
    })
  end
  return ui.row({ gap = 4, align = "center" }, {
    tab_button("today", tr("panel.tab.today"), #(view.today_tasks or {})),
    tab_button("pending", tr("panel.tab.pending"), #(view.pending_tasks or {})),
    tab_button("dashboard", tr("panel.tab.stats")),
    tab_button("reports", tr("panel.tab.reports")),
    tab_button("trash", tr("panel.tab.trash"), #(view.trash_tasks or {})),
  })
end

local function list_body()
  local rows = current_rows()
  local children = {}
  if #rows == 0 then
    children[#children + 1] = ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({
        text = tab == "today" and tr("panel.empty.today") or tr("panel.empty.pending"),
        fontSize = 12,
        color = "on_surface_variant",
      }),
    })
  else
    for index, task in ipairs(rows) do
      children[#children + 1] = row_node(task, index)
    end
  end
  return ui.column({ gap = 6 }, children)
end

local function footer()
  if tab == "dashboard" then
    return ui.column({ gap = 2 }, {
      ui.separator({}),
      ui.label({
        text = tr("panel.footer.dashboard", {
          day = view.day or "…",
          score = view.score or 0,
          target = view.target or 70,
          streak = view.streak or 0,
          best = view.streak_best or 0,
        }),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    })
  elseif tab == "trash" then
    local retention = tonumber(noctalia.getConfig("trash_days")) or 30
    local children = {
      ui.separator({}),
      ui.label({
        text = tr("panel.trash.footer", { days = retention }),
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 2,
      }),
    }
    if #(view.trash_tasks or {}) > 0 then
      children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
        ui.button({
          text = tr("panel.empty_trash"),
          variant = "ghost",
          controlSize = "sm",
          tooltip = tr("panel.empty_trash_tip"),
          onClick = function()
            send("empty-trash")
            render()
          end,
        }),
        ui.spacer({ flexGrow = 1 }),
      })
    end
    return ui.column({ gap = 4 }, children)
  elseif tab == "reports" then
    local exportable = has_report() and (view.report.active_days or 0) > 0
    local note = tr("panel.reports_note")
    if type(view.last_export) == "table" and view.last_export.path
      and view.last_export.period == period then
      note = tr("panel.last_export", { path = tostring(view.last_export.path) })
    end
    local children = { ui.separator({}) }
    if exportable then
      children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
        ui.button({
          text = tr("panel.export_md"),
          variant = "primary",
          controlSize = "sm",
          onClick = function() send("export", { period = period, format = "markdown" }) end,
        }),
        ui.button({
          text = tr("panel.export_json"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function() send("export", { period = period, format = "json" }) end,
        }),
        ui.spacer({ flexGrow = 1 }),
      })
    end
    children[#children + 1] = ui.label({
      text = note,
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 1,
    })
    return ui.column({ gap = 4 }, children)
  end

  local planned = 0
  for _, task in ipairs(view.today_tasks or {}) do
    planned = planned + (tonumber(task.estimate_min) or 0)
  end
  local hours = math.floor(planned / 60)
  local minutes = planned % 60
  local planned_text = hours > 0 and string.format("%dh %02dm", hours, minutes) or string.format("%dm", minutes)
  return ui.column({ gap = 2 }, {
    ui.separator({}),
    ui.label({
      text = tr("panel.footer.today", {
        count = #(view.today_tasks or {}),
        planned = planned_text,
        score = view.score or 0,
        carried = view.carried or 0,
      }),
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.label({
      text = tr("panel.footer.hint"),
      fontSize = 10,
      color = "on_surface_variant",
    }),
  })
end

function render()
  read_view()
  local rows = current_rows()
  if #rows == 0 then selected = 1 elseif selected > #rows then selected = #rows end

  -- the service clears the stamp when it expires; these ticks only shorten the
  -- delay while the card is up (a panel tick is not guaranteed on 5.4.1)
  local celebration = celebrating()
  panel.setWantsSecondTicks(celebration)
  noctalia.setUpdateInterval(celebration and 1000 or 30000)

  local body
  if celebration then
    body = celebration_body()
  elseif tab == "triage" then
    body = triage_body()
  elseif tab == "trash" then
    body = trash_body()
  elseif tab == "dashboard" then
    body = dashboard_body()
  elseif tab == "reports" then
    request_report(false)
    body = reports_body()
  elseif tab == "today" then
    body = ui.column({ gap = 8 }, { list_body(), add_form() })
  else
    body = list_body()
  end

  panel.render(ui.column({ gap = 10, padding = 14 }, {
    header(),
    tab_strip(),
    body,
    footer(),
  }))
end

-- ── keyboard + lifecycle ────────────────────────────────────────────────────

function onOpen(context)
  read_view()
  editing = nil
  cap_pending = nil
  tab = "today"
  selected = 1
  last_report_request = nil
  triage_ignored = {}
  dismissed_celebration = 0

  -- context comes from `noctalia msg panel-open <id> <context>`; notifications
  -- and debugging use it to land on the right surface
  if context == "pending" then
    tab = "pending"
  elseif context == "triage" then
    tab = "triage"
  elseif context == "trash" then
    tab = "trash"
  elseif context == "dashboard" then
    tab = "dashboard"
  elseif context == "reports" or context == "reports-monthly" then
    tab = "reports"
    period = context == "reports-monthly" and "monthly" or "weekly"
    request_report(true)
  elseif context == "add" then
    -- explicit capture intent: start from an empty field, not last draft
    add = { title = "", estimate = 30, time = "", tag = "" }
    add_focus = true
    add_epoch = add_epoch + 1
  elseif type(context) == "string" then
    local task_id = context:match("^edit:(.+)$")
    if task_id then
      for index, task in ipairs(view.today_tasks) do
        if task.id == task_id then
          selected = index
          editing = {
            id = task.id,
            epoch = 1,
            draft = {
              title = task.title,
              estimate = estimate_index(task.estimate_min),
              due = "",
              tag = task.tag or "",
              priority = priority_index(task.priority),
              notes = task.notes or "",
            },
          }
        end
      end
    end
  end

  render()
end

function update()
  -- the service pushes every change through the view watch; the slow tick keeps
  -- the dashboard countdown honest, and the one-second ticks expire the
  -- celebration card after ~8 s
  if tab == "dashboard" or celebrating() then render() end
end

-- Drop the one-second cadence when the panel goes away; render() reinstates it
-- the next time a celebration starts.
function onClose()
  noctalia.setUpdateInterval(30000)
end

noctalia.state.watch("view", function()
  overrides = {}
  read_view()
  render()
end)

noctalia.setUpdateInterval(30000)
render()
