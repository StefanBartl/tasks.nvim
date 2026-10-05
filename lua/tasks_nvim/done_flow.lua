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
    local path = fsio.norm(vim.fn.expand(doc))
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
  if done.plan_id then
    step("closing the plan " .. done.plan_id, function()
      local open = scan.open_tasks({ root = opts.root })
      if not open or #plans.members(done.plan_id, open) > 0 then
        return
      end
      local file = plans.find(done.plan_id, { root = opts.root })
      if not file then
        return
      end
      local summary = plans.summary(file, { root = opts.root, date = opts.date or opts.today })
      local closed, cerr = plans.close(done.plan_id, {
        root = opts.root,
        date = opts.date,
        today = opts.today,
        checkpoint_dir = opts.checkpoint_dir,
      })
      if not closed then
        flow.notes[#flow.notes + 1] = ("the plan %s could not be closed: %s"):format(
          done.plan_id,
          tostring(cerr)
        )
        return
      end
      flow.plans_closed[#flow.plans_closed + 1] = done.plan_id
      summary.title = file.title
      flow.plan_summaries[done.plan_id] = summary
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
