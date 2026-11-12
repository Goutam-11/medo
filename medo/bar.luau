--!nonstrict
-- medo bar widget: the Medo glyph plus today's done/total.
--
-- Reads the view published by the core service and re-renders whenever it
-- changes; the widget itself never touches data files. Click opens the panel.

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
    { "medo", count_text(snapshot) .. (snapshot.ready and "" or " · waking up") },
  }
  if (tonumber(snapshot.carried) or 0) > 0 then
    rows[#rows + 1] = { "Carried", tostring(snapshot.carried) }
  end
  rows[#rows + 1] = { "Click", "open today" }
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

  barWidget.render(ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyphName, size = 16, color = color }),
    ui.label({ text = count_text(snapshot), fontSize = 12, color = "on_surface" }),
  }))
  barWidget.setTooltip(tooltip(snapshot))
end

noctalia.state.watch("view", render)

function onClick()
  noctalia.togglePanel("goutamsharma/medo:panel")
end

function onIpc(event)
  if event == "refresh" then
    render()
  end
end

function update()
  -- the service pushes on every change; a slow tick is only a safety net
  noctalia.setUpdateInterval(5000)
  render()
end

render()
