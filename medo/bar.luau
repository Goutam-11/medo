--!nonstrict
-- medo bar widget: the Medo glyph plus today's done/total.
--
-- Reads the view published by the core service and re-renders whenever it
-- changes; the widget itself never touches data files. Click opens the panel,
-- right-click opens it on Pending.

local logic = require("./logic.luau")

local PANEL_ID = "goutamsharma/medo:panel"
local glyphName = noctalia.getConfig("glyph") or "checklist"

local function view()
  local snapshot = noctalia.state.get("view")
  if type(snapshot) ~= "table" then
    return { done = 0, total = 0, carried = 0, ready = false }
  end
  return snapshot
end

local function count_text(snapshot)
  local done = tonumber(snapshot.done) or 0
  local total = tonumber(snapshot.total) or 0
  return string.format("%d/%d", done, total)
end

local function tooltip(snapshot)
  local rows = {
    { noctalia.tr("plugin.name"), count_text(snapshot) .. (snapshot.ready and "" or (" · " .. noctalia.tr("bar.waking"))) },
  }
  local due = logic.next_due_tooltip(snapshot.next_due, noctalia.nowMs())
  if due then
    rows[#rows + 1] = {
      noctalia.tr("bar.next_due"),
      noctalia.tr("bar.next_due.value", { when = due.when, title = due.title }),
    }
  end
  if (tonumber(snapshot.carried) or 0) > 0 then
    rows[#rows + 1] = { noctalia.tr("bar.carried"), tostring(snapshot.carried) }
  end
  rows[#rows + 1] = { noctalia.tr("bar.click"), noctalia.tr("bar.open_today") }
  rows[#rows + 1] = { noctalia.tr("bar.right_click"), noctalia.tr("bar.open_pending") }
  return rows
end

local function render()
  local snapshot = view()
  local done = tonumber(snapshot.done) or 0
  local total = tonumber(snapshot.total) or 0
  -- the glyph warms up as the day fills: quiet when empty, primary while work
  -- remains, tertiary once everything is finished
  local color = "on_surface_variant"
  if total > 0 then
    color = done >= total and "tertiary" or "primary"
  end

  -- widget settings (PLAN §9); both off falls back to the count so the bar
  -- never renders an empty capsule
  local show = logic.bar_visibility(
    noctalia.getConfig("show_count"),
    noctalia.getConfig("show_mascot_dot")
  )
  local children = {}
  if show.dot then
    children[#children + 1] = ui.glyph({ name = glyphName, size = 16, color = color })
  end
  if show.count then
    children[#children + 1] = ui.label({ text = count_text(snapshot), fontSize = 12, color = "on_surface" })
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltip(snapshot))
end

-- API 43's togglePanel takes no context argument, so the bar hands the context
-- to the panel through the shared state; panel.onOpen consumes it once.
local function open_pending()
  noctalia.state.set("panel_context", "pending")
  noctalia.togglePanel(PANEL_ID)
end

noctalia.state.watch("view", render)

function onClick()
  noctalia.state.set("panel_context", nil)
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  open_pending()
end

function onIpc(event)
  if event == "refresh" then
    render()
  elseif event == "pending" then
    -- dev seam for the right-click path: no pointer injection on this machine
    open_pending()
  end
end

function update()
  -- the service pushes on every change; a slow tick is only a safety net
  noctalia.setUpdateInterval(5000)
  render()
end

render()
