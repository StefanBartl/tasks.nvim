---@module 'tasks_nvim.ui.steps_watch'
---@brief Opt-in: ticking the LAST open step of a task's `## Plan` asks whether to finish the task.
---@description
--- Off by default (`setup({ steps = { ask_finish = true } })` turns it on): it is the one autocommand the plugin has,
--- and it only ever looks at buffers that are task files of the vault (`<vault>/<area>/ROADMAP/tasks/...`).
---
--- It keeps, per buffer, whether the plan was complete the last time it looked. Ticking the last open step turns
--- "not complete" into "complete" once: that is the moment it asks (a question, never an action on its own). Un-ticking
--- a step and ticking it again asks again; a task whose steps were all ticked when the buffer was opened does not ask
--- until something changes. On yes the buffer is written first (the finish moves the file) and then goes the way
--- `:Tasks done` goes (messages, next-task dialog).
---
--- Not its job: reading the steps (`steps`), finishing (`done_flow`).

local confirm = require("tasks_nvim.ui.confirm")
local steps = require("tasks_nvim.steps")
local vault = require("tasks_nvim.vault")

local M = {}

---Whether the plan of a buffer was complete the last time it was looked at.
---@type table<integer, boolean>
local complete = {}

---The id of the task a buffer holds, when it is a task file of the vault.
---@param buf integer
---@return string|nil id
function M.task_id(buf)
  local root = vault.root()
  if not root then
    return nil
  end
  local fsio = require("tasks_nvim.fsio")
  local name = fsio.norm(vim.api.nvim_buf_get_name(buf))
  -- The vault prefix is compared the way every path is (case-insensitively on Windows: `c:/` is `C:/`); the id is
  -- sliced from the name as it is, so it keeps the casing on disk.
  local n = #root
  if #name <= n or name:sub(n + 1, n + 1) ~= "/" or not fsio.same_path(name:sub(1, n), root) then
    return nil
  end
  local area, rest = name:sub(n + 2):match("^([^/]+)/ROADMAP/tasks/(.+)%.md$")
  if not area or not rest then
    return nil
  end
  local slug = rest:match("^([^/]+)/%1$") or rest
  if slug:find("/", 1, true) then
    return nil
  end
  return area .. "/" .. slug
end

---Look at a buffer: when its plan has just become complete, ask. Returns whether the question was asked.
---@param buf integer
---@return boolean asked
function M.check_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local id = M.task_id(buf)
  if not id then
    return false
  end
  local summary = steps.parse(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  local now = summary ~= nil and summary.total > 0 and summary.ticked == summary.total
  local before = complete[buf]
  complete[buf] = now
  if not now or before ~= false then
    -- not complete, or first look (the file was already complete when it was opened): nothing to ask
    return false
  end
  confirm.yesno(
    ("All steps of %s are ticked.\n\nFinish the task?"):format(confirm.shorten(id, 60)),
    "finish",
    function(yes)
      if not yes or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.bo[buf].modified then
        local wrote = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent write")
        end)
        if not wrote then
          require("lib.nvim.notify")
            .create("[tasks]")
            .error("could not save the task; it was not finished")
          return
        end
      end
      require("tasks_nvim.ui.cmd").finish(id, {})
    end
  )
  return true
end

---Remember how a buffer stands when it is first seen, without asking.
---@param buf integer
function M.prime(buf)
  local id = M.task_id(buf)
  if not id then
    return
  end
  local summary = steps.parse(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  complete[buf] = summary ~= nil and summary.total > 0 and summary.ticked == summary.total
end

---Register the autocommands (idempotent).
function M.enable()
  local autocmd = require("lib.nvim.bindings.autocmd")
  local group = autocmd.group("TasksStepsWatch", true)
  autocmd.create({ "BufReadPost", "BufEnter" }, function(args)
    if complete[args.buf] == nil then
      M.prime(args.buf)
    end
  end, {
    group = group,
    pattern = "*/ROADMAP/tasks/*.md",
    desc = "tasks.nvim: note whether the plan steps are complete",
  })
  autocmd.create("TextChanged", function(args)
    M.check_buffer(args.buf)
  end, {
    group = group,
    pattern = "*/ROADMAP/tasks/*.md",
    desc = "tasks.nvim: ticking the last plan step asks to finish the task",
  })
  autocmd.create({ "BufWipeout", "BufDelete" }, function(args)
    complete[args.buf] = nil
  end, {
    group = group,
    pattern = "*/ROADMAP/tasks/*.md",
    desc = "tasks.nvim: forget a closed task buffer",
    record = false,
  })
  -- Task buffers that are already open (`setup` ran lazily, on the first `:Tasks`): note how they stand now, else
  -- the first tick of their last step would pass for a first look and never ask.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and complete[buf] == nil then
      M.prime(buf)
    end
  end
end

---Remove the autocommands and the memory (specs, `setup` with the option off).
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, "TasksStepsWatch")
  complete = {}
end

return M
