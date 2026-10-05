---@module 'tasks_nvim.frecency'
---@brief How often and how recently a task was touched in the dashboard: the score behind `--sort=frecency`.
---@description
--- A small, self-contained ranking. Every entry is `{ score, last }`: `score` is
--- a decayed counter, `last` the second of the latest visit. A visit adds 1
--- after the old score has been decayed to "now", so the score is the sum of
--- all visits, each weighted `0.5 ^ (age / half_life)` (default half-life: 14
--- days). A task opened three times today outranks one opened five times last
--- month, and one that is left alone fades out by itself.
---
--- The scoring is pure: every function takes the table and the time it should
--- use, so a spec can drive the clock. Only `load` / `save` / `record` touch a
--- file (`stdpath("state")/tasks/frecency.json`, or `$TASKS_FRECENCY_FILE`, or
--- `set_path`), keyed by task id (`<area>/<slug>`).
---
--- Key responsibilities:
---  - `decayed` / `bump` / `scores`: the arithmetic
---  - `prune`: drop entries that faded below `MIN_SCORE`, keep at most `MAX_ENTRIES`
---  - `decode` / `encode`: the file format; entries that do not validate are dropped
---  - `load` / `save` / `record`: persistence; a corrupt file starts empty (the old
---    bytes are kept as `<file>.bad`), an unreadable one is never overwritten
---
--- Not its job: windows, keys, which action counts as a visit (`tasks_dash`), or
--- how the score orders a list (`model.sort`).
---
--- Why not `lib.nvim.frecency`: that store ranks by fixed recency buckets with
--- `os.time()` baked in (no clock to inject), has no entry cap and no half-life;
--- the task dashboard wants a smooth decay it can specify and test.

local fsio = require("tasks_nvim.fsio")

local uv = vim.uv or vim.loop

local M = {}

---Days after which a visit counts half as much.
M.HALF_LIFE_DAYS = 14

---Most entries kept in the file; the lowest scores go first.
M.MAX_ENTRIES = 500

---An entry whose decayed score is below this is forgotten (about 60 days of silence after one visit).
M.MIN_SCORE = 0.05

---Format version written to the file.
M.VERSION = 1

---A file bigger than this is not ours: `MAX_ENTRIES` rows of at most `MAX_ID_LENGTH`
---characters are about 120 KiB. Reading (and decoding) a runaway file on every
---dashboard refresh would stall the editor, so it counts as corrupt (SEC-32).
M.MAX_FILE_BYTES = 1024 * 1024

local DAY_SECONDS = 86400

---@class Tasks.FrecencyEntry
---@field score number   # The decayed counter as of `last`.
---@field last integer   # Unix seconds of the latest visit.

---@alias Tasks.FrecencyEntries table<string, Tasks.FrecencyEntry>

---@class Tasks.FrecencyOpts
---@field now? number|fun(): number   # Unix seconds; default `os.time()`.
---@field half_life_days? number
---@field max_entries? integer
---@field path? string                # The file; default `M.path()`.

---@param opts Tasks.FrecencyOpts|nil
---@return number
local function now_of(opts)
  local n = opts and opts.now
  if type(n) == "function" then
    n = n()
  end
  return type(n) == "number" and n or os.time()
end

---@param opts Tasks.FrecencyOpts|nil
---@return number
local function half_life_of(opts)
  local h = opts and opts.half_life_days
  return (type(h) == "number" and h > 0) and h or M.HALF_LIFE_DAYS
end

-- ── arithmetic ───────────────────────────────────────────────────────────────

---The score of an entry at `now`. A clock that went backwards counts as "just now".
---@param entry Tasks.FrecencyEntry|nil
---@param now number
---@param opts? Tasks.FrecencyOpts
---@return number
function M.decayed(entry, now, opts)
  if type(entry) ~= "table" or type(entry.score) ~= "number" then
    return 0
  end
  local age = math.max(0, now - (entry.last or now))
  return entry.score * 0.5 ^ (age / (half_life_of(opts) * DAY_SECONDS))
end

---Record one visit of `id` (in place): decay the old score to `now`, add `weight`.
---@param entries Tasks.FrecencyEntries
---@param id string
---@param now number
---@param opts? Tasks.FrecencyOpts
---@param weight? number   # Default 1.
---@return Tasks.FrecencyEntry|nil entry  # nil for an empty or non-string id
function M.bump(entries, id, now, opts, weight)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  local entry = {
    score = M.decayed(entries[id], now, opts) + (weight or 1),
    last = math.floor(now),
  }
  entries[id] = entry
  return entry
end

---Forget what faded and cap the table (in place). Ties at the cap break towards
---the more recent visit, then the id, so the result is deterministic.
---@param entries Tasks.FrecencyEntries
---@param now number
---@param opts? Tasks.FrecencyOpts
---@return integer removed
function M.prune(entries, now, opts)
  local removed = 0
  local live = {}
  for id, entry in pairs(entries) do
    local s = M.decayed(entry, now, opts)
    if s < M.MIN_SCORE then
      entries[id] = nil
      removed = removed + 1
    else
      live[#live + 1] = { id = id, score = s, last = entry.last or 0 }
    end
  end
  local max = (opts and opts.max_entries) or M.MAX_ENTRIES
  if #live > max then
    table.sort(live, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      if a.last ~= b.last then
        return a.last > b.last
      end
      return a.id < b.id
    end)
    for i = max + 1, #live do
      entries[live[i].id] = nil
      removed = removed + 1
    end
  end
  return removed
end

---The current score of every entry that still counts (`>= MIN_SCORE`).
---@param entries Tasks.FrecencyEntries
---@param now number
---@param opts? Tasks.FrecencyOpts
---@return table<string, number> scores
function M.scores(entries, now, opts)
  local out = {}
  for id, entry in pairs(entries) do
    local s = M.decayed(entry, now, opts)
    if s >= M.MIN_SCORE then
      out[id] = s
    end
  end
  return out
end

-- ── file format ──────────────────────────────────────────────────────────────

---Longest task id taken from a file; anything longer is not an id this system wrote.
local MAX_ID_LENGTH = 200

---Parse the file text. `nil, err` when it is not a frecency file at all; single
---entries that do not validate are skipped, so one bad row never costs the rest.
---@param text string|nil
---@return Tasks.FrecencyEntries|nil entries
---@return string|nil err
function M.decode(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil, "empty file"
  end
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, "not valid JSON"
  end
  local rows = data.entries
  if type(rows) ~= "table" then
    return nil, "no entries table"
  end
  local out = {}
  for id, e in pairs(rows) do
    if
      type(id) == "string"
      and id ~= ""
      and #id <= MAX_ID_LENGTH
      and type(e) == "table"
      and type(e.score) == "number"
      and type(e.last) == "number"
      and e.score == e.score -- not NaN
      and e.score > 0
      and e.score < math.huge
      and e.last == e.last
      and e.last > 0
      and e.last < math.huge
    then
      out[id] = { score = e.score, last = math.floor(e.last) }
    end
  end
  return out, nil
end

---@param entries Tasks.FrecencyEntries
---@return string
function M.encode(entries)
  local rows = {}
  for id, e in pairs(entries) do
    rows[id] = { score = math.floor(e.score * 10000 + 0.5) / 10000, last = e.last }
  end
  -- An empty Lua table would encode as `[]`; the reader wants an object.
  if next(rows) == nil then
    return '{"version":' .. M.VERSION .. ',"entries":{}}'
  end
  return vim.json.encode({ version = M.VERSION, entries = rows })
end

-- ── persistence ──────────────────────────────────────────────────────────────

---@type string|nil
local override_path

---Pin the file for this process (nil clears it). Used by specs.
---@param path string|nil
function M.set_path(path)
  override_path = path and fsio.norm(path) or nil
end

---Where the entries live: `set_path`, `$TASKS_FRECENCY_FILE`, then `stdpath("state")/tasks/frecency.json`.
---@return string
function M.path()
  if override_path and override_path ~= "" then
    return override_path
  end
  local env = vim.env.TASKS_FRECENCY_FILE
  if env and env ~= "" then
    return fsio.norm(env)
  end
  return fsio.norm(vim.fn.stdpath("state")) .. "/tasks/frecency.json"
end

---@alias Tasks.FrecencyStatus "ok"|"missing"|"corrupt"|"unreadable"

---Read the file. Never raises and never returns nil entries: a missing, corrupt
---or unreadable file is an empty table, with the reason in `status`.
---@param opts? Tasks.FrecencyOpts
---@return Tasks.FrecencyEntries entries
---@return Tasks.FrecencyStatus status
---@return string|nil err
function M.load(opts)
  local path = (opts and opts.path) or M.path()
  local st = uv.fs_stat(path)
  if not st then
    return {}, "missing", nil
  end
  if st.type == "file" and st.size > M.MAX_FILE_BYTES then
    return {}, "corrupt", ("file is %d bytes, more than %d"):format(st.size, M.MAX_FILE_BYTES)
  end
  local text, rerr = fsio.read(path)
  if not text then
    return {}, "unreadable", tostring(rerr)
  end
  local entries, derr = M.decode(text)
  if not entries then
    return {}, "corrupt", derr
  end
  return entries, "ok", nil
end

---Write the table (atomically, parent folder created).
---@param entries Tasks.FrecencyEntries
---@param opts? Tasks.FrecencyOpts
---@return boolean ok
---@return string|nil err
function M.save(entries, opts)
  local path = (opts and opts.path) or M.path()
  return fsio.write_atomic(path, M.encode(entries))
end

---Count one visit for each id and write the result. A file that could not be
---read is left alone (its content may be fine, only this read failed); a
---corrupt one is replaced, the old bytes kept as `<file>.bad`.
---@param ids string|string[]
---@param opts? Tasks.FrecencyOpts
---@return boolean ok
---@return string|nil err
function M.record(ids, opts)
  if type(ids) == "string" then
    ids = { ids }
  end
  if type(ids) ~= "table" or #ids == 0 then
    return true, nil
  end
  local path = (opts and opts.path) or M.path()
  local entries, status, lerr = M.load(opts)
  if status == "unreadable" then
    return false, "frecency file not readable: " .. tostring(lerr)
  end
  if status == "corrupt" then
    pcall(uv.fs_rename, path, path .. ".bad")
  end
  local now = now_of(opts)
  local seen = {}
  for _, id in ipairs(ids) do
    -- One action on a task is one visit, however often the id is passed.
    if not seen[id] then
      seen[id] = true
      M.bump(entries, id, now, opts)
    end
  end
  M.prune(entries, now, opts)
  return M.save(entries, opts)
end

---The current scores from the file (empty when there is none). What
---`model.sort(tasks, "frecency")` uses when it is not handed a table.
---@param opts? Tasks.FrecencyOpts
---@return table<string, number> scores
function M.load_scores(opts)
  local entries = M.load(opts)
  return M.scores(entries, now_of(opts), opts)
end

return M
