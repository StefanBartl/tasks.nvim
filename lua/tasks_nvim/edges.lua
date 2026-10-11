---@module 'tasks_nvim.edges'
---@brief What a change of a task's relations would break, asked BEFORE the file is written.
---@description
--- `check` finds a bad `blocked_by`, `after`, `plan` or `phase` after the fact, in files. A front end that writes on
--- behalf of somebody else (an app, an agent) needs the same answer first, so it can refuse the change with a reason
--- instead of writing a file that `check` then reports. The rules are `check`'s, with the same codes:
---
---  - `blocked-by-self` / `after-self`: the task names itself
---  - `blocked-by-dangling` / `after-dangling`: the target exists nowhere (an open task or a finished one counts; a
---    finished blocker is allowed, it only blocks nobody)
---  - `blocked-by-cycle`: the hard edges (with the stage gates of the plan files) would form a circle through the task
---    (a soft `after` edge that closes a circle is not an error: the plan drops it with a warning)
---  - `plan-unknown`: the plan names no plan file (a finished plan is fine)
---  - `plan-phase`: the plan lists stages (`phase_order`) and the phase is not one of them; `check` warns, a change
---    that has not happened yet is refused
---
--- Pure over one pass of the vault (`plan_scope.shared`); nothing is written. Not its job: the format of the values
--- (`mutate` checks them), the write.

local plan = require("tasks_nvim.plan")
local plan_scope = require("tasks_nvim.plan_scope")

local M = {}

---What a change proposes. A key that is absent is left as it is; an empty list or `false` removes the relation.
---@class Tasks.EdgeProposal
---@field blocked_by? string[]
---@field after? string[]
---@field plan? string|false
---@field phase? string|false

---@class Tasks.EdgeProblem
---@field code string        # The `check` code of the same fault.
---@field key string         # `blocked_by`, `after`, `plan` or `phase`.
---@field target? string     # The id, plan or phase that is wrong.
---@field message string
---@field members? string[]  # For a cycle: the tasks on it, the task first.

---@param list string[]
---@param value string
---@return boolean
local function has(list, value)
  return vim.tbl_contains(list, value)
end

---Check a proposed change of the relations of task `id`.
---@param id string
---@param proposal Tasks.EdgeProposal
---@param opts { root: string, shared?: Tasks.PlanShared }
---@return Tasks.EdgeProblem[]|nil problems  # empty: the change breaks nothing
---@return string|nil err
function M.validate(id, proposal, opts)
  local shared = opts.shared
  if not shared then
    local err
    shared, err = plan_scope.shared(opts.root)
    if not shared then
      return nil, tostring(err)
    end
  end
  local index = shared.index
  local task = index.open[id]
  if not task then
    return nil, "no such open task: " .. id
  end
  ---@type Tasks.EdgeProblem[]
  local problems = {}

  ---@param key "blocked_by"|"after"
  ---@param self_code string
  ---@param dangling_code string
  local function targets(key, self_code, dangling_code)
    for _, ref in ipairs(proposal[key] or {}) do
      if ref == id then
        problems[#problems + 1] = {
          code = self_code,
          key = key,
          target = ref,
          message = key .. " names the task itself",
        }
      elseif not index.open[ref] and not index.is_done(ref) then
        problems[#problems + 1] = {
          code = dangling_code,
          key = key,
          target = ref,
          message = key .. " " .. ref .. " does not exist",
        }
      end
    end
  end
  targets("blocked_by", "blocked-by-self", "blocked-by-dangling")
  targets("after", "after-self", "after-dangling")

  -- plan and phase, as the task would have them afterwards
  local plan_id, phase = task.plan, task.phase
  if proposal.plan ~= nil then
    plan_id = proposal.plan or nil
  end
  if proposal.phase ~= nil then
    phase = proposal.phase or nil
  end
  local file
  if plan_id then
    for _, f in ipairs(shared.files) do
      if f.id == plan_id then
        file = f
        break
      end
    end
    if not file and not index.is_done(plan_id) then
      if proposal.plan ~= nil then
        problems[#problems + 1] = {
          code = "plan-unknown",
          key = "plan",
          target = plan_id,
          message = "plan " .. plan_id .. " is no plan file (ROADMAP/plans/<slug>.md)",
        }
      end
    end
  end
  if
    file
    and phase
    and #file.phase_order > 0
    and not has(file.phase_order, phase)
    and (proposal.plan ~= nil or proposal.phase ~= nil)
  then
    problems[#problems + 1] = {
      code = "plan-phase",
      key = "phase",
      target = phase,
      message = ("phase '%s' is not in the phase_order of %s (%s)"):format(
        phase,
        plan_id,
        table.concat(file.phase_order, ", ")
      ),
    }
  end

  -- a circle through the task: judged on the whole graph with the change applied
  local changes_graph = proposal.blocked_by ~= nil or proposal.plan ~= nil or proposal.phase ~= nil
  if changes_graph and #problems == 0 then
    local changed = vim.tbl_extend("force", {}, task)
    changed.blocked_by = proposal.blocked_by or task.blocked_by
    changed.plan = plan_id
    changed.phase = phase
    local open = {}
    for _, t in ipairs(shared.open) do
      open[#open + 1] = t.id == id and changed or t
    end
    local after_index = plan.index(open, index.is_done, shared.files)
    local built = plan.build(open, after_index)
    for _, members in ipairs(built.cycles) do
      if #members > 1 and has(members, id) then
        -- name the circle starting at the task
        local from = 1
        for i, m in ipairs(members) do
          if m == id then
            from = i
          end
        end
        local ordered = {}
        for i = 0, #members - 1 do
          ordered[#ordered + 1] = members[(from - 1 + i) % #members + 1]
        end
        problems[#problems + 1] = {
          code = "blocked-by-cycle",
          key = proposal.blocked_by ~= nil and "blocked_by"
            or (proposal.plan ~= nil and "plan" or "phase"),
          message = "this would form a cycle: " .. table.concat(ordered, " -> "),
          members = ordered,
        }
        break
      end
    end
  end
  return problems, nil
end

return M
