---@module 'tasks_nvim.ui.reminder_hint'
---@brief One line at the start of Neovim: how many reminders (`remind:`) are due.
---@description
--- Opt-out (`setup({ reminders = { on_start = false } })`). Runs a moment after startup, once per session, only
--- with a UI, and says nothing when nothing is due or no vault is there. The cost is one scan of the open
--- tasks (cached by mtime) and the light scan of the finished ones.
---
--- Not its job: setting or listing reminders (`tasks_nvim.mutate`, `:Tasks list --reminders`).

local M = {}

---Whether the hint was given in this session (a second `setup()` does not repeat it).
local announced = false

---A line each for the tasks, open or finished, whose reminder date is today or earlier.
---@param opts? Tasks.ScanOpts
---@return integer open  # Open tasks with a reminder that is due.
---@return integer done  # Finished tasks with a reminder that is due.
function M.count(opts)
  local scan = require("tasks_nvim.scan")
  local model = require("tasks_nvim.model")
  local today = (opts and opts.today) or model.today()
  local function due(tasks)
    local n = 0
    for _, t in ipairs(tasks or {}) do
      if model.is_date(t.remind) and t.remind <= today then
        n = n + 1
      end
    end
    return n
  end
  local open = scan.open_tasks(opts)
  local finished = scan.backlog_reminders(opts)
  return due(open), due(finished)
end

---The text of the hint; `nil` when nothing is due.
---@param open integer
---@param done integer
---@return string|nil
function M.message(open, done)
  local total = open + done
  if total == 0 then
    return nil
  end
  local extra = done > 0 and (" (%d of them finished)"):format(done) or ""
  return ("%d reminder%s due%s: `:Tasks list --reminders`"):format(
    total,
    total == 1 and "" or "s",
    extra
  )
end

---Give the hint once. A vault that is not there, or a scan that fails, is silence, not an error.
---@param opts? Tasks.ScanOpts
---@return boolean given
function M.announce(opts)
  if announced then
    return false
  end
  announced = true
  local ok, open, done = pcall(M.count, opts)
  if not ok then
    return false
  end
  local text = M.message(open, done)
  if not text then
    return false
  end
  require("lib.nvim.notify").create("[tasks]").info(text)
  return true
end

---Register the hint for this session: a moment after startup, so the scan is not part of it.
---@param delay_ms? integer  # Default 3000.
---@return nil
function M.schedule(delay_ms)
  if announced or #vim.api.nvim_list_uis() == 0 then
    return
  end
  vim.defer_fn(function()
    M.announce()
  end, delay_ms or 3000)
end

---Forget that the hint was given (specs).
---@return nil
function M.reset()
  announced = false
end

return M
