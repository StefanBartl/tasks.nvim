---@module 'tasks_nvim.ui.next_popup'
---@brief The small dialog after finishing a task: what comes next, and whether to jump into it.
---@description
--- The answer (`next_pick`) and its wording (`plan_view.next_message`) live in the engine; this module only shows
--- them. With a startable task: "Done: ... / Next: ... / Why: ..." and the choices `Not now` (the harmless first one,
--- so a stray <CR> opens nothing), `Open <id>` and, when there are runners-up, `Show another`. Without one -- or when
--- `setup({ next = { popup = false } })`, or nobody is looking (a headless session) -- the same text is a plain
--- message, so the honest "nothing can be started, 4 wait for you" is never swallowed.
---
--- A stack of finished tasks (`D` in the dashboard with several marked) shows ONE dialog, built from the answer of the
--- last one: the caller passes that answer, not one per task.
---
--- Seam for specs: `M.chooser(msg, choices, cb)` replaces the dialog.
---
--- Not its job: picking the task (`next_pick`), finishing it (`done_flow`).

local confirm = require("tasks_nvim.ui.confirm")
local notify = require("lib.nvim.notify").create("[tasks]")
local plan_view = require("tasks_nvim.plan_view")

local M = {}

---Replaces the dialog (specs): `function(msg, choices, cb)`.
---@type (fun(msg: string, choices: string[], cb: fun(index: integer|nil)))|nil
M.chooser = nil

---Whether somebody can answer a dialog.
---@return boolean
local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

---Open the task and count the visit, like the dashboard does.
---@param task Tasks.Task
local function jump(task)
  pcall(function()
    require("tasks_nvim.frecency").record({ task.id })
  end)
  require("tasks_nvim.ui.cmd").open_file(task.path)
end

---Show the answer. Returns whether a dialog was opened (otherwise a message was shown).
---@param pick Tasks.NextPick
---@param done_id? string   # The finished task (a heading line); nil for a plain "what next?".
---@return boolean dialog
function M.show(pick, done_id)
  local cfg = require("tasks_nvim.config").get().next
  local lines = plan_view.next_message(pick, done_id)
  if not cfg.cdx_hint then
    local kept = {}
    for _, l in ipairs(lines) do
      if not l:find("^An AI session could take") then
        kept[#kept + 1] = l
      end
    end
    lines = kept
  end
  local text = table.concat(lines, "\n")
  local task = pick.task
  if not task or not cfg.popup or (not has_ui() and not M.chooser) then
    notify.info(text)
    return false
  end

  local choices = { "Not now", "Open " .. confirm.shorten(task.id, 44) }
  if #pick.alternatives > 0 then
    choices[#choices + 1] = "Show another"
  end
  local ask = M.chooser or confirm.choose
  ask(text, choices, function(index)
    if index == 2 then
      jump(task)
    elseif index == 3 then
      M.show({
        task = pick.alternatives[1],
        reason = nil,
        alternatives = vim.list_slice(pick.alternatives, 2),
        cdx = {},
        freed = {},
        freed_blocked = {},
        ready = pick.ready,
        open = pick.open,
      }, nil)
    end
  end)
  return true
end

return M
