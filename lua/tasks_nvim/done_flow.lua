---@module 'tasks_nvim.done_flow'
---@brief The one entry for "finish a task": `mutate.done` plus whatever follows from it.
---@description
--- Every front end that finishes a task (the `:Tasks done` command, the dashboard's `D`, the headless CLI) calls
--- `run` and nothing else. Today the flow is `mutate.done` and an empty chain; the chain (ticking the task's own
--- plan steps, closing a plan file whose last member is done, refreshing generated plan blocks, naming the tasks
--- that were freed, picking the next task) lands behind this seam without touching a caller.
---
--- Rules the chain keeps (so they can be relied on now):
---  - the truth changes first: `mutate.done` runs, and only a successful, non-`already` finish starts the chain;
---  - a failure AFTER the finish never undoes it: it goes to `notes` (the task is done, one follow-up step did not
---    work -- an honest report, not a half rollback);
---  - an already finished task changes nothing and runs no chain.
---
--- Not its job: the finish itself (`mutate.done`), batches (`batch.done_many` calls `run` per task), messages.

local mutate = require("tasks_nvim.mutate")

local M = {}

---@class Tasks.DoneFlowOpts : Tasks.DoneOpts
---@field chain? boolean   # Run the follow-up steps (default true; there are none yet).

---What a finish did. `done` is what `mutate.done` returned (`done.already` for a task that was finished before).
---@class Tasks.DoneFlow
---@field done table                 # The result of `mutate.done`.
---@field steps_ticked integer       # Plan steps of the task ticked off.
---@field freed string[]             # Ids of tasks whose last open blocker this was.
---@field plans_closed string[]      # Ids of plan files closed because their last member is done.
---@field docs_refreshed string[]    # Generated plan blocks that were refreshed.
---@field notes string[]             # Follow-up steps that did not work; the finish itself stands.
---@field next? table                # The suggested next task (not built yet).

---Finish `id`.
---@param id string
---@param opts? Tasks.DoneFlowOpts
---@return Tasks.DoneFlow|nil flow
---@return string|nil err   # The finish failed (nothing changed, or the rollback says what it could not undo).
function M.run(id, opts)
  opts = opts or {}
  local done, err = mutate.done(id, opts)
  if not done then
    return nil, err
  end
  ---@type Tasks.DoneFlow
  local flow = {
    done = done,
    steps_ticked = 0,
    freed = {},
    plans_closed = {},
    docs_refreshed = {},
    notes = {},
  }
  if done.already or opts.chain == false then
    return flow, nil
  end
  -- The follow-up steps go here, each in its own pcall so that one cannot cost the others; a failure is a note.
  return flow, nil
end

return M
