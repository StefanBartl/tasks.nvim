---@module 'tasks_nvim.ui.dash_watch'
---@brief The file watcher behind the dashboard's auto-refresh: which folders, one debounce for all of them, quiet during its own batches.
---@description
--- While the task dashboard is open it watches the folders its list is made of
--- and calls `on_refresh` once when something changed -- a task edited, created,
--- moved to `Backlog/` or deleted, by this Neovim, another one or a Claude
--- session. The dashboard then rescans and keeps cursor, marks, filter and sort.
---
--- Which folders (`M.dirs`, non-recursive handles only, so it behaves the same
--- on Windows, macOS and Linux -- libuv's `recursive` flag is a no-op on Linux):
---  - `<area>/ROADMAP/tasks` and each folder directly inside it (folder tasks);
---    where there is no `tasks/` yet, `<area>/ROADMAP` until `tasks/` shows up (an `only`
---    handle: a burst of events there counts once `tasks/` exists, whatever file name it ended on)
---  - `<area>/Backlog/FEATURES` and `<area>/Backlog/TASKS`, where finished tasks land
---  - the areas: the one shown, else every area of the vault
---
--- Key responsibilities:
---  - `new` / `start` / `stop`: handles from `lib.nvim.fs.watch` (guarded close, own
---    short debounce per handle), all stopped by `stop`, which is safe to call twice
---  - one coalescing debounce over every handle: fifty events from one `git pull`
---    are one refresh
---  - `hold`: the dashboard's own batches. Events from its writes are dropped (during
---    the batch and for `mute_ms` after it) and a pending refresh is cancelled, because
---    the caller rescans right after the batch; no double scan
---  - `sync` after every refresh: folders that appeared are watched, folders that
---    vanished are released
---  - failure to watch is reported by `start` (`false, err`), never raised, so the
---    dashboard falls back to the manual `r`
---
--- Seams for specs: `start` (the handle factory), `schedule` (the debounce timer),
--- `now` (a clock in ms).
---
--- Not its job: what a refresh does (`tasks_dash`), what is a task (`tasks.scan`).
---
--- `filename` handling: libuv reports it relative to the watched folder, but on
--- Windows it can carry a folder prefix (`\0\x.md`, see the vault task
--- `lib.nvim/fs-watch-filename-normalize`), so only its last component is used.

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---@class Plugin_repos.TasksDashWatchDir
---@field path string
---@field only? string   # Waiting for this entry (a folder that may not exist yet): events count once it exists.

---@class Plugin_repos.TasksDashWatchOpts
---@field root string
---@field area? string|nil               # nil: every area of the vault.
---@field on_refresh fun()               # Called on the main loop, once per quiet period.
---@field debounce_ms? integer           # Quiet period over all handles (default 250).
---@field mute_ms? integer               # Quiet time after `hold` (default 300).
---@field raw_debounce_ms? integer       # Per-handle debounce of `lib.nvim.fs.watch` (default 20).
---@field backlog? boolean               # Watch `Backlog/FEATURES|TASKS` too (default true).
---@field start? fun(path: string, on_change: fun(path: string, filename: string|nil, events: table), opts: table): table|nil, string|nil
---@field schedule? fun(ms: integer, fn: fun()): fun()   # Returns a cancel function.
---@field now? fun(): number             # Milliseconds, monotonic.

M.DEFAULTS = { debounce_ms = 250, mute_ms = 300, raw_debounce_ms = 20, backlog = true }

---The last path component, either slash.
---@param name string|nil
---@return string|nil
local function last_component(name)
  if name == nil then
    return nil
  end
  return (name:match("([^/\\]+)[/\\]*$"))
end

---Whether an event for `filename` can change what the dashboard shows. Editor
---droppings (swap files, `4913` probes, `~` backups, our own temp files) cannot;
---an event without a name is assumed to matter.
---@param filename string|nil
---@return boolean
function M.relevant(filename)
  local base = last_component(filename)
  if base == nil or base == "" then
    return true
  end
  if base:sub(1, 1) == "." or base:sub(-1) == "~" or base:match("^%d+$") then
    return false
  end
  if base:find(".tasks-tmp.", 1, true) then
    return false
  end
  return true
end

---The folders below `dir` (names only, sorted).
---@param dir string
---@return string[]
local function subdirs(dir)
  local out = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---The folders to watch for a dashboard scope (see the module header).
---@param root string
---@param area string|nil
---@param opts? { backlog?: boolean }
---@return Plugin_repos.TasksDashWatchDir[]
function M.dirs(root, area, opts)
  local with_backlog = not (opts and opts.backlog == false)
  local names = {}
  if area then
    if vault.valid_area(area) then
      names[1] = area
    end
  else
    for _, a in ipairs(vault.areas(root)) do
      names[#names + 1] = a.name
    end
  end
  local out = {}
  for _, name in ipairs(names) do
    local tasks = vault.tasks_dir(root, name)
    if fsio.is_dir(tasks) then
      out[#out + 1] = { path = tasks }
      for _, sub in ipairs(subdirs(tasks)) do
        out[#out + 1] = { path = tasks .. "/" .. sub }
      end
    else
      local roadmap = root .. "/" .. name .. "/ROADMAP"
      if fsio.is_dir(roadmap) then
        out[#out + 1] = { path = roadmap, only = "tasks" }
      end
    end
    if with_backlog then
      for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
        local dir = vault.backlog_dir(root, name, bucket)
        if fsio.is_dir(dir) then
          out[#out + 1] = { path = dir }
        end
      end
    end
  end
  return out
end

---The default timer: one libuv timer per pending refresh, closed when it fires
---or is cancelled.
---@param ms integer
---@param fn fun()
---@return fun() cancel
local function default_schedule(ms, fn)
  local timer = uv.new_timer()
  if not timer then
    vim.schedule(fn)
    return function() end
  end
  local done = false
  local function close()
    if done then
      return
    end
    done = true
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      pcall(timer.close, timer)
    end
  end
  timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      if done then
        return
      end
      close()
      fn()
    end)
  )
  return close
end

---The handle factory: `lib.nvim.fs.watch` when it is there.
---@param path string
---@param on_change fun(path: string, filename: string|nil, events: table)
---@param opts table
---@return table|nil handle
---@return string|nil err
local function default_start(path, on_change, opts)
  local ok, watch = pcall(require, "lib.nvim.fs.watch")
  if not ok or type(watch) ~= "table" or type(watch.start) ~= "function" then
    return nil, "lib.nvim.fs.watch is not available"
  end
  return watch.start(path, on_change, opts)
end

---@return number
local function default_now()
  return uv.hrtime() / 1e6
end

---@class Plugin_repos.TasksDashWatcher
---@field opts Plugin_repos.TasksDashWatchOpts
---@field handles table<string, { handle: table, only?: string }>
---@field stopped boolean
---@field held boolean
---@field mute_until number
---@field gen integer
---@field cancel_timer? fun()
---@field partial? { started: integer, wanted: integer, err: string|nil }
---@field stats { events: integer, muted: integer, refreshes: integer }
local Watcher = {}
Watcher.__index = Watcher

---@param opts Plugin_repos.TasksDashWatchOpts
---@return Plugin_repos.TasksDashWatcher
function M.new(opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts)
  o.start = o.start or default_start
  o.schedule = o.schedule or default_schedule
  o.now = o.now or default_now
  return setmetatable({
    opts = o,
    handles = {},
    stopped = true,
    held = false,
    mute_until = 0,
    gen = 0,
    stats = { events = 0, muted = 0, refreshes = 0 },
  }, Watcher)
end

---Number of folders being watched.
---@return integer
function Watcher:count()
  local n = 0
  for _ in pairs(self.handles) do
    n = n + 1
  end
  return n
end

---@return boolean
function Watcher:active()
  return not self.stopped
end

function Watcher:disarm()
  self.gen = self.gen + 1
  local cancel = self.cancel_timer
  self.cancel_timer = nil
  if cancel then
    pcall(cancel)
  end
end

function Watcher:arm()
  self:disarm()
  local gen = self.gen
  self.cancel_timer = self.opts.schedule(self.opts.debounce_ms, function()
    if gen == self.gen then
      self:fire()
    end
  end)
end

---One raw event: filter, and (unless the dashboard is writing itself) arm the debounce.
---@param only string|nil
---@param filename string|nil
---@param dir? string  # The watched folder; needed to judge an `only` handle.
function Watcher:on_event(only, filename, dir)
  if self.stopped then
    return
  end
  if only then
    if dir then
      -- `lib.nvim.fs.watch` debounces per handle and hands over only the LAST name of a burst:
      -- creating the first task of an area is `tasks` and then `TASKS.md` within a few ms, so the
      -- name says nothing reliable. Ask the file system whether the folder we wait for is there.
      if not fsio.is_dir(dir .. "/" .. only) then
        return
      end
    elseif filename ~= nil and last_component(filename) ~= only then
      return
    end
  elseif not M.relevant(filename) then
    return
  end
  if self.held or self.opts.now() < self.mute_until then
    self.stats.muted = self.stats.muted + 1
    return
  end
  self.stats.events = self.stats.events + 1
  self:arm()
end

---The quiet period is over: refresh, then re-aim the handles at what is there now.
function Watcher:fire()
  self.cancel_timer = nil
  if self.stopped then
    return
  end
  self.stats.refreshes = self.stats.refreshes + 1
  pcall(self.opts.on_refresh)
  if not self.stopped then
    pcall(self.sync, self)
  end
end

---Aim the handles at the folders that exist now: new ones started, vanished
---ones released. Failures are counted, not raised.
---@return integer started  # Handles watching after the call.
---@return integer wanted
---@return string|nil first_err
function Watcher:sync()
  local wanted = M.dirs(self.opts.root, self.opts.area, { backlog = self.opts.backlog })
  local want = {}
  for _, d in ipairs(wanted) do
    want[d.path] = d
  end
  for path, h in pairs(self.handles) do
    local d = want[path]
    if not d or d.only ~= h.only then
      pcall(h.handle.stop)
      self.handles[path] = nil
    end
  end
  local first_err
  for _, d in ipairs(wanted) do
    if not self.handles[d.path] then
      local only = d.only
      local dir = d.path
      local handle, err = self.opts.start(dir, function(_, filename)
        self:on_event(only, filename, dir)
      end, { debounce_ms = self.opts.raw_debounce_ms })
      if handle then
        self.handles[d.path] = { handle = handle, only = only }
      else
        first_err = first_err or tostring(err)
      end
    end
  end
  return self:count(), #wanted, first_err
end

---Start watching. `false, err` when there was something to watch and nothing
---could be (the dashboard then falls back to `r`); a partial result is `true`
---with `self.partial` set.
---@return boolean ok
---@return string|nil err
function Watcher:start()
  if not self.stopped then
    return true, nil
  end
  self.stopped = false
  self.partial = nil
  local started, wanted, err = self:sync()
  if wanted > 0 and started == 0 then
    self:stop()
    return false, err or "no folder could be watched"
  end
  if started < wanted then
    self.partial = { started = started, wanted = wanted, err = err }
  end
  return true, nil
end

---Stop everything: pending timer and every handle. Idempotent.
function Watcher:stop()
  self.stopped = true
  self:disarm()
  for path, h in pairs(self.handles) do
    pcall(h.handle.stop)
    self.handles[path] = nil
  end
end

---Run `fn` (a write batch of the dashboard itself) without echoing it back as a
---refresh: events during and shortly after it are dropped, and a refresh that
---was already pending is cancelled -- the caller rescans right after the batch.
---Returns what `fn` returns; an error in `fn` is re-raised after the books are straight.
---@generic T
---@param fn fun(): T
---@return T
function Watcher:hold(fn)
  local outer = self.held
  self.held = true
  local res = vim.F.pack_len(pcall(fn))
  self.held = outer
  if not outer then
    self.mute_until = self.opts.now() + self.opts.mute_ms
    self:disarm()
  end
  if not res[1] then
    error(res[2], 0)
  end
  return (table.unpack or unpack)(res, 2, res.n)
end

return M
