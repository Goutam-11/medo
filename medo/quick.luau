--!nonstrict
-- medo launcher provider — `medo buy milk @17:00 #errand !high`.
--
-- Answers the launcher query behind the `medo` prefix: one result whose title
-- is the parsed task title and whose subtitle previews the parsed due time, tag
-- and priority. Activating it sends one `add` command to the core service (the
-- only writer), toasts, and resets the query so the launcher stays open for the
-- next capture. This entry never touches disk; `logic.luau` owns the parsing.

local logic = require("./logic.luau")

local seq = 0

local ROOT_HINT = "buy milk @17:00 #errand !high"

local function now_ms()
  return noctalia.nowMs()
end

-- The logical day comes from the published view; before the service has
-- published one, derive it from the clock and the rollover setting.
local function day()
  local snapshot = noctalia.state.get("view")
  if type(snapshot) == "table" and type(snapshot.day) == "string" then return snapshot.day end
  local hour = tonumber(noctalia.getConfig("rollover_hour")) or 4
  return logic.logical_day(now_ms(), hour)
end

-- The command channel the panel uses: the service applies it, saves and
-- republishes the view. `rev` is monotonic so a duplicate delivery is a no-op.
local function send_add(parsed)
  seq = seq + 1
  noctalia.state.set("cmd", {
    kind = "add",
    rev = now_ms() * 1000 + (seq % 1000),
    title = parsed.title,
    due_ms = parsed.due_ms,
    tag = parsed.tag,
    priority = parsed.priority,
  })
end

-- Results are stateless: the id carries the raw query, so activating an older
-- result can never add the text of a newer one.
local function capture_id(query)
  return "capture:" .. query
end

local function caption(parsed)
  local preview = logic.capture_preview(parsed)
  if preview ~= "" then return preview end
  return "today's list"
end

function onQuery(text)
  local query = tostring(text or "")
  local parsed = logic.parse_capture(query, now_ms(), day())
  if query == "" then
    launcher.setResults(query, {
      {
        id = "hint",
        title = "medo " .. ROOT_HINT,
        subtitle = "type a task — the tokens become the due, tag and priority",
        glyph = "checklist",
      },
    })
    return
  end
  if parsed.title == "" then
    launcher.setResults(query, {
      {
        id = "hint",
        title = "Give it a title",
        subtitle = "tokens alone do not make a task",
        glyph = "info-circle",
      },
    })
    return
  end
  launcher.setResults(query, {
    {
      id = capture_id(query),
      title = parsed.title,
      subtitle = caption(parsed),
      glyph = "checklist",
    },
  })
end

function onActivate(id)
  local query = tostring(id or ""):match("^capture:(.*)$")
  if not query then return end
  local parsed = logic.parse_capture(query, now_ms(), day())
  if parsed.title == "" then return end

  send_add(parsed)
  noctalia.notify("medo", string.format('Sold. "%s" is on today\'s list.', parsed.title))
  -- "" resets the launcher input to its root; the launcher stays open
  launcher.setQuery("")
end
