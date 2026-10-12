---@module 'tasks_nvim.ui.reminder_hint'
---@brief One line at the start of Neovim: how many reminders (`remind:`) are due.
---@description
--- Opt-out (`setup({ reminders = { on_start = false } })`; the option is read again when the timer fires, so a later
--- `setup()` that turns it off cancels a hint that is already waiting). Runs a moment after startup, once per
--- session, only with a UI, and says nothing when nothing is due or no vault is there.
---
--- The scan is the cost. The first one in a process looks at every task file, open and finished (on a vault of about
--- 650 open and 550 finished tasks: about 0.4 s), because what was seen is remembered only for the life of the
--- process. So the hint scans in steps, one area per turn of the event loop, and no step holds the editor for long.
--- A file is searched for its `remind:` line and parsed only when it has one; a file that has not changed since the
--- last look costs a stat.
---
--- Not its job: setting or listing reminders (`tasks_nvim.mutate`, `:Tasks list --reminders`).

local M = {}

---Whether the hint was given in this session (a second `setup()` does not repeat it).
local announced = false

---How many finished tasks the line names (the rest is a count).
local NAMED_MAX = 3

---@class Tasks.RemindersDue
---@field open integer      # Open tasks with a reminder that is due.
---@field done Tasks.Task[] # Finished tasks with a reminder that is due.

---@param task Tasks.Task
---@param today string
---@return boolean
local function is_due(task, today)
  return require("tasks_nvim.model").is_date(task.remind) and task.remind <= today
end

---The vault and its areas for a scan; nil when there is no vault.
---@param opts? Tasks.ScanOpts
---@return string|nil root
---@return string[] names
local function areas_of(opts)
  local vault = require("tasks_nvim.vault")
  local root = vault.root(opts)
  local names = {}
  if root then
    for _, area in ipairs(vault.areas(root)) do
      names[#names + 1] = area.name
    end
  end
  return root, names
end

---Add what is due in one area to `total`.
---@param total Tasks.RemindersDue
---@param root string
---@param name string
---@param today string
local function add_area(total, root, name, today)
  local scan = require("tasks_nvim.scan")
  for _, task in ipairs(scan.open_reminders({ root = root, area = name }) or {}) do
    if is_due(task, today) then
      total.open = total.open + 1
    end
  end
  for _, task in ipairs(scan.backlog_reminders({ root = root, area = name }) or {}) do
    if is_due(task, today) then
      total.done[#total.done + 1] = task
    end
  end
end

---@param total Tasks.RemindersDue
---@return integer open
---@return integer done
---@return string[] done_ids  # The finished tasks, the oldest date first.
local function summary(total)
  table.sort(total.done, function(a, b)
    if a.remind ~= b.remind then
      return a.remind < b.remind
    end
    return a.id < b.id
  end)
  local ids = {}
  for _, task in ipairs(total.done) do
    ids[#ids + 1] = task.id
  end
  return total.open, #total.done, ids
end

---How many tasks, open or finished, have a reminder whose date is today or earlier, in one go. `announce` and the
---specs use it; the hint at startup uses `count_in_steps`.
---@param opts? Tasks.ScanOpts
---@return integer open  # Open tasks with a reminder that is due.
---@return integer done  # Finished tasks with a reminder that is due.
---@return string[] done_ids  # The finished ones, the oldest date first.
function M.count(opts)
  local today = (opts and opts.today) or require("tasks_nvim.model").today()
  local root, names = areas_of(opts)
  local total = { open = 0, done = {} }
  if root then
    for _, name in ipairs(names) do
      add_area(total, root, name, today)
    end
  end
  return summary(total)
end

---The same answer, one area per turn of the event loop. `on_done` is called once: with the numbers, or with `nil` when
---a step failed (a scan that fails is silence, not an error).
---@param opts? Tasks.ScanOpts
---@param on_done fun(open: integer|nil, done: integer, done_ids: string[])
---@return nil
function M.count_in_steps(opts, on_done)
  local ok, root, names = pcall(areas_of, opts)
  if not ok or not root then
    on_done(ok and 0 or nil, 0, {})
    return
  end
  local today = (opts and opts.today) or require("tasks_nvim.model").today()
  local total = { open = 0, done = {} }
  local at = 0
  local function step()
    at = at + 1
    if at > #names then
      on_done(summary(total))
      return
    end
    if not pcall(add_area, total, root, names[at], today) then
      on_done(nil, 0, {})
      return
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

---The text of the hint; `nil` when nothing is due. The finished tasks are named (three at most): `:Tasks list` shows
---the open ones only.
---@param open integer
---@param done integer
---@param extra? { ids?: string[], command?: boolean }  # The finished ones; whether `:Tasks` exists (default: asked).
---@return string|nil
function M.message(open, done, extra)
  local total = open + done
  if total == 0 then
    return nil
  end
  extra = extra or {}
  local command = extra.command
  if command == nil then
    command = vim.fn.exists(":Tasks") == 2
  end
  local text = ("%d reminder%s due"):format(total, total == 1 and "" or "s")
  if done > 0 then
    local ids = extra.ids or {}
    local fsio = require("tasks_nvim.fsio")
    -- an id is a file name of the vault: nothing in it reaches the message line as a control character
    local named = vim.tbl_map(fsio.clean, vim.list_slice(ids, 1, NAMED_MAX))
    local who = ""
    if #named > 0 then
      who = ": " .. table.concat(named, ", ")
      if #ids > #named then
        who = who .. (" +%d more"):format(#ids - #named)
      end
    end
    text = text
      .. (" (%d of them finished%s%s)"):format(done, who, command and "; `:Tasks open <id>`" or "")
  end
  if open > 0 then
    if command then
      text = text .. ": `:Tasks list --reminders`" .. (done > 0 and " for the open ones" or "")
    else
      text = text .. "; the reminders filter lists the open ones"
    end
  end
  return text
end

---Say it, when there is something to say.
---@param open integer
---@param done integer
---@param ids string[]
---@return boolean given
local function give(open, done, ids)
  local text = M.message(open, done, { ids = ids })
  if not text then
    return false
  end
  require("lib.nvim.notify").create("[tasks]").info(text)
  return true
end

---Give the hint once, in one go. A vault that is not there, or a scan that fails, is silence, not an error.
---@param opts? Tasks.ScanOpts
---@return boolean given
function M.announce(opts)
  if announced then
    return false
  end
  announced = true
  local ok, open, done, ids = pcall(M.count, opts)
  if not ok then
    return false
  end
  return give(open, done, ids)
end

---Give the hint once, scanning in steps (see `count_in_steps`).
---@param opts? Tasks.ScanOpts
---@param on_done? fun(given: boolean)  # Called when the hint is given or has turned out to be silence.
---@return nil
function M.announce_in_steps(opts, on_done)
  if announced then
    if on_done then
      on_done(false)
    end
    return
  end
  announced = true
  M.count_in_steps(opts, function(open, done, ids)
    local given = false
    if open ~= nil then
      given = give(open, done, ids)
    end
    if on_done then
      on_done(given)
    end
  end)
end

---Register the hint for this session: a moment after startup, so the scan is not part of it.
---@param delay_ms? integer  # Default 3000.
---@return nil
function M.schedule(delay_ms)
  if announced then
    return
  end
  vim.defer_fn(function()
    -- The UI is asked when the timer fires, not when it is set: a GUI that starts Neovim with `--embed` attaches after
    -- `init.lua` has run, and would never get the hint otherwise. Without one (headless) nothing is said.
    if #vim.api.nvim_list_uis() == 0 then
      return
    end
    -- Read again: a later `setup()` may have turned the hint off since this timer was set.
    if require("tasks_nvim.config").get().reminders.on_start then
      M.announce_in_steps()
    end
  end, delay_ms or 3000)
end

---Forget that the hint was given (specs).
---@return nil
function M.reset()
  announced = false
end

return M
