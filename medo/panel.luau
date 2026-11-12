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
        text = (view.day ~= "" and view.day or "…") .. " · scaffold",
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

local function body(view)
  return ui.column({ gap = 10, padding = 12, fill = "surface_container", radius = 12 }, {
    ui.label({
      text = "Phase 0: the shell is wired. Next up is the store, then today's list.",
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "checks", size = 16, color = "primary" }),
      ui.label({
        text = string.format("%d of %d done · %d carried", view.done, view.total, view.carried),
        fontSize = 12,
      }),
    }),
    ui.separator({}),
    ui.label({
      text = "Try: noctalia msg plugin goutamsharma/medo:core all ping",
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
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
