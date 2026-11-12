--!nonstrict
-- medo core service.
--
-- Phase 0 scaffold: publish an empty view every second so the bar widget and the
-- panel have a live snapshot to render, and answer two IPC pokes used by the
-- dev loop. Phase 1 adds the store (tasks.json), the logical day, rollover and
-- reminders here; nothing else in the plugin writes data files.

-- The snapshot every other entry renders from. Kept deliberately small: the
-- panel reads the same table, so anything added here must stay serialisable to
-- noctalia.state.
local view = {
  day = "",
  done = 0,
  total = 0,
  score = 0,
  carried = 0,
  ready = false,
}

local function today()
  local now = os.date("*t")
  return string.format("%04d-%02d-%02d", now.year, now.month, now.day)
end

local function publish()
  noctalia.state.set("view", view)
end

function update()
  view.day = today()
  view.ready = true
  publish()
end

function onIpc(event, payload)
  if event == "ping" then
    -- proves the service is alive and the IPC path works end to end
    noctalia.notify("medo", string.format("core alive · %s · %d/%d", view.day, view.done, view.total))
    publish()
  elseif event == "rollover" then
    -- Phase 1 wires the real rollover; the hole is deliberate so the IPC path
    -- can be tested before the logic exists.
    noctalia.notify("medo", "rollover is not wired yet (phase 1)")
  end
end

noctalia.setUpdateInterval(1000)
update()
