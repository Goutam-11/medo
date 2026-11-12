--!nonstrict
-- medo panel — Phase 0 scaffold.
--
-- The real thing is five tabs (Today / Pending / Dashboard / Reports / Trash)
-- with a per-task progress slider. This shell exists to prove the panel opens,
-- auto-sizes to its content, and reads the same view the bar does.

local function snapshot()
  local view = noctalia.state.get("view")
  if type(view) ~= "table" then
    return { day = "", done = 0, total = 0, carried = 0, ready = false }
  end
  return view
end

local function header(view)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = "( ◕‿◕ )", fontSize = 18, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = "medo", fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = (view.day ~= "" and view.day or "…") .. " · " .. tostring(view.total) .. " planned",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
    ui.button({
      glyph = "close",
      variant = "ghost",
      tooltip = "Close",
      onClick = function()
        panel.close()
      end,
    }),
  })
end

local function stat(name, value, color)
  return ui.column({ gap = 2, flexGrow = 1 }, {
    ui.label({ text = tostring(value), fontSize = 20, fontWeight = "bold", color = color or "primary" }),
    ui.label({ text = name, fontSize = 10, color = "on_surface_variant" }),
  })
end

local function body(view)
  return ui.column({ gap = 10, padding = 12, fill = "surface_container", radius = 12 }, {
    ui.row({ gap = 10, align = "center" }, {
      stat("done", string.format("%d/%d", view.done, view.total)),
      stat("score", string.format("%d%%", view.score)),
      stat("carried", view.carried, "tertiary"),
      stat("streak", view.streak, "secondary"),
    }),
    ui.separator({}),
    ui.label({
      text = "The store is live: tasks survive reloads, and the day closes at the rollover hour.",
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.label({
      text = "Tabs and the progress slider arrive in phase 2.",
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

function render()
  local view = snapshot()
  panel.render(ui.column({ gap = 12, padding = 14 }, {
    header(view),
    body(view),
  }))
end

function onOpen(_context)
  render()
end

function update()
  render()
end

render()
