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
local planner = require("tasks_nvim.plan")
local plan_scope = require("tasks_nvim.plan_scope")
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

-- ── reorder ──────────────────────────────────────────────────────────────────

---Two `order` values closer than this are not told apart reliably after many halvings: the group is renumbered.
M.MIN_ORDER_GAP = 1e-6

---Most files one move may write (a move among tasks that have no `order` yet gives the ones before it a value).
M.MAX_REORDER_WRITES = 50

---@param t Tasks.Task
---@return boolean
local function has_order(t)
  local o = t.order
  return type(o) == "number" and o == o and o ~= math.huge and o ~= -math.huge
end

---@class Tasks.ReorderWrite
---@field id string
---@field order number
---@field was number|nil   # The value the task has now (nil: none): the write is refused when it changed meanwhile.

---Where a task goes in its group, as the `order` values that put it there. Pure.
---
---`order` is a tie-breaker behind status and priority: the tasks of a group are sorted by `order` (those without one
---last, in the plan's own order), so a spot is made by giving the moved task a value between its neighbours'. When the
---neighbours have none, the tasks before the spot get values first (the ones after it stay as they are, behind every
---number). When two values are closer than `MIN_ORDER_GAP`, the numbered tasks are renumbered 1, 2, 3, ...
---@param seq Tasks.Task[]   # The group WITHOUT the moved task, in plan order.
---@param moved Tasks.Task
---@param pos integer        # The moved task goes before `seq[pos + 1]`: 0 is the front, `#seq` the end.
---@return Tasks.ReorderWrite[] writes  # The neighbours first, the moved task last.
---@return boolean renumbered
function M.plan_reorder(seq, moved, pos)
  local numbered = 0
  for i, t in ipairs(seq) do
    if has_order(t) then
      numbered = i
    else
      break
    end
  end
  ---@type Tasks.ReorderWrite[]
  local writes = {}
  ---@param t Tasks.Task
  ---@param v number
  local function give(t, v)
    if t.order ~= v then
      writes[#writes + 1] = { id = t.id, order = v, was = t.order }
    end
  end
  local value, renumbered
  -- the last value of the numbered part: what the numbering of the unnumbered tasks continues from
  local top = numbered > 0 and seq[numbered].order or 0
  if pos == 0 then
    value = numbered > 0 and seq[1].order - 1 or 1
  elseif pos == numbered then
    -- behind the last numbered task, in front of the unnumbered ones
    value = seq[numbered].order + 1
  elseif pos > numbered then
    -- among the unnumbered: the ones before the spot get the next numbers, the moved task the one after them
    for i = numbered + 1, pos do
      give(seq[i], top + (i - numbered))
    end
    value = top + (pos - numbered) + 1
  else
    local lo, hi = seq[pos].order, seq[pos + 1].order
    if hi - lo >= M.MIN_ORDER_GAP then
      value = (lo + hi) / 2
    else
      renumbered = true
      for i = 1, numbered do
        give(seq[i], i <= pos and i or i + 1)
      end
      value = pos + 1
    end
  end
  writes[#writes + 1] = { id = moved.id, order = value, was = moved.order }
  return writes, renumbered == true
end

---`order` as it is written: a whole number plainly, a fraction with twelve significant digits (two values at least
---`MIN_ORDER_GAP` apart stay apart, and so does their midpoint).
---@param n number
---@return string
local function order_text(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return ("%d"):format(n)
  end
  return ("%.12g"):format(n)
end

---@class Tasks.ReorderSpec
---@field after? string       # The task the moved one goes right behind.
---@field before? string      # The task it goes right in front of.
---@field group? string       # The group the caller saw (`status|eff_prio`): a different one is a conflict.
---@field if_match? string    # The `etag` of the moved task the caller read.

---@class Tasks.ReorderResult
---@field id string
---@field changed boolean
---@field group string
---@field renumbered boolean
---@field writes { id: string, order: number, was: number|nil }[]   # Every file this move wrote (or would write), the moved task last.
---@field changed_ids string[]
---@field etag_before? string          # Of the moved task.
---@field etag_after? string
---@field inverse? Tasks.ReorderSpec   # Puts the moved task back where it was.
---@field areas string[]
---@field index_errors string[]

---Move a task inside its group: the same stage, the same status and effective priority. The spot is named by the
---neighbour it goes behind (`after`) or in front of (`before`); none of the two is the front, `before` alone with
---nothing behind is the front, `after` alone at the last task is the end. A neighbour from another group, a group the
---caller did not see, or neighbours that are no longer next to each other is a conflict (the list moved on).
---
---Every write goes through `mutate.set` with `expect` on `order`, so a task another writer ordered meanwhile is not
---overwritten. Not all-or-nothing: what was written stays (the numbers keep the relative order of the tasks they were
---given to, so a half-finished move does not scramble the list).
---@param id string
---@param spec Tasks.ReorderSpec
---@param opts { root: string, today?: string, index?: boolean, dry_run?: boolean, max_writes?: integer }
---@return Tasks.ReorderResult|nil result
---@return string|nil err
---@return table|nil info
function M.reorder(id, spec, opts)
  spec = spec or {}
  local shared, serr = plan_scope.shared(opts.root)
  if not shared then
    return nil, tostring(serr), { code = "io" }
  end
  local built = planner.build(shared.open, shared.index)
  local node = built.nodes[id]
  if not node then
    local known = shared.index.open[id]
    if known then
      return nil,
        id .. " is in a dependency cycle (or behind one) and has no place in the order",
        { code = "invalid_argument" }
    end
    return nil, "no such open task: " .. id, { code = "not_found" }
  end
  local moved = node.task
  local group = planner.group_key(node)
  if spec.group ~= nil and spec.group ~= group then
    return nil,
      ("%s is in the group %s now, not %s"):format(id, group, tostring(spec.group)),
      { code = "conflict", id = id, key = "group", expected = spec.group, actual = group }
  end
  if spec.if_match ~= nil and moved.etag ~= spec.if_match then
    return nil,
      ("%s changed since it was read (its version is %s, not %s)"):format(
        id,
        tostring(moved.etag),
        tostring(spec.if_match)
      ),
      { code = "conflict", id = id, expected = spec.if_match, actual = moved.etag }
  end
  if spec.after == id or spec.before == id then
    return nil, "a task cannot go next to itself", { code = "invalid_argument" }
  end

  -- the group: this stage, this status and effective priority, in plan order
  ---@type Tasks.Task[]
  local seq = {}
  local current = 0
  for _, other_id in ipairs(built.stages[node.stage + 1] or {}) do
    local other = built.nodes[other_id]
    if planner.group_key(other) == group then
      if other_id == id then
        current = #seq + 1
      else
        seq[#seq + 1] = other.task
      end
    end
  end
  ---@type table<string, integer>
  local at = {}
  for i, t in ipairs(seq) do
    at[t.id] = i
  end
  for _, name in ipairs({ "after", "before" }) do
    local neighbour = spec[name]
    if neighbour ~= nil and not at[neighbour] then
      local msg = shared.index.open[neighbour]
          and ("%s is not in the group of %s (%s, same stage)"):format(neighbour, id, group)
        or ("%s is no open task"):format(neighbour)
      return nil, msg, { code = "conflict", id = id, key = name, expected = neighbour }
    end
  end
  local pos
  if spec.after ~= nil and spec.before ~= nil then
    if at[spec.before] ~= at[spec.after] + 1 then
      return nil,
        ("%s and %s are no longer next to each other"):format(spec.after, spec.before),
        {
          code = "conflict",
          id = id,
          key = "neighbours",
          expected = spec.after .. " | " .. spec.before,
        }
    end
    pos = at[spec.after]
  elseif spec.after ~= nil then
    pos = at[spec.after]
  elseif spec.before ~= nil then
    pos = at[spec.before] - 1
  else
    pos = 0
  end

  ---@type Tasks.ReorderResult
  local result = {
    id = id,
    changed = false,
    group = group,
    renumbered = false,
    writes = {},
    changed_ids = {},
    etag_before = moved.etag,
    etag_after = moved.etag,
    areas = {},
    index_errors = {},
    inverse = {
      after = current > 1 and (seq[current - 1] and seq[current - 1].id) or nil,
      before = seq[current] and seq[current].id or nil,
    },
  }
  -- already there: the task stands right behind seq[pos] and in front of seq[pos + 1]
  if current > 0 and pos == current - 1 then
    return result, nil
  end

  local writes, renumbered = M.plan_reorder(seq, moved, pos)
  result.writes = writes
  result.renumbered = renumbered
  local cap = opts.max_writes or M.MAX_REORDER_WRITES
  if #writes > cap then
    return nil,
      ("this move would write %d files (at most %d): give the tasks around it an order or a priority first"):format(
        #writes,
        cap
      ),
      { code = "invalid_argument", writes = #writes }
  end
  result.changed = true
  if opts.dry_run then
    return result, nil
  end

  local touched = {}
  for i, w in ipairs(writes) do
    local is_moved = i == #writes
    local r, err, info = mutate.set(w.id, { order = order_text(w.order) }, {
      root = opts.root,
      today = opts.today,
      index = false,
      expect = { key = "order", value = w.was },
      if_match = is_moved and spec.if_match or nil,
    })
    if not r then
      -- what was written stays; say how far it got
      info = info or { code = "io" }
      info.written = vim.deepcopy(result.changed_ids)
      return nil, tostring(err), info
    end
    touched[#touched + 1] = w.id
    result.changed_ids[#result.changed_ids + 1] = w.id
    if is_moved then
      result.etag_before = r.etag_before
      result.etag_after = r.etag_after
    end
  end
  result.areas = areas_of(touched)
  if opts.index ~= false then
    result.index_errors = reindex(result.areas, opts.root)
  end
  return result, nil
end

---@class Tasks.BatchSetResult
---@field changed { id: string, path: string }[]
---@field unchanged string[]
---@field failed { id: string, err: string, code?: string }[]  # `code`: `conflict` (the task changed since it was read), `locked`, ...
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
    -- `expect` is checked by `mutate.set` UNDER the lock, against the text read there: advancing an OLD value would
    -- overwrite a newer change with the wrong successor, and a check before the lock leaves a gap.
    local r, err, info = mutate.set(step.id, step.patch, {
      root = opts.root,
      index = false,
      today = opts.today,
      expect = step.expect,
    })
    if not r then
      res.failed[#res.failed + 1] = { id = step.id, err = tostring(err), code = info and info.code }
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
