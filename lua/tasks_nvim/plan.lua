---@module 'tasks_nvim.plan'
---@brief The plan of a set of open tasks, computed from `blocked_by` alone: stages, who is ready, leverage, critical path.
---@description
--- Pure and UI-free: tasks in, a table out. Nothing here reads a file; `plan.index` is handed what the vault knows
--- (every open task by id, which ids are finished), so a spec needs no vault and the editor, the CLI, `check` and the
--- dashboard all ask the same questions of the same answers.
---
--- Key responsibilities:
---  - `ready` / `classify`: THE definition of "can be started" (see below), used by `list --ready`, the dashboard,
---    `next` and the plan. There is no second reading anywhere else.
---  - `scope_for`: a task plus everything that has to be finished before it (transitively, across areas)
---  - `build`: stages (earliest possible, Kahn layering), the order inside a stage, leverage, effective priority,
---    the critical path (weighted with `effort_days`), cycles over hard edges
---
--- "Ready" means: the status is `open`, `doing` or `decision` and no blocker is open. A finished blocker counts as
--- met. A blocker nobody knows (neither open nor finished) counts as open and is reported (`unknown-blocker`). A task
--- whose blocker is `parked`, or sits in a cycle, is `stuck`: it waits without end. `decision` is ready too -- it is
--- the thing that waits for the human, not for another task.
---
--- Hard edges (`blocked_by`) decide readiness, leverage and the critical path. A cycle over them is reported
--- (members named) and taken out of the calculation; every other task is still ordered, a cycle never swallows the
--- whole plan. Soft edges (`after`, "should come after") only move a task to a later stage: never an error, and one
--- that would close a cycle is dropped with a warning. `order` is a tie-breaker inside a stage, nothing more.
---
--- Tasks of one stage that name the same file in `refs` are marked `same-file`: they are not parallel work, the order
--- says which to do first (a note, not a rule).
---
--- Not its job: reading files (`scan`), rendering (`plan_view`), the estimate sums (`estimate`), what to start next
--- (`next_pick`).

local model = require("tasks_nvim.model")
local staleness = require("tasks_nvim.staleness")

local M = {}

---@class Tasks.PlanIndex
---@field open table<string, Tasks.Task>   # Every open task of the vault by id, whatever the scope.
---@field is_done fun(id: string): boolean # Whether a task id is finished (in a Backlog).
---@field gate_blockers table<string, string[]>  # Plan files with `gate: hard`: the tasks of the stage before, as blockers.
---@field phase_edges table<string, string[]>    # Plan files without a gate: the stage before, as soft edges.

---What a task is waiting for, one word.
---@alias Tasks.PlanState
---| "ready"        # open / doing, nothing blocks it
---| "decision"     # status decision, nothing blocks it: waits for the human
---| "waiting"      # an open blocker
---| "stuck"        # a parked blocker, an unknown blocker or a cycle: waits without end
---| "freed"        # status blocked, but nothing blocks it any more
---| "parked"       # parked by its own status
---| "unknown"      # a status the engine does not know

---@class Tasks.PlanNode
---@field task Tasks.Task
---@field state Tasks.PlanState
---@field open_blockers string[]      # Open blockers (in or outside the scope), in `blocked_by` order.
---@field external string[]           # The open blockers that are outside the scope.
---@field unknown_blockers string[]   # Blockers that are neither open nor finished.
---@field stage? integer              # Nil for a task in a cycle.
---@field leverage integer            # Tasks in the scope that transitively depend on it.
---@field eff_prio? integer           # Own prio or the best prio of the tasks that depend on it.
---@field inversion? { from: integer|nil, to: integer, because: string }
---@field in_cycle boolean
---@field same_file string[]          # Tasks of the same stage that name the same file in `refs`.
---@field behind_cycle boolean        # Waits (transitively) on a cycle: in no stage, like the cycle itself.

---@class Tasks.PlanCritical
---@field days number                 # Sum along the longest path (unknown effort counts as 1 day).
---@field path string[]
---@field unknown integer             # Tasks on the path without a (valid) effort.

---@class Tasks.Plan
---@field nodes table<string, Tasks.PlanNode>
---@field ids string[]                # Every task of the scope in plan order (stage, then the tie-breakers).
---@field stages string[][]           # Ids per stage, each in plan order; tasks in a cycle are not in any stage.
---@field ready string[]              # Ready tasks (state `ready` or `decision`), best first.
---@field decisions string[]          # Ready decisions by leverage, highest first.
---@field cycles string[][]           # Members of every cycle over hard edges.
---@field conflicts { stage: integer, file: string, ids: string[] }[]  # Same-stage tasks that touch the same file.
---@field critical Tasks.PlanCritical
---@field warnings { code: string, id?: string, msg: string }[]

---The status order inside a stage and a list: doing first, parked last.
---@type table<string, integer>
local STATUS_ORDER = { doing = 1, decision = 2, open = 3, blocked = 4, parked = 5 }

local NO_PRIO = 99

---@param all_open Tasks.Task[]
---@param is_done? (fun(id: string): boolean)|table<string, boolean>  # A predicate or a set of finished ids.
---@param plans? Tasks.PlanFile[]  # The open plan files: their `phase_order` gives the stages an order.
---@return Tasks.PlanIndex
function M.index(all_open, is_done, plans)
  local open = {}
  for _, t in ipairs(all_open) do
    open[t.id] = t
  end
  local done = function()
    return false
  end
  if type(is_done) == "function" then
    done = is_done
  elseif type(is_done) == "table" then
    done = function(id)
      return is_done[id] == true
    end
  end
  local index = { open = open, is_done = done, gate_blockers = {}, phase_edges = {} }

  -- A plan file with a `phase_order` puts its tasks in an order: a task of a stage follows the tasks of the nearest
  -- earlier stage that has any. With `gate: hard` that is a real blocker (readiness, leverage, the critical path all
  -- see it); without, it is a soft edge that only moves the task to a later stage.
  for _, file in ipairs(plans or {}) do
    if #file.phase_order > 0 and file.status ~= "done" then
      local rank = {}
      for i, name in ipairs(file.phase_order) do
        rank[name] = i
      end
      ---@type table<integer, string[]>
      local by_rank = {}
      for _, t in ipairs(all_open) do
        local r = t.plan == file.id and t.phase and rank[t.phase]
        if r then
          by_rank[r] = by_rank[r] or {}
          table.insert(by_rank[r], t.id)
        end
      end
      local earlier ---@type string[]|nil
      for r = 1, #file.phase_order do
        local members = by_rank[r]
        if members then
          if earlier then
            for _, id in ipairs(members) do
              local target = file.gate == "hard" and index.gate_blockers or index.phase_edges
              target[id] = target[id] or {}
              for _, e in ipairs(earlier) do
                if not vim.tbl_contains(target[id], e) then
                  table.insert(target[id], e)
                end
              end
            end
          end
          earlier = members
        end
      end
    end
  end
  return index
end

---The hard blockers of a task: its `blocked_by` and, under a plan with `gate: hard`, the tasks of the stage before.
---@param task Tasks.Task
---@param index Tasks.PlanIndex
---@return string[]
function M.hard_blockers(task, index)
  local gates = index.gate_blockers[task.id]
  if not gates then
    return task.blocked_by or {}
  end
  local out = vim.list_slice(task.blocked_by or {}, 1, #(task.blocked_by or {}))
  for _, g in ipairs(gates) do
    if not vim.tbl_contains(out, g) then
      out[#out + 1] = g
    end
  end
  return out
end

---Where each blocker of `task` stands.
---@param task Tasks.Task
---@param index Tasks.PlanIndex
---@return string[] open_blockers
---@return string[] parked_blockers
---@return string[] unknown_blockers
local function blockers_of(task, index)
  local open, parked, unknown = {}, {}, {}
  for _, id in ipairs(M.hard_blockers(task, index)) do
    local blocker = index.open[id]
    if blocker then
      open[#open + 1] = id
      if blocker.status == "parked" then
        parked[#parked + 1] = id
      end
    elseif not index.is_done(id) then
      open[#open + 1] = id
      unknown[#unknown + 1] = id
    end
  end
  return open, parked, unknown
end

---What `task` is waiting for (before cycles are known; `build` marks a cycle member `stuck`).
---@param task Tasks.Task
---@param index Tasks.PlanIndex
---@return Tasks.PlanState state
---@return string[] open_blockers
---@return string[] unknown_blockers
function M.classify(task, index)
  local open, parked, unknown = blockers_of(task, index)
  if #open > 0 then
    if #parked > 0 or #unknown > 0 then
      return "stuck", open, unknown
    end
    return "waiting", open, unknown
  end
  local status = task.status
  if status == "open" or status == "doing" then
    return "ready", open, unknown
  elseif status == "decision" then
    return "decision", open, unknown
  elseif status == "parked" then
    return "parked", open, unknown
  elseif status == "blocked" then
    return "freed", open, unknown
  end
  return "unknown", open, unknown
end

---The one definition of "can be started now": ready, or a decision that is ready.
---@param task Tasks.Task
---@param index Tasks.PlanIndex
---@return boolean
function M.ready(task, index)
  local state = M.classify(task, index)
  return state == "ready" or state == "decision"
end

---The task plus every open task that has to be finished before it, transitively and across areas. Blockers that
---are finished or unknown are not part of it.
---@param index Tasks.PlanIndex
---@param id string
---@return Tasks.Task[]|nil tasks   # nil when `id` is no open task
function M.scope_for(index, id)
  local root = index.open[id]
  if not root then
    return nil
  end
  local seen, out, queue = { [id] = true }, { root }, { root }
  local head = 1
  while head <= #queue do
    local t = queue[head]
    head = head + 1
    for _, b in ipairs(M.hard_blockers(t, index)) do
      local blocker = index.open[b]
      if blocker and not seen[b] then
        seen[b] = true
        out[#out + 1] = blocker
        queue[#queue + 1] = blocker
      end
    end
  end
  return out
end

---Strongly connected components with more than one member, or a task that blocks itself (iterative Tarjan: a long
---chain must not overflow the stack).
---@param ids string[]
---@param succ table<string, string[]>
---@return string[][] cycles
local function find_cycles(ids, succ)
  local number, low, on_stack, stack, cycles = {}, {}, {}, {}, {}
  local counter = 0
  for _, root in ipairs(ids) do
    if number[root] == nil then
      counter = counter + 1
      number[root], low[root] = counter, counter
      stack[#stack + 1] = root
      on_stack[root] = true
      local work = { { root, 1 } }
      while #work > 0 do
        local frame = work[#work]
        local v = frame[1]
        local next_nodes = succ[v]
        local i = frame[2]
        if i <= #next_nodes then
          frame[2] = i + 1
          local w = next_nodes[i]
          if number[w] == nil then
            counter = counter + 1
            number[w], low[w] = counter, counter
            stack[#stack + 1] = w
            on_stack[w] = true
            work[#work + 1] = { w, 1 }
          elseif on_stack[w] then
            low[v] = math.min(low[v], number[w])
          end
        else
          work[#work] = nil
          if low[v] == number[v] then
            local component = {}
            repeat
              local w = table.remove(stack)
              on_stack[w] = false
              component[#component + 1] = w
            until w == v
            local self_loop = false
            if #component == 1 then
              for _, w in ipairs(succ[v]) do
                self_loop = self_loop or w == v
              end
            end
            if #component > 1 or self_loop then
              table.sort(component)
              cycles[#cycles + 1] = component
            end
          end
          local parent = work[#work]
          if parent then
            low[parent[1]] = math.min(low[parent[1]], low[v])
          end
        end
      end
    end
  end
  table.sort(cycles, function(a, b)
    return a[1] < b[1]
  end)
  return cycles
end

---@param task Tasks.Task
---@return number
local function effort_key(task)
  return model.effort_days(task.effort) or math.huge
end

---Build the plan of `tasks` (the scope). Blockers outside the scope that are still open are listed as external and
---keep a task from being ready; they take no part in stages, leverage or the critical path.
---@param tasks Tasks.Task[]
---@param index Tasks.PlanIndex
---@return Tasks.Plan
function M.build(tasks, index)
  ---@type Tasks.Plan
  local plan = {
    nodes = {},
    ids = {},
    stages = {},
    ready = {},
    decisions = {},
    cycles = {},
    conflicts = {},
    critical = { days = 0, path = {}, unknown = 0 },
    warnings = {},
  }
  local in_scope, ids = {}, {}
  for _, t in ipairs(tasks) do
    if not in_scope[t.id] then
      in_scope[t.id] = true
      ids[#ids + 1] = t.id
    end
  end
  table.sort(ids)

  ---@type table<string, string[]>
  local blockers_in, dependents = {}, {}
  for _, id in ipairs(ids) do
    blockers_in[id], dependents[id] = {}, {}
  end
  local by_id = {}
  for _, t in ipairs(tasks) do
    by_id[t.id] = t
  end
  for _, id in ipairs(ids) do
    local t = by_id[id]
    local state, open_blockers, unknown = M.classify(t, index)
    local external = {}
    for _, b in ipairs(open_blockers) do
      if not in_scope[b] then
        external[#external + 1] = b
      end
    end
    plan.nodes[id] = {
      task = t,
      state = state,
      open_blockers = open_blockers,
      external = external,
      unknown_blockers = unknown,
      leverage = 0,
      in_cycle = false,
      same_file = {},
      behind_cycle = false,
    }
    local seen = {}
    for _, b in ipairs(M.hard_blockers(t, index)) do
      if in_scope[b] and not seen[b] then
        seen[b] = true
        blockers_in[id][#blockers_in[id] + 1] = b
        dependents[b][#dependents[b] + 1] = id
      end
    end
    for _, u in ipairs(unknown) do
      plan.warnings[#plan.warnings + 1] = {
        code = "unknown-blocker",
        id = id,
        msg = ("%s waits on %s, which does not exist"):format(id, u),
      }
    end
  end

  -- Cycles over the hard edges: reported, and taken out of the rest of the calculation.
  plan.cycles = find_cycles(ids, dependents)
  local cyclic = {}
  for _, members in ipairs(plan.cycles) do
    for _, id in ipairs(members) do
      cyclic[id] = true
      plan.nodes[id].in_cycle = true
    end
    plan.warnings[#plan.warnings + 1] = {
      code = "blocked-by-cycle",
      id = members[1],
      msg = "blocked_by forms a cycle: " .. table.concat(members, " -> "),
    }
  end

  -- Stages: Kahn layering over the acyclic part, every task in the earliest possible stage.
  ---@type table<string, integer>
  local missing, stage = {}, {}
  local frontier = {}
  for _, id in ipairs(ids) do
    if not cyclic[id] then
      local n = 0
      for _, b in ipairs(blockers_in[id]) do
        if not cyclic[b] then
          n = n + 1
        end
      end
      missing[id] = n
      if n == 0 then
        stage[id] = 0
        frontier[#frontier + 1] = id
      end
    end
  end
  local topo = {}
  local head = 1
  while head <= #frontier do
    local id = frontier[head]
    head = head + 1
    topo[#topo + 1] = id
    for _, d in ipairs(dependents[id]) do
      if not cyclic[d] then
        stage[d] = math.max(stage[d] or 0, stage[id] + 1)
        missing[d] = missing[d] - 1
        if missing[d] == 0 then
          frontier[#frontier + 1] = d
        end
      end
    end
  end

  -- A task that waits on a cycle (or on a parked / unknown task) waits without end.
  for _, id in ipairs(ids) do
    local node = plan.nodes[id]
    local waits_on_cycle = false
    for _, b in ipairs(blockers_in[id]) do
      waits_on_cycle = waits_on_cycle or cyclic[b] == true
    end
    if node.in_cycle or waits_on_cycle then
      node.state = "stuck"
    end
    node.stage = stage[id]
  end
  -- ... and so does everything behind it: walk in dependency order so `stuck` travels down a whole chain.
  for _, id in ipairs(topo) do
    local node = plan.nodes[id]
    if node.state == "waiting" then
      for _, b in ipairs(blockers_in[id]) do
        if plan.nodes[b].state == "stuck" then
          node.state = "stuck"
          break
        end
      end
    end
  end

  -- A task behind a cycle has no honest stage either: it is left out of the stages like the cycle.
  local behind = {}
  for _, id in ipairs(topo) do
    for _, b in ipairs(blockers_in[id]) do
      if cyclic[b] or behind[b] then
        behind[id] = true
        plan.nodes[id].behind_cycle = true
        plan.nodes[id].stage = nil
        break
      end
    end
  end

  -- Soft edges (`after`): they only push a task into a later stage. One that would close a cycle over what is
  -- already accepted is dropped and reported; the order of the tasks (sorted ids) makes that choice stable.
  ---@param adj table<string, string[]>
  ---@param from string
  ---@param to string
  ---@return boolean
  local function reaches(adj, from, to)
    local seen, stack = { [from] = true }, { from }
    while #stack > 0 do
      local v = table.remove(stack)
      if v == to then
        return true
      end
      for _, w in ipairs(adj[v] or {}) do
        if not seen[w] then
          seen[w] = true
          stack[#stack + 1] = w
        end
      end
    end
    return false
  end
  local combined, soft_in, has_soft = {}, {}, false
  for _, id in ipairs(ids) do
    combined[id] = vim.list_slice(dependents[id], 1, #dependents[id])
    soft_in[id] = {}
  end
  for _, id in ipairs(ids) do
    if not cyclic[id] and not behind[id] then
      local seen_after = {}
      local soft = vim.list_slice(by_id[id].after or {}, 1, #(by_id[id].after or {}))
      vim.list_extend(soft, index.phase_edges[id] or {})
      for _, b in ipairs(soft) do
        if b ~= id and in_scope[b] and not cyclic[b] and not behind[b] and not seen_after[b] then
          seen_after[b] = true
          if reaches(combined, id, b) then
            plan.warnings[#plan.warnings + 1] = {
              code = "after-cycle",
              id = id,
              msg = ("%s: after %s would close a cycle and is ignored"):format(id, b),
            }
          else
            combined[b][#combined[b] + 1] = id
            soft_in[id][#soft_in[id] + 1] = b
            has_soft = true
          end
        end
      end
    end
  end
  if has_soft then
    -- Layer again over hard + accepted soft edges (longest path, so a task lands after everything it follows).
    local eligible = function(x)
      return not cyclic[x] and not behind[x]
    end
    local need, layer, queue = {}, {}, {}
    for _, id in ipairs(ids) do
      if eligible(id) then
        local n = #soft_in[id]
        for _, b in ipairs(blockers_in[id]) do
          if eligible(b) then
            n = n + 1
          end
        end
        need[id], layer[id] = n, 0
        if n == 0 then
          queue[#queue + 1] = id
        end
      end
    end
    local at = 1
    while at <= #queue do
      local id = queue[at]
      at = at + 1
      for _, d in ipairs(combined[id]) do
        if eligible(d) then
          layer[d] = math.max(layer[d], layer[id] + 1)
          need[d] = need[d] - 1
          if need[d] == 0 then
            queue[#queue + 1] = d
          end
        end
      end
    end
    for id, l in pairs(layer) do
      if need[id] == 0 then
        stage[id] = l
        plan.nodes[id].stage = l
      end
    end
  end

  -- Leverage and effective prio: walk the stages backwards, a task sees all that depend on it.
  ---@type table<string, table<string, boolean>>
  local reach = {}
  ---@type table<string, { prio: integer, id: string }|false>
  local best = {}
  for i = #topo, 1, -1 do
    local id = topo[i]
    local set = {}
    ---@type { prio: integer, id: string }|false
    local best_dep = false
    for _, d in ipairs(dependents[id]) do
      if not cyclic[d] then
        set[d] = true
        for k in pairs(reach[d]) do
          set[k] = true
        end
        local candidate = best[d]
        if candidate and (not best_dep or candidate.prio < best_dep.prio) then
          best_dep = candidate
        end
      end
    end
    reach[id] = set
    local n = 0
    for _ in pairs(set) do
      n = n + 1
    end
    local node = plan.nodes[id]
    node.leverage = n
    local own = by_id[id].prio
    local own_entry = own and { prio = own, id = id } or false
    -- the dependent's own entry wins only when it is strictly better
    local chosen = own_entry
    if best_dep and (not chosen or best_dep.prio < chosen.prio) then
      chosen = best_dep
    end
    best[id] = chosen
    if chosen then
      node.eff_prio = chosen.prio
      if chosen.id ~= id and (own == nil or chosen.prio < own) then
        node.inversion = { from = own, to = chosen.prio, because = chosen.id }
      end
    end
  end

  -- The order: status, effective prio, leverage (high first), effort (small first), id.
  ---@param a string
  ---@param b string
  ---@return boolean
  local function before(a, b)
    local na, nb = plan.nodes[a], plan.nodes[b]
    local sa, sb = STATUS_ORDER[na.task.status or ""] or 6, STATUS_ORDER[nb.task.status or ""] or 6
    if sa ~= sb then
      return sa < sb
    end
    local pa, pb = na.eff_prio or na.task.prio or NO_PRIO, nb.eff_prio or nb.task.prio or NO_PRIO
    if pa ~= pb then
      return pa < pb
    end
    local oa, ob = na.task.order or math.huge, nb.task.order or math.huge
    if oa ~= ob then
      return oa < ob
    end
    if na.leverage ~= nb.leverage then
      return na.leverage > nb.leverage
    end
    local ea, eb = effort_key(na.task), effort_key(nb.task)
    if ea ~= eb then
      return ea < eb
    end
    return a < b
  end

  for _, id in ipairs(ids) do
    local s = stage[id]
    if s and not behind[id] then
      plan.stages[s + 1] = plan.stages[s + 1] or {}
      table.insert(plan.stages[s + 1], id)
    end
  end
  for i = 1, #plan.stages do
    plan.stages[i] = plan.stages[i] or {}
    table.sort(plan.stages[i], before)
    for _, id in ipairs(plan.stages[i]) do
      plan.ids[#plan.ids + 1] = id
    end
  end
  -- Same-file: tasks of one stage that name the same file are not parallel work.
  -- The file is told by `index.file_key` when there is one (the file a ref RESOLVES to: `README.md` of two repos are
  -- two files); the pure engine, without it, keys by the ref's path.
  local file_key = index.file_key
  for i, members in ipairs(plan.stages) do
    local by_file, shown = {}, {}
    for _, id in ipairs(members) do
      local seen_files = {}
      for _, ref in ipairs(by_id[id].refs or {}) do
        local kind, rel = staleness.classify(ref)
        if kind == "path" and rel then
          local key = file_key and file_key(by_id[id], rel) or rel
          if not seen_files[key] then
            seen_files[key] = true
            by_file[key] = by_file[key] or {}
            shown[key] = shown[key] or rel
            table.insert(by_file[key], id)
          end
        end
      end
    end
    local files = {}
    for key, list in pairs(by_file) do
      if #list > 1 then
        files[#files + 1] = key
      end
    end
    table.sort(files, function(a, b)
      return shown[a] < shown[b] or (shown[a] == shown[b] and a < b)
    end)
    for _, key in ipairs(files) do
      local list = by_file[key]
      plan.conflicts[#plan.conflicts + 1] = { stage = i - 1, file = shown[key], ids = list }
      for _, id in ipairs(list) do
        for _, other in ipairs(list) do
          if other ~= id and not vim.tbl_contains(plan.nodes[id].same_file, other) then
            table.insert(plan.nodes[id].same_file, other)
          end
        end
      end
    end
  end

  for _, id in ipairs(ids) do
    table.sort(plan.nodes[id].same_file)
  end

  for _, members in ipairs(plan.cycles) do
    for _, id in ipairs(members) do
      plan.ids[#plan.ids + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    if behind[id] then
      plan.ids[#plan.ids + 1] = id
    end
  end

  for _, id in ipairs(plan.ids) do
    local node = plan.nodes[id]
    if node.state == "ready" or node.state == "decision" then
      plan.ready[#plan.ready + 1] = id
    end
  end
  table.sort(plan.ready, before)
  for _, id in ipairs(plan.ready) do
    if plan.nodes[id].state == "decision" then
      plan.decisions[#plan.decisions + 1] = id
    end
  end
  table.sort(plan.decisions, function(a, b)
    local la, lb = plan.nodes[a].leverage, plan.nodes[b].leverage
    if la ~= lb then
      return la > lb
    end
    return before(a, b)
  end)

  -- Critical path: the longest chain of hard edges, weighted with the effort in days.
  local dist, pred = {}, {}
  local best_end, best_days = nil, -1
  for _, id in ipairs(topo) do
    if behind[id] then
      goto continue
    end
    local days = model.effort_days(by_id[id].effort) or 1
    local from, longest = nil, 0
    for _, b in ipairs(blockers_in[id]) do
      if dist[b] and dist[b] > longest then
        from, longest = b, dist[b]
      end
    end
    dist[id] = days + longest
    pred[id] = from
    if dist[id] > best_days or (dist[id] == best_days and best_end and id < best_end) then
      best_end, best_days = id, dist[id]
    end
    ::continue::
  end
  if best_end then
    local path, unknown = {}, 0
    local cursor = best_end
    while cursor do
      table.insert(path, 1, cursor)
      if not model.effort_days(by_id[cursor].effort) then
        unknown = unknown + 1
      end
      cursor = pred[cursor]
    end
    plan.critical = { days = best_days, path = path, unknown = unknown }
  end

  for _, id in ipairs(plan.ids) do
    local node = plan.nodes[id]
    if node.state == "stuck" and not node.in_cycle then
      local parked = {}
      for _, b in ipairs(node.open_blockers) do
        local blocker = index.open[b]
        if blocker and blocker.status == "parked" then
          parked[#parked + 1] = b
        end
      end
      if #parked > 0 then
        plan.warnings[#plan.warnings + 1] = {
          code = "blocked-by-parked",
          id = id,
          msg = ("%s waits on %s, which is parked"):format(id, table.concat(parked, ", ")),
        }
      end
    end
  end
  return plan
end

return M
