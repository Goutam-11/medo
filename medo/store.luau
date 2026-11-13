--!nonstrict
-- medo store — the only module that touches disk.
--
-- Layout inside noctalia.pluginDataDir() (owner-only, survives plugin updates):
--   tasks.json           live document (schema 1)
--   tasks.json.bak       previous generation, used when tasks.json is unreadable
--   history.json         one aggregate snapshot per closed day
--   state.json           notification dedupe (day + notified keys)
--   backups/tasks-<day>.json   last 14 rollover snapshots
--
-- Writes are atomic: encode → write .tmp → rotate the current file to .bak →
-- rename .tmp into place. A crash leaves either the old file, the .tmp, or the
-- .bak — never a half-written document.

local M = {}

local DATA_FILE = "tasks.json"
local HISTORY_FILE = "history.json"
local STATE_FILE = "state.json"
local BACKUP_DIR = "backups"
local KEEP_BACKUPS = 14
local SCHEMA = 1

local function join(dir, name)
  return dir .. "/" .. name
end

function M.dir()
  local dir, err = noctalia.pluginDataDir()
  if not dir then return nil, err or "no plugin data directory" end
  return dir
end

local function read_json(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, value = pcall(noctalia.json.decode, raw)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function write_atomic(path, value, keep_previous)
  local raw, err = noctalia.json.encode(value, true)
  if not raw then return false, err or "could not encode JSON" end

  local tmp = path .. ".tmp"
  local wrote, write_err = noctalia.writeFile(tmp, raw)
  if not wrote then return false, write_err end

  if keep_previous ~= false and noctalia.fileExists(path) then
    noctalia.renameFile(path, path .. ".bak")
  end

  local moved, move_err = noctalia.renameFile(tmp, path)
  if not moved then
    -- rename can fail on some filesystems; fall back to a direct write
    local direct, direct_err = noctalia.writeFile(path, raw)
    noctalia.removeFile(tmp)
    if not direct then return false, direct_err or move_err end
  end
  return true
end

-- Returns doc, nil on success; nil, "missing" when there is no document yet;
-- nil, "corrupt" when the file is unreadable and no backup recovered it.
function M.load()
  local dir, err = M.dir()
  if not dir then return nil, err end

  local path = join(dir, DATA_FILE)
  local doc = read_json(path)
  if doc and doc.schema == SCHEMA then return doc, nil end

  local backup = read_json(path .. ".bak")
  if backup and backup.schema == SCHEMA then
    noctalia.notifyError(noctalia.tr("plugin.name"), noctalia.tr("error.recovered"))
    return backup, nil
  end

  if not noctalia.fileExists(path) and not noctalia.fileExists(path .. ".bak") then
    return nil, "missing"
  end
  return nil, "corrupt"
end

-- Read an import candidate from any path the shell can read (a copy of
-- tasks.json, a backups/ file, the export folder). `noctalia.readFile` resolves
-- `~`, absolute paths verbatim, and everything else plugin-relative. Decoding
-- only — a JSON scalar is not a document — and this never writes: schema and
-- shape belong to logic.validate_import. Failures come back as copy keys; an
-- unreadable path keeps the shell's own message for core.luau to interpolate.
function M.read_document(path)
  if type(path) ~= "string" then return nil, "error.import_path" end
  local target = path:gsub("^%s+", ""):gsub("%s+$", "")
  if target == "" then return nil, "error.import_path" end

  local raw, err = noctalia.readFile(target)
  if type(raw) ~= "string" or raw == "" then
    if type(err) == "string" and err ~= "" then return nil, err end
    return nil, "error.import_empty"
  end

  local ok, value = pcall(noctalia.json.decode, raw)
  if not ok then return nil, "error.import_json" end
  if type(value) ~= "table" then return nil, "error.import_json" end
  return value, nil
end

function M.save(doc)
  local dir, err = M.dir()
  if not dir then return false, err end
  doc.revision = (tonumber(doc.revision) or 0) + 1
  doc.updated_ms = noctalia.nowMs()
  return write_atomic(join(dir, DATA_FILE), doc)
end

function M.load_history()
  local dir, err = M.dir()
  if not dir then return nil, err end
  local history = read_json(join(dir, HISTORY_FILE))
  if type(history) == "table" and type(history.days) == "table" then return history end
  return { schema = SCHEMA, days = {} }
end

-- One entry per day: a repeated close of the same day replaces the old row.
function M.append_history(snapshot)
  local history = M.load_history()
  local replaced = false
  for index, day in ipairs(history.days) do
    if day.day == snapshot.day then
      history.days[index] = snapshot
      replaced = true
      break
    end
  end
  if not replaced then history.days[#history.days + 1] = snapshot end
  return M.save_history(history)
end

-- Whole-file write, used by the debug fixture that replays several days.
function M.save_history(history)
  local dir, err = M.dir()
  if not dir then return false, err end
  if type(history) ~= "table" or type(history.days) ~= "table" then
    return false, "history must be { schema = 1, days = { ... } }"
  end
  history.schema = SCHEMA
  table.sort(history.days, function(a, b) return (a.day or "") < (b.day or "") end)
  return write_atomic(join(dir, HISTORY_FILE), history)
end

function M.history_path()
  local dir = M.dir()
  return dir and join(dir, HISTORY_FILE) or nil
end

-- Notification dedupe state. A missing or unreadable file is an empty state,
-- never an error: a lost toast is better than a broken service.
function M.load_state()
  local dir, err = M.dir()
  if not dir then return nil, err end
  local state = read_json(join(dir, STATE_FILE))
  if type(state) == "table" and state.schema == SCHEMA then
    if type(state.notified) ~= "table" then state.notified = {} end
    return state
  end
  return { schema = SCHEMA, day = nil, notified = {} }
end

function M.save_state(state)
  local dir, err = M.dir()
  if not dir then return false, err end
  if type(state) ~= "table" then return false, "state must be a table" end
  state.schema = SCHEMA
  return write_atomic(join(dir, STATE_FILE), state)
end

function M.state_path()
  local dir = M.dir()
  return dir and join(dir, STATE_FILE) or nil
end

-- Resolve the export folder setting. Empty means $XDG_DOCUMENTS_DIR, then
-- ~/Documents; expandPath handles a leading ~.
function M.export_dir(configured)
  local raw = tostring(configured or "")
  raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then
    local documents = noctalia.getenv("XDG_DOCUMENTS_DIR")
    raw = (type(documents) == "string" and documents ~= "") and documents or "~/Documents"
  end
  local expanded = noctalia.expandPath(raw)
  if type(expanded) ~= "string" or expanded == "" then return raw end
  return (expanded:gsub("/+$", ""))
end

-- Exports are plain text outside the plugin data dir; only store writes files.
function M.write_text(path, contents)
  if type(path) ~= "string" or path == "" then return false, "empty export path" end
  local dir = path:match("^(.*)/[^/]*$")
  if dir and dir ~= "" then
    local ok, err = noctalia.mkdirAll(dir)
    if not ok then return false, err end
  end
  return noctalia.writeFile(path, contents)
end

function M.data_path()
  local dir = M.dir()
  return dir and join(dir, DATA_FILE) or nil
end

-- Dated copy taken at rollover; the newest 14 are kept.
function M.backup(doc, day)
  local dir, err = M.dir()
  if not dir then return false, err end
  local backup_dir = join(dir, BACKUP_DIR)
  local ok, mkdir_err = noctalia.mkdirAll(backup_dir)
  if not ok then return false, mkdir_err end

  local label = type(day) == "string" and day or "unknown"
  local saved, save_err = write_atomic(join(backup_dir, "tasks-" .. label .. ".json"), doc, false)
  if not saved then return false, save_err end

  local names = noctalia.listDir(backup_dir) or {}
  table.sort(names)
  while #names > KEEP_BACKUPS do
    noctalia.removeFile(join(backup_dir, names[1]))
    table.remove(names, 1)
  end
  return true
end

return M
