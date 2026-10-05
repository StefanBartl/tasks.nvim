---@module 'tasks_nvim.next_pick'
---@brief What to start next: the best READY task, with the reason, the runners-up and an honest answer when there is none.
---@description
--- The selection behind the popup after `done`, `:Tasks next`, the CLI `next` line and the dashboard: one pure
--- function over the open tasks, so all of them give the same answer. "Ready" is NOT defined here: the candidates
--- are what `tasks_nvim.plan` calls ready (an open / doing / decision task with no open blocker) -- a second reading
--- would count differently from the dashboard.
---
--- Order (fixed, documented; the first difference decides):
---  1. freed by the task that was just finished
---  2. the same area, then the whole vault   (a `plan:` scope slots in between once plan files exist)
---  3. status: `doing`, then `open`, then `decision`
---  4. effective priority (`plan`: a task that blocks a better one rates as that one)
---  5. return on effort (`model.roi`, highest first; a task without a figure after those with one)
---  6. effort ascending, then the id
---
--- Who it is for: without `opts.actor` the answer is for the human, so tasks written `cdx` are not offered as "your
--- next task" but listed apart (`cdx`, "an AI session could take these"). `opts.actor = "cdx"` (or `me`, `pair`,
--- `none`) asks for that queue instead.
---
--- Empty answers do not cheer: `empty.kind` is `all_done` only when nothing is open at all; `nothing_startable` says
--- what is still waiting (so the popup can say "nothing startable, 4 wait for you, 6 are blocked" and never "all
--- done" when only waiting work is left); `only_cdx` when everything startable is for an AI session.
---
--- Not its job: showing it (`ui.cmd`), finishing a task (`done_flow`).

local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")

local M = {}

---@class Tasks.NextOpts
---@field tasks Tasks.Task[]                    # Every open task of the vault.
---@field is_done? (fun(id: string): boolean)|table<string, boolean>  # Finished ids (default: none known).
---@field done? { id: string, area: string }    # The task that was just finished.
---@field area? string                          # Area that ranks first (default: the finished task's).
---@field actor? string                         # `cdx`, `me`, `pair` or `none`: that queue instead of the human's.
---@field n? integer                            # Runners-up to return (default 2).
---@field cdx? integer                          # Tasks for an AI session to list apart (default 3).

---@class Tasks.NextPick
---@field task? Tasks.Task
---@field reason? "freed"|"area"|"vault"
---@field alternatives Tasks.Task[]
---@field cdx Tasks.Task[]                      # Ready tasks written `cdx`, apart from the human's list.
---@field freed string[]                        # Tasks the finished one was the last open blocker of.
---@field freed_blocked string[]                # ... of those, the ones still written `status: blocked`.
---@field ready { area: integer, vault: integer }   # Ready tasks (for the human's list) in the area / the vault.
---@field open { area: integer, vault: integer }
---@field empty? Tasks.NextEmpty
---@field incomplete? string[]                  # Folders that could not be read: the answer may be incomplete.

---@class Tasks.NextEmpty
---@field kind "all_done"|"nothing_startable"|"only_cdx"
---@field area_empty boolean                    # The finished task's area has no open task left.
---@field waiting integer                       # Open tasks that wait on another open task.
---@field for_me integer                        # Open tasks that are yours (actor me) and not startable.
---@field blocked_status integer                # `status: blocked` with nothing blocking (set them to open).
---@field parked integer

---@type table<string, integer>
local STATUS_RANK = { doing = 1, open = 2, decision = 3 }

---Who a ready task is offered to: the human's list, an AI session's, or the one asked for.
---@param task Tasks.Task
---@param want? string
---@return boolean
local function wanted(task, want)
  local who = model.actor(task) or "none"
  if want then
    return who == want
  end
  return who ~= "cdx"
end

---@param opts Tasks.NextOpts
---@return Tasks.NextPick
function M.pick(opts)
  local index = plan.index(opts.tasks, opts.is_done)
  local built = plan.build(opts.tasks, index)
  local done = opts.done
  local home = opts.area or (done and done.area) or nil

  ---@type Tasks.NextPick
  local result = {
    alternatives = {},
    cdx = {},
    freed = {},
    freed_blocked = {},
    ready = { area = 0, vault = 0 },
    open = { area = 0, vault = 0 },
  }

  -- Freed: every task that names the finished one and has nothing open left behind it.
  local freed = {}
  if done then
    for _, id in ipairs(built.ids) do
      local node = built.nodes[id]
      if #node.open_blockers == 0 and not node.in_cycle then
        for _, b in ipairs(node.task.blocked_by or {}) do
          if b == done.id then
            freed[id] = true
            result.freed[#result.freed + 1] = id
            if node.task.status == "blocked" then
              result.freed_blocked[#result.freed_blocked + 1] = id
            end
            break
          end
        end
      end
    end
    table.sort(result.freed)
    table.sort(result.freed_blocked)
  end

  for _, t in ipairs(opts.tasks) do
    result.open.vault = result.open.vault + 1
    if home and t.area == home then
      result.open.area = result.open.area + 1
    end
  end

  ---@param t Tasks.Task
  ---@return integer
  local function scope_rank(t)
    if freed[t.id] then
      return 1
    end
    if home and t.area == home then
      return 2
    end
    return 3
  end

  ---@type Tasks.Task[]
  local candidates = {}
  for _, id in ipairs(built.ready) do
    local node = built.nodes[id]
    if wanted(node.task, opts.actor) then
      candidates[#candidates + 1] = node.task
      result.ready.vault = result.ready.vault + 1
      if home and node.task.area == home then
        result.ready.area = result.ready.area + 1
      end
    elseif not opts.actor and model.actor(node.task) == "cdx" then
      result.cdx[#result.cdx + 1] = node.task
    end
  end

  ---@param a Tasks.Task
  ---@param b Tasks.Task
  ---@return boolean
  local function better(a, b)
    local ra, rb = scope_rank(a), scope_rank(b)
    if ra ~= rb then
      return ra < rb
    end
    local sa, sb = STATUS_RANK[a.status or ""] or 9, STATUS_RANK[b.status or ""] or 9
    if sa ~= sb then
      return sa < sb
    end
    local pa = built.nodes[a.id].eff_prio or a.prio or 99
    local pb = built.nodes[b.id].eff_prio or b.prio or 99
    if pa ~= pb then
      return pa < pb
    end
    local roa, rob = model.roi(a), model.roi(b)
    if roa ~= rob then
      if roa and rob then
        return roa > rob
      end
      return roa ~= nil
    end
    local ea, eb =
      model.effort_days(a.effort) or math.huge, model.effort_days(b.effort) or math.huge
    if ea ~= eb then
      return ea < eb
    end
    return a.id < b.id
  end
  table.sort(candidates, better)
  table.sort(result.cdx, better)
  local keep_cdx = opts.cdx or 3
  for i = #result.cdx, keep_cdx + 1, -1 do
    result.cdx[i] = nil
  end

  local top = candidates[1]
  if top then
    result.task = top
    result.reason = freed[top.id] and "freed" or (home and top.area == home) and "area" or "vault"
    for i = 2, math.min(#candidates, 1 + (opts.n or 2)) do
      result.alternatives[#result.alternatives + 1] = candidates[i]
    end
    return result
  end

  -- Nothing to offer: say which kind of nothing it is.
  ---@type Tasks.NextEmpty
  local empty = {
    kind = "nothing_startable",
    area_empty = done ~= nil and result.open.area == 0,
    waiting = 0,
    for_me = 0,
    blocked_status = 0,
    parked = 0,
  }
  for _, id in ipairs(built.ids) do
    local node = built.nodes[id]
    local state = node.state
    if state == "waiting" or state == "stuck" then
      empty.waiting = empty.waiting + 1
    elseif state == "freed" then
      empty.blocked_status = empty.blocked_status + 1
    elseif state == "parked" then
      empty.parked = empty.parked + 1
    end
    if model.actor(node.task) == "me" and state ~= "ready" and state ~= "decision" then
      empty.for_me = empty.for_me + 1
    end
  end
  if #opts.tasks == 0 then
    empty.kind = "all_done"
  elseif not opts.actor and #result.cdx > 0 then
    empty.kind = "only_cdx"
  end
  result.empty = empty
  return result
end

---The same over the vault on disk: every open task, the finished ids looked up in the Backlogs when needed.
---@param opts { root?: string, done?: { id: string, area: string }, area?: string, actor?: string, n?: integer, cdx?: integer }
---@return Tasks.NextPick|nil result
---@return string|nil err
function M.pick_from_vault(opts)
  local scan = require("tasks_nvim.scan")
  local open, skipped, errors = scan.open_tasks({ root = opts.root })
  if not open then
    return nil, tostring(skipped)
  end
  local known = {}
  local result = M.pick({
    tasks = open,
    is_done = function(id)
      local hit = known[id]
      if hit == nil then
        hit = scan.find_done(id, { root = opts.root }) ~= nil
        known[id] = hit
      end
      return hit
    end,
    done = opts.done,
    area = opts.area,
    actor = opts.actor,
    n = opts.n,
    cdx = opts.cdx,
  })
  -- A folder that could not be read means the answer may be incomplete, in particular an "all done".
  if errors and #errors > 0 then
    result.incomplete = errors
  end
  return result, nil
end

return M
