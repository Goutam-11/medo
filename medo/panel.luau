--!nonstrict
-- medo panel — Today and Pending, with the progress slider and keyboard-first
-- actions. The panel never touches disk: every change goes to the core service
-- as a command on noctalia.state["cmd"], and the service publishes a new view.

local logic = require("./logic.luau")

local ESTIMATES = { 15, 30, 45, 60, 90 }
local ESTIMATE_LABELS = { "15m", "30m", "45m", "60m", "90m" }
local PRIORITIES = { "low", "med", "high" }

local view = { today_tasks = {}, pending_tasks = {}, cap = { enabled = true, value = 3 } }
local tab = "today"
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

local function tagline()
  local total = view.total or 0
  local done = view.done or 0
  if total == 0 then return "nothing planned. medo is suspiciously calm." end
  if done >= total then return "all done. go touch grass." end
  if (view.carried or 0) > 0 then return tostring(view.carried) .. " carried. be gentle, then start." end
  if (view.score or 0) >= 70 then return "on a roll. medo approves." end
  return "one at a time. three is plenty."
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
      tooltip = "Plan for today",
      onClick = function() send("promote", { id = task.id }) end,
    })
  end
  actions[#actions + 1] = ui.button({
    glyph = "pencil",
    variant = "ghost",
    controlSize = "sm",
    tooltip = "Edit",
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
    tooltip = "Delete",
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
    text = tab == "today" and "Move to Pending" or "Plan for today",
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      send(tab == "today" and "park" or "promote", { id = task.id })
      editing = nil
      render()
    end,
  })

  local cancel = ui.button({
    text = "Cancel",
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
    text = "Save",
    variant = "primary",
    controlSize = "sm",
    onClick = save_draft,
  })

  return ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_container_highest" }, {
    ui.input({
      key = "edit-title-" .. epoch,
      value = draft.title,
      placeholder = "Title",
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
        placeholder = "tag",
        width = 84,
        controlSize = "sm",
        onChange = field_changed(function(value) draft.tag = value end),
      }),
      ui.select({
        key = "edit-pri-" .. epoch,
        options = { "low", "med", "high" },
        selectedIndex = (draft.priority or 2) - 1,
        width = 76,
        controlSize = "sm",
        onChange = function(index) draft.priority = tonumber(index) + 1 end,
      }),
    }),
    ui.input({
      key = "edit-notes-" .. epoch,
      value = draft.notes,
      placeholder = "notes",
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
    -- drop focus out of the input so the y shortcut reaches onKey
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
      placeholder = "add a task…",
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
        placeholder = "tag",
        width = 84,
        controlSize = "sm",
        onChange = function(value) add.tag = value end,
      }),
      ui.button({
        text = "Add",
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
        text = string.format("Today already has %d. Add one more anyway? (y)", view.cap.value or 3),
        fontSize = 11,
        color = "on_primary_container",
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.button({
          text = "Add it",
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
          text = "Not now",
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

-- ── header, tabs, bodies, footer ────────────────────────────────────────────

local function header()
  return ui.row({ gap = 10, align = "center" }, {
    ui.label({ text = mascot(), fontSize = 18, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "medo", fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = view.day or "…", fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = string.format("%d%%", view.score or 0), fontSize = 11, color = "primary" }),
        ui.label({ text = "🔥" .. tostring(view.streak or 0), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = tagline(), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "adjustments",
      variant = "ghost",
      tooltip = "medo settings",
      onClick = function() noctalia.openSettings() end,
    }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
  })
end

local function tab_strip()
  local function tab_button(id, label, count)
    return ui.button({
      text = string.format("%s %d", label, count or 0),
      variant = tab == id and "secondary" or "ghost",
      selected = tab == id,
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        if tab ~= id then
          tab = id
          selected = 1
          cap_pending = nil
          render()
        end
      end,
    })
  end
  return ui.row({ gap = 4, align = "center" }, {
    tab_button("today", "Today", #(view.today_tasks or {})),
    tab_button("pending", "Pending", #(view.pending_tasks or {})),
  })
end

local function list_body()
  local rows = current_rows()
  local children = {}
  if #rows == 0 then
    children[#children + 1] = ui.column({ gap = 4, padding = 14, radius = 10, fill = "surface_container" }, {
      ui.label({
        text = tab == "today" and "Nothing planned yet. Three is a good number to start."
          or "No leftovers. Medo is pleasantly surprised.",
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
      text = string.format("%d today · %s planned · %d%% · %d carried",
        #(view.today_tasks or {}), planned_text, view.score or 0, view.carried or 0),
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.label({
      text = "n new · j/k select · x done · p park · d delete · y confirm · 1/2 tabs",
      fontSize = 10,
      color = "on_surface_variant",
    }),
  })
end

function render()
  read_view()
  local rows = current_rows()
  if #rows == 0 then selected = 1 elseif selected > #rows then selected = #rows end

  local body = tab == "today" and ui.column({ gap = 8 }, { list_body(), add_form() }) or list_body()
  panel.render(ui.column({ gap = 10, padding = 14 }, {
    header(),
    tab_strip(),
    body,
    footer(),
  }))
end

-- ── keyboard + lifecycle ────────────────────────────────────────────────────

function onKey(chord, pressed)
  if pressed ~= "true" then return end
  local rows = current_rows()
  if chord == "n" then
    add_focus = true
    add_epoch = add_epoch + 1
    render()
  elseif chord == "j" or chord == "k" then
    if #rows == 0 then return end
    selected = math.max(1, math.min(#rows, selected + (chord == "j" and 1 or -1)))
    render()
  elseif chord == "x" then
    local task = rows[selected]
    if task then
      send("progress", { id = task.id, progress = progress_of(task) >= 100 and 0 or 100 })
    end
  elseif chord == "d" then
    local task = rows[selected]
    if task then send("delete", { id = task.id }) end
  elseif chord == "p" then
    local task = rows[selected]
    if task then send(tab == "today" and "park" or "promote", { id = task.id }) end
  elseif chord == "y" then
    -- confirm the soft-cap prompt without reaching for the pointer
    if cap_pending then
      send("add", cap_pending)
      cap_pending = nil
      add = { title = "", estimate = 30, time = "", tag = "" }
      add_epoch = add_epoch + 1
      add_focus = true
      render()
    end
  elseif chord == "1" then
    tab = "today"
    selected = 1
    render()
  elseif chord == "2" then
    tab = "pending"
    selected = 1
    render()
  end
end

function onOpen(context)
  read_view()
  editing = nil
  cap_pending = nil
  tab = "today"
  selected = 1

  -- context comes from `noctalia msg panel-open <id> <context>`; notifications
  -- and debugging use it to land on the right surface
  if context == "pending" then
    tab = "pending"
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

  -- deliberately NOT focusing the add field: the panel keeps keyboard focus for
  -- the j/k/x shortcuts, and `n` moves focus into the field when you want to type
  render()
end

function update()
  -- the service pushes every change through the view watch; no polling needed
end

noctalia.state.watch("view", function()
  overrides = {}
  read_view()
  render()
end)

render()
