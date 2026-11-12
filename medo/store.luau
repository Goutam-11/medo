--!nonstrict
-- medo store — the only module that touches disk.
--
-- Layout inside noctalia.pluginDataDir() (owner-only, survives plugin updates):
--   tasks.json           live document (schema 1)
--   tasks.json.bak       previous generation, used when tasks.json is unreadable
--   history.json         one aggregate snapshot per closed day
--   backups/tasks-<day>.json   last 14 rollover snapshots
--
-- Writes are atomic: encode → write .tmp → rotate the current file to .bak →
-- rename .tmp into place. A crash leaves either the old file, the .tmp, or the
-- .bak — never a half-written document.

local M = {}

local DATA_FILE = "tasks.json"
local HISTORY_FILE = "history.json"
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
    noctalia.notifyError("medo", "tasks.json was unreadable; recovered the previous copy")
    return backup, nil
  end

  if not noctalia.fileExists(path) and not noctalia.fileExists(path .. ".bak") then
    return nil, "missing"
  end
  return nil, "corrupt"
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
  local dir, err = M.dir()
  if not dir then return false, err end
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
  table.sort(history.days, function(a, b) return (a.day or "") < (b.day or "") end)
  return write_atomic(join(dir, HISTORY_FILE), history)
end

function M.history_path()
  local dir = M.dir()
  return dir and join(dir, HISTORY_FILE) or nil
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
