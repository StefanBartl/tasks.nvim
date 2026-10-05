---@module 'tasks_nvim.plan_scope'
---@brief Reads the vault and hands `plan` what it needs: the open tasks, which ids are finished, the scope asked for.
---@description
--- The impure edge of the plan: `plan`, `estimate` and `next_pick` take data, this module fetches it. One scan of the
--- open tasks, finished ids looked up in the Backlogs only when a blocker is not open (and remembered), the scope
--- cut the way `task plan` is called: an area, `--for=<id>` (the task and everything before it, across areas), or the
--- whole vault, narrowed by a `Tasks.Filter` like `list`.
---
--- Not its job: the calculation (`plan`), rendering (`plan_view`), the command line (`cli`, `ui.cmd`).

local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")
local scan = require("tasks_nvim.scan")

local M = {}

---@class Tasks.PlanScopeOpts
---@field root? string
---@field area? string
---@field for_id? string
---@field filter? Tasks.Filter

---@class Tasks.PlanScope
---@field plan Tasks.Plan
---@field tasks Tasks.Task[]          # The scope.
---@field index Tasks.PlanIndex
---@field done? Tasks.Task[]          # Finished tasks of the area (only for an area scope): the progress figure.
---@field errors string[]             # Folders that could not be read: the plan may be incomplete.
---@field title string

---Every open task of the vault and a finished-id lookup: what `plan.ready` and `plan.classify` need, whatever the
---area of the list being filtered (a blocker may live anywhere).
---@param root? string
---@return Tasks.PlanIndex|nil index
---@return Tasks.Task[]|string open_or_err
---@return string[]|nil errors
function M.index(root)
  local open, skipped, errors = scan.open_tasks({ root = root })
  if not open then
    return nil, tostring(skipped), nil
  end
  local known = {}
  local index = plan.index(open, function(id)
    local hit = known[id]
    if hit == nil then
      hit = scan.find_done(id, { root = root }) ~= nil
      known[id] = hit
    end
    return hit
  end)
  return index, open, errors
end

---@param opts Tasks.PlanScopeOpts
---@return Tasks.PlanScope|nil scope
---@return string|nil err
function M.load(opts)
  local index, open, errors = M.index(opts.root)
  if not index then
    return nil, tostring(open)
  end
  ---@cast open Tasks.Task[]
  local tasks, title
  if opts.for_id then
    tasks = plan.scope_for(index, opts.for_id)
    if not tasks then
      return nil, "no such open task: " .. opts.for_id
    end
    title = "for " .. opts.for_id
  elseif opts.area then
    tasks = {}
    for _, t in ipairs(open) do
      if t.area == opts.area then
        tasks[#tasks + 1] = t
      end
    end
    title = opts.area
  else
    tasks = open
    title = "all areas"
  end
  if opts.filter and next(opts.filter) ~= nil then
    tasks = model.filter(tasks, opts.filter)
  end

  ---@type Tasks.PlanScope
  local scope = {
    plan = plan.build(tasks, index),
    tasks = tasks,
    index = index,
    errors = errors or {},
    title = title,
  }
  if opts.area and not opts.for_id then
    local finished = scan.backlog(opts.area, { root = opts.root })
    scope.done = finished or {}
  end
  return scope, nil
end

return M
