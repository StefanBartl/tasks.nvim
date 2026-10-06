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
local plan_view = require("tasks_nvim.plan_view")
local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")

local M = {}

---@class Tasks.PlanScopeOpts
---@field root? string
---@field area? string
---@field for_id? string
---@field plan_id? string             # The plan file (`<area>/<slug>`): the tasks that name it with `plan:`.
---@field filter? Tasks.Filter

---@class Tasks.PlanScope
---@field plan Tasks.Plan
---@field tasks Tasks.Task[]          # The scope.
---@field index Tasks.PlanIndex
---@field done? Tasks.Task[]          # Finished tasks of the area (only for an area scope): the progress figure.
---@field plan_file? Tasks.PlanFile   # The plan file of a `plan_id` scope.
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
  local files = plans.all({ root = root })
  local index = plan.index(open, function(id)
    local hit = known[id]
    if hit == nil then
      hit = scan.find_done(id, { root = root }) ~= nil
      known[id] = hit
    end
    return hit
  end, files or {})
  return index, open, errors
end

---Keep the tasks that are ready (`which = "ready"`) or wait on an open blocker (`which = "waiting"`), judged against
---EVERY open task of the vault: a blocker may sit in another area than the list being filtered.
---@param tasks Tasks.Task[]
---@param which "ready"|"waiting"
---@param root? string
---@return Tasks.Task[]|nil kept
---@return string|nil err
function M.filter_readiness(tasks, which, root)
  local index, everything = M.index(root)
  if not index then
    return nil, tostring(everything)
  end
  local kept = {}
  for _, t in ipairs(tasks) do
    local state = plan.classify(t, index)
    local is_ready = state == "ready" or state == "decision"
    local is_waiting = state == "waiting" or state == "stuck"
    if (which == "ready" and is_ready) or (which == "waiting" and is_waiting) then
      kept[#kept + 1] = t
    end
  end
  return kept, nil
end

---What a block name stands for: an area, an open plan's slug, `all`, or `for-<slug>` (the open task of that slug).
---`nil, reason, finished` when it names nothing that is open; `finished` is true when it names something that was
---finished (a closed plan's block is history: it is left as it is, and nothing is said about it).
---@param key string
---@param root string
---@return Tasks.PlanScopeOpts|nil opts
---@return string|nil reason
---@return boolean|nil finished
function M.resolve_block(key, root)
  if key == "all" then
    return { root = root }, nil
  end
  if vault.has_area(root, key) then
    return { root = root, area = key }, nil
  end
  for _, file in ipairs(plans.all({ root = root }) or {}) do
    if file.slug == key then
      return { root = root, plan_id = file.id }, nil
    end
  end
  local slug = key:match("^for%-(.+)$")
  if slug then
    for _, t in ipairs(scan.open_tasks({ root = root }) or {}) do
      if t.slug == slug then
        return { root = root, for_id = t.id }, nil
      end
    end
  end
  for _, area in ipairs(vault.areas(root)) do
    if scan.find_done(area.name .. "/" .. (slug or key), { root = root }) then
      return nil, ("the block `%s` names something that is finished"):format(key), true
    end
  end
  return nil, ("the block `%s` names no area, open plan or open task"):format(key), false
end

---Refresh every marker block of a document: only the blocks change, the rest of the file (and its line endings)
---stays. Nothing is written when nothing changed.
---`closed` names plans finished a moment ago (block name -> text): their block gets that text as its last state
---instead of being left showing tasks that are done.
---@param path string
---@param root string
---@param closed? table<string, string>
---@return { changed: boolean, refreshed: string[], skipped: { scope: string, reason: string }[] }|nil result
---@return string|nil err
function M.refresh_document(path, root, closed)
  local text, err = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local result = { changed = false, refreshed = {}, skipped = {} }
  local fresh = text
  for _, key in ipairs(plan_view.block_scopes(text)) do
    local scope_opts, reason, finished = M.resolve_block(key, root)
    local scope = scope_opts and M.load(scope_opts)
    if closed and closed[key] then
      local replaced, _, changed = plan_view.replace_block(fresh, key, closed[key])
      if replaced then
        fresh = replaced
        if changed then
          result.refreshed[#result.refreshed + 1] = key
        end
      end
    elseif finished then
      -- history: left exactly as it is
    elseif not scope then
      result.skipped[#result.skipped + 1] = { scope = key, reason = reason or "could not be read" }
    else
      local body = plan_view.markdown(scope.plan, {
        title = scope.title,
        done = scope.done,
        plan_file = scope.plan_file,
        block = true,
      })
      local replaced, rerr, changed = plan_view.replace_block(fresh, key, body)
      if not replaced then
        result.skipped[#result.skipped + 1] = { scope = key, reason = tostring(rerr) }
      else
        fresh = replaced
        if changed then
          result.refreshed[#result.refreshed + 1] = key
        end
      end
    end
  end
  if fresh ~= text then
    -- a document the user named may be a symlink to the original: write through it
    local ok, werr = fsio.write_atomic(path, fresh, { follow_symlinks = true })
    if not ok then
      return nil, ("cannot write %s: %s"):format(path, tostring(werr))
    end
    result.changed = true
  end
  return result, nil
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
  local tasks, title, plan_file
  if opts.plan_id then
    local found, perr = plans.find(opts.plan_id, { root = opts.root })
    if not found then
      return nil, tostring(perr)
    end
    plan_file = found
    tasks = plans.members(found.id, open)
    title = "plan " .. found.id
  elseif opts.for_id then
    local closure = plan.scope_for(index, opts.for_id)
    if not closure then
      return nil, "no such open task: " .. opts.for_id
    end
    tasks = closure
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
    title = title or "",
    plan_file = plan_file,
  }
  if opts.area and not opts.for_id then
    local finished = scan.backlog(opts.area, { root = opts.root })
    scope.done = finished or {}
  end
  return scope, nil
end

return M
