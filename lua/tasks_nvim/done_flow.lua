---@module 'tasks_nvim.done_flow'
---@brief The one entry for "finish a task": `mutate.done` plus whatever follows from it.
---@description
--- Every front end that finishes a task (the `:Tasks done` command, the dashboard's `D`, the headless CLI) calls
--- `run` and nothing else. The flow is `mutate.done` and then the chain:
---  a. the open steps of the task's own `## Plan` are ticked (written WITH the finish, so its rollback covers them;
---     a step marked `(dropped)` stays open);
---  b. a plan file whose last member task this was is finished (moved to `Backlog/FEATURES/`);
---  c. the marker blocks (`<!-- GENERATED:plan scope=... -->`) of the documents named in `setup({ chain = {
---     marker_docs = {...} } })` are refreshed -- only those files, nothing is scanned;
---  d. the tasks the finish freed, and e. the next task to start (`next_pick`).
---
--- Rules the chain keeps (so they can be relied on now):
---  - the truth changes first: `mutate.done` runs, and only a successful, non-`already` finish starts the chain;
---  - a failure AFTER the finish never undoes it: it goes to `notes` (the task is done, one follow-up step did not
---    work -- an honest report, not a half rollback);
---  - an already finished task changes nothing and runs no chain.
---
--- Not its job: the finish itself (`mutate.done`), batches (`batch.done_many` calls `run` per task), messages.

local fsio = require("tasks_nvim.fsio")
local mutate = require("tasks_nvim.mutate")
local next_pick = require("tasks_nvim.next_pick")
local plan_scope = require("tasks_nvim.plan_scope")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.DoneFlowOpts : Tasks.DoneOpts
---@field chain? boolean       # Run the follow-up steps (default true).
---@field pick_next? boolean   # Name the freed tasks and pick the next one (default true; a batch picks once at its end).
---@field refresh_docs? boolean  # Refresh the generated blocks of the configured documents (default true; a batch does it once).
---@field defer_plan_close? boolean  # Leave step b to the caller (`close_plans`): a batch checks each plan once, not per task.

---What a finish did. `done` is what `mutate.done` returned (`done.already` for a task that was finished before).
---@class Tasks.DoneFlow
---@field done table                 # The result of `mutate.done`.
---@field steps_ticked integer       # Plan steps of the task ticked off.
---@field plan_summaries table<string, Tasks.PlanSummary>  # What each closed plan amounted to.
---@field freed string[]             # Ids of tasks whose last open blocker this was (set with `next`).
---@field plans_closed string[]      # Ids of plan files closed because their last member is done.
---@field docs_refreshed string[]    # Generated plan blocks that were refreshed.
---@field notes string[]             # Follow-up steps that did not work; the finish itself stands.
---@field next? Tasks.NextPick       # What to start next (`next_pick`); absent when not asked for or not computable.

---Refresh the marker blocks of the documents named in `setup({ chain = { marker_docs = ... } })`. Only those files
---are read or written; a block that cannot be refreshed is a note, never an error.
---`opts.closed` (plan id -> summary) names plans that were finished a moment ago: their block is rewritten as the
---"plan is done" line, its last state.
---@param opts? { root?: string, closed?: table<string, table> }
---@return string[] refreshed  # The documents that changed.
---@return string[] notes
function M.refresh_marker_docs(opts)
  opts = opts or {}
  local refreshed, notes = {}, {}
  local docs = require("tasks_nvim.config").get().chain.marker_docs
  if #docs == 0 then
    return refreshed, notes
  end
  local root = vault.root(opts)
  if not root then
    return refreshed, notes
  end
  local closed
  for plan_id, summary in pairs(opts.closed or {}) do
    closed = closed or {}
    closed[(plan_id:match("([^/]+)$")) or plan_id] =
      require("tasks_nvim.plan_view").plan_closed_text(plan_id, summary)
  end
  for _, doc in ipairs(docs) do
    local path = fsio.doc_path(doc)
    local res, err = plan_scope.refresh_document(path, root, closed)
    if not res then
      notes[#notes + 1] = tostring(err)
    else
      if res.changed then
        refreshed[#refreshed + 1] = path
      end
      for _, skipped in ipairs(res.skipped) do
        notes[#notes + 1] = ("%s: %s"):format(path, skipped.reason)
      end
    end
  end
  return refreshed, notes
end

---@class Tasks.ClosedPlans
---@field closed string[]                        # Ids of the plan files that were finished.
---@field summaries table<string, Tasks.PlanSummary>
---@field notes string[]                         # Plans that could not be closed, or whose state could not be judged.

---Step b: finish every plan of `plan_ids` that has no open member task left. One scan for all of them, and none when
---no such plan file exists (a task may name a plan that was never written). A member is any task with `plan: <id>`
---whose status is not `done`, valid or not: a typo in `status:` must not make the plan look finished. A scan that
---could not list every folder cannot say that no member is open: the plans stay and a note says so.
---@param plan_ids string[]
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string }
---@return Tasks.ClosedPlans
function M.close_plans(plan_ids, opts)
  opts = opts or {}
  ---@type Tasks.ClosedPlans
  local out = { closed = {}, summaries = {}, notes = {} }
  local files, seen = {}, {}
  for _, plan_id in ipairs(plan_ids) do
    if not seen[plan_id] then
      seen[plan_id] = true
      local file = plans.find(plan_id, { root = opts.root })
      if file then
        files[#files + 1] = file
      end
    end
  end
  if #files == 0 then
    return out
  end
  local all, errors = scan.all({ root = opts.root })
  if not all then
    out.notes[1] = ("the plans could not be checked: %s"):format(tostring(errors))
    return out
  end
  if type(errors) == "table" and #errors > 0 then
    for _, file in ipairs(files) do
      out.notes[#out.notes + 1] = ("the plan %s was not closed: the scan was incomplete (%s)"):format(
        file.id,
        tostring(errors[1])
      )
    end
    return out
  end
  for _, file in ipairs(files) do
    local open = 0
    for _, t in ipairs(plans.members(file.id, all)) do
      if t.status ~= "done" then
        open = open + 1
      end
    end
    if open == 0 then
      local summary = plans.summary(file, { root = opts.root, date = opts.date or opts.today })
      local closed, cerr = plans.close(file.id, {
        root = opts.root,
        date = opts.date,
        today = opts.today,
        checkpoint_dir = opts.checkpoint_dir,
      })
      if not closed then
        out.notes[#out.notes + 1] = ("the plan %s could not be closed: %s"):format(
          file.id,
          tostring(cerr)
        )
      else
        out.closed[#out.closed + 1] = file.id
        summary.title = file.title
        out.summaries[file.id] = summary
      end
    end
  end
  return out
end

---Finish `id`.
---@param id string
---@param opts? Tasks.DoneFlowOpts
---@return Tasks.DoneFlow|nil flow
---@return string|nil err   # The finish failed (nothing changed, or the rollback says what it could not undo).
function M.run(id, opts)
  opts = opts or {}
  -- Step a is part of the finish itself: the ticked text is what `mutate.done` writes as the finished copy.
  local done, err =
    mutate.done(id, vim.tbl_extend("force", opts, { tick_steps = opts.chain ~= false }))
  if not done then
    return nil, err
  end
  ---@type Tasks.DoneFlow
  local flow = {
    done = done,
    steps_ticked = 0,
    freed = {},
    plans_closed = {},
    plan_summaries = {},
    docs_refreshed = {},
    notes = {},
  }
  flow.steps_ticked = done.steps_ticked or 0
  if done.already or opts.chain == false then
    return flow, nil
  end
  -- Each follow-up step runs in its own pcall so that one cannot cost the others; a failure is a note.
  ---@param what string
  ---@param fn fun()
  local function step(what, fn)
    local ran, perr = pcall(fn)
    if not ran then
      flow.notes[#flow.notes + 1] = ("%s: %s"):format(what, tostring(perr))
    end
  end

  -- b. the plan this task belonged to: finished when no member is left open
  if done.plan_id and not opts.defer_plan_close then
    step("closing the plan " .. done.plan_id, function()
      local res = M.close_plans({ done.plan_id }, opts)
      vim.list_extend(flow.plans_closed, res.closed)
      vim.list_extend(flow.notes, res.notes)
      for plan_id, summary in pairs(res.summaries) do
        flow.plan_summaries[plan_id] = summary
      end
    end)
  end

  -- c. the generated blocks of the documents the user named, and only those (a batch does this once at its end)
  if opts.refresh_docs ~= false then
    step("refreshing generated plan blocks", function()
      local refreshed, notes =
        M.refresh_marker_docs({ root = opts.root, closed = flow.plan_summaries })
      vim.list_extend(flow.docs_refreshed, refreshed)
      vim.list_extend(flow.notes, notes)
    end)
  end

  -- d. the freed tasks and e. the next task
  if opts.pick_next ~= false then
    local ran, pick, perr = pcall(next_pick.pick_from_vault, {
      root = opts.root,
      done = { id = done.id, area = done.area },
    })
    if ran and pick then
      flow.next = pick
      flow.freed = pick.freed
    else
      flow.notes[#flow.notes + 1] = "the next task could not be worked out: "
        .. tostring(ran and perr or pick)
    end
  end
  return flow, nil
end

return M
