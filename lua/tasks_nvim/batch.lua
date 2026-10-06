---@module 'tasks_nvim.batch'
---@brief Several tasks changed or finished in one go, the index regenerated once per area.
---@description
--- The engine side of what the dashboard does with marked tasks (and what any front end or script may do):
---
---  - `set_many`: one `mutate.set` per step without its own index write; a step that carries `expect` is
---    refused when the task no longer has that value (it was changed since the list was drawn, ERR-30);
---  - `done_many`: `done_flow.run` one after the other (rule R6);
---  - after the last task ONE index regeneration per area that changed.
---
--- A failing task never stops the others. No notifications and no windows: the result says what happened and the
--- caller decides how to tell the user.

local done_flow = require("tasks_nvim.done_flow")
local index = require("tasks_nvim.index")
local mutate = require("tasks_nvim.mutate")
local next_pick = require("tasks_nvim.next_pick")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@param ids string[]
---@return string[] areas  sorted, distinct
local function areas_of(ids)
  local seen, out = {}, {}
  for _, id in ipairs(ids) do
    local area = vault.parse_id(id)
    if area and not seen[area] then
      seen[area] = true
      out[#out + 1] = area
    end
  end
  table.sort(out)
  return out
end

---Regenerate the index of each area once.
---@param areas string[]
---@param root string
---@return string[] errors
local function reindex(areas, root)
  local errors = {}
  for _, area in ipairs(areas) do
    local res, err = index.write_area(area, { root = root })
    if not res then
      errors[#errors + 1] = ("%s: %s"):format(area, tostring(err))
    end
  end
  return errors
end

---@class Tasks.BatchSetStep
---@field id string
---@field patch table<string, any>                          # As for `mutate.set`.
---@field expect? { key: string, value: any }               # The task must still have this value, else the step fails.

---A step planned by `plan_cycle`: the batch step plus what it does, for a summary.
---@class Tasks.CycleStep : Tasks.BatchSetStep
---@field field "status"|"prio"
---@field from string|integer|nil
---@field to string|integer|nil   # nil: the key is removed.

---Plan advancing `field` of every task: each one from ITS OWN current value, so a mixed selection stays mixed.
---Pure; nothing is written. The steps carry `expect`, so applying them refuses a task that no longer has the value
---it was planned from.
---@param tasks Tasks.Task[]
---@param field "status"|"prio"
---@param count? integer  presses to advance (`3p` is three); default 1
---@return Tasks.CycleStep[]
function M.plan_cycle(tasks, field, count)
  local model = require("tasks_nvim.model")
  local plan = {}
  local presses = math.max(1, math.floor(count or 1))
  -- The first press brings any value (a status nobody knows, a prio of 9) into the cycle; from then on it is periodic,
  -- so `999999999p` costs one cycle, not a billion steps (a vim count is typed, and not interruptible here).
  ---@generic T
  ---@param cur T
  ---@param step fun(cur: T): T
  ---@param period integer
  ---@return T
  local function advance(cur, step, period)
    cur = step(cur)
    for _ = 1, (presses - 1) % period do
      cur = step(cur)
    end
    return cur
  end
  for _, t in ipairs(tasks) do
    ---@type string|integer|nil
    local from, to
    if field == "status" then
      from, to = t.status, advance(t.status, model.cycle_status, #model.OPEN_STATUSES)
    else
      from, to = t.prio, advance(t.prio, model.cycle_prio, #model.PRIOS + 1)
    end
    plan[#plan + 1] = {
      id = t.id,
      field = field,
      from = from,
      to = to,
      expect = { key = field, value = from },
      patch = { [field] = to == nil and mutate.REMOVE or to },
    }
  end
  return plan
end

---A proposed `actor` for a task that has none.
---@class Tasks.ActorProposal
---@field id string
---@field actor string
---@field reason string

---Which tasks without an `actor` can get one without guessing: those `model.actor` derives (`status: decision`,
---the tag `needs-user`) become `me`; everything else is left EMPTY on purpose, because the share of tasks nobody can
---classify is the honest number. Pure; nothing is written.
---@param tasks Tasks.Task[]
---@return Tasks.ActorProposal[] proposals
---@return integer left_empty   # Open tasks without an actor that stay unclassified.
function M.plan_actor_migration(tasks)
  local model = require("tasks_nvim.model")
  local proposals, left = {}, 0
  for _, t in ipairs(tasks) do
    if t.actor == nil then
      local derived = model.actor(t)
      if derived then
        proposals[#proposals + 1] = {
          id = t.id,
          actor = derived,
          reason = t.status == "decision" and "status: decision" or "tag needs-user",
        }
      else
        left = left + 1
      end
    end
  end
  return proposals, left
end

---The batch steps that write a migration plan (`expect` guards against a task that got an actor meanwhile).
---@param proposals Tasks.ActorProposal[]
---@return Tasks.BatchSetStep[]
function M.actor_steps(proposals)
  local steps = {}
  for _, p in ipairs(proposals) do
    steps[#steps + 1] =
      { id = p.id, patch = { actor = p.actor }, expect = { key = "actor", value = nil } }
  end
  return steps
end

---@class Tasks.BatchSetResult
---@field changed { id: string, path: string }[]
---@field unchanged string[]
---@field failed { id: string, err: string }[]
---@field areas string[]            # Areas whose index was regenerated (those with a change).
---@field index_errors string[]

---Run a list of `set` steps. The index of every touched area is regenerated once at the end (`opts.index = false`:
---not at all).
---@param steps Tasks.BatchSetStep[]
---@param opts { root: string, today?: string, index?: boolean }
---@return Tasks.BatchSetResult
function M.set_many(steps, opts)
  ---@type Tasks.BatchSetResult
  local res = { changed = {}, unchanged = {}, failed = {}, areas = {}, index_errors = {} }
  local changed_ids = {}
  for _, step in ipairs(steps) do
    local r, err
    local refused
    if step.expect then
      -- Read again right before the write: advancing an OLD value would overwrite a newer change with the
      -- wrong successor. A difference is a failure, not a write.
      local current = scan.find(step.id, { root = opts.root })
      if current and tostring(current[step.expect.key]) ~= tostring(step.expect.value) then
        refused = ("%s changed since the list was read (%s is now %s, not %s); press r to rescan"):format(
          step.id,
          step.expect.key,
          tostring(current[step.expect.key]),
          tostring(step.expect.value)
        )
      end
    end
    if refused then
      err = refused
    else
      r, err =
        mutate.set(step.id, step.patch, { root = opts.root, index = false, today = opts.today })
    end
    if not r then
      res.failed[#res.failed + 1] = { id = step.id, err = tostring(err) }
    elseif r.changed then
      res.changed[#res.changed + 1] = { id = r.id, path = r.path }
      changed_ids[#changed_ids + 1] = r.id
    else
      res.unchanged[#res.unchanged + 1] = r.id
    end
  end
  res.areas = areas_of(changed_ids)
  if opts.index ~= false then
    res.index_errors = reindex(res.areas, opts.root)
  end
  return res
end

---@class Tasks.BatchDoneResult
---@field done { id: string, from: string, to: string, readme?: string }[]
---@field already string[]
---@field failed { id: string, err: string }[]
---@field areas string[]
---@field index_errors string[]
---@field next? Tasks.NextPick          # What to start next, worked out ONCE after the last finished task.
---@field freed string[]                # Tasks that the last finished task freed.
---@field steps_ticked integer           # Plan steps ticked in the finished copies.
---@field plans_closed string[]          # Plan files finished because their last member was among these.
---@field plan_summaries table<string, Tasks.PlanSummary>
---@field docs_refreshed string[]        # Documents whose generated blocks changed.
---@field notes string[]                 # Follow-up steps that did not work (the finishes stand).

---Finish tasks (rule R6) one after the other, the index regenerated once per area at the end.
---@param ids string[]
---@param opts { root: string, today?: string, date?: string, pick_next?: boolean }
---@return Tasks.BatchDoneResult
function M.done_many(ids, opts)
  ---@type Tasks.BatchDoneResult
  local res = {
    done = {},
    already = {},
    failed = {},
    areas = {},
    index_errors = {},
    freed = {},
    steps_ticked = 0,
    plans_closed = {},
    plan_summaries = {},
    docs_refreshed = {},
    notes = {},
  }
  local moved, plan_ids = {}, {}
  for _, id in ipairs(ids) do
    local flow, err = done_flow.run(id, {
      root = opts.root,
      index = false,
      today = opts.today,
      date = opts.date,
      pick_next = false,
      refresh_docs = false,
      defer_plan_close = true,
    })
    local r = flow and flow.done
    if not flow or not r then
      res.failed[#res.failed + 1] = { id = id, err = tostring(err) }
    elseif r.already then
      res.already[#res.already + 1] = id
    else
      res.done[#res.done + 1] = { id = id, from = r.from, to = r.to, readme = r.readme }
      moved[#moved + 1] = id
      if r.plan_id then
        plan_ids[#plan_ids + 1] = r.plan_id
      end
      res.steps_ticked = res.steps_ticked + flow.steps_ticked
      vim.list_extend(res.plans_closed, flow.plans_closed)
      for plan_id, summary in pairs(flow.plan_summaries) do
        res.plan_summaries[plan_id] = summary
      end
      vim.list_extend(res.notes, flow.notes)
    end
  end
  if #plan_ids > 0 then
    -- The plans of the finished tasks: ONE scan for the whole stack (not one per task), after the last finish.
    local ran, closed = pcall(done_flow.close_plans, plan_ids, opts)
    if ran then
      vim.list_extend(res.plans_closed, closed.closed)
      vim.list_extend(res.notes, closed.notes)
      for plan_id, summary in pairs(closed.summaries) do
        res.plan_summaries[plan_id] = summary
      end
    else
      res.notes[#res.notes + 1] = "closing the plans: " .. tostring(closed)
    end
  end
  res.areas = areas_of(moved)
  res.index_errors = reindex(res.areas, opts.root)
  if #res.done > 0 then
    -- The generated blocks of the configured documents: once for the whole stack, after everything is finished.
    local refreshed, notes =
      done_flow.refresh_marker_docs({ root = opts.root, closed = res.plan_summaries })
    res.docs_refreshed = refreshed
    vim.list_extend(res.notes, notes)
  end
  -- One answer for the whole batch, from the last finished task and after the indexes are written: a stack of
  -- finished tasks gets one "what next", not one per task.
  local last = res.done[#res.done]
  if last and opts.pick_next ~= false then
    local area = last.id:match("^([^/]+)/")
    local ran, pick =
      pcall(next_pick.pick_from_vault, { root = opts.root, done = { id = last.id, area = area } })
    if ran and pick then
      res.next = pick
      res.freed = pick.freed
    end
  end
  return res
end

return M
