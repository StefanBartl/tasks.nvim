---@module 'tasks_nvim.done_flow'
---@brief The one entry for "finish a task": `mutate.done` plus whatever follows from it.
---@description
--- Every front end that finishes a task (the `:Tasks done` command, the dashboard's `D`, the headless CLI) calls
--- `run` and nothing else. The flow is `mutate.done` and then the chain: the tasks the finish freed and the next task
--- to start (`next_pick`). Ticking the task's own plan steps, closing a plan file whose last member is done and
--- refreshing generated plan blocks land behind the same seam without touching a caller.
---
--- Rules the chain keeps (so they can be relied on now):
---  - the truth changes first: `mutate.done` runs, and only a successful, non-`already` finish starts the chain;
---  - a failure AFTER the finish never undoes it: it goes to `notes` (the task is done, one follow-up step did not
---    work -- an honest report, not a half rollback);
---  - an already finished task changes nothing and runs no chain.
---
--- Not its job: the finish itself (`mutate.done`), batches (`batch.done_many` calls `run` per task), messages.

local mutate = require("tasks_nvim.mutate")
local next_pick = require("tasks_nvim.next_pick")

local M = {}

---@class Tasks.DoneFlowOpts : Tasks.DoneOpts
---@field chain? boolean       # Run the follow-up steps (default true).
---@field pick_next? boolean   # Name the freed tasks and pick the next one (default true; a batch picks once at its end).

---What a finish did. `done` is what `mutate.done` returned (`done.already` for a task that was finished before).
---@class Tasks.DoneFlow
---@field done table                 # The result of `mutate.done`.
---@field steps_ticked integer       # Plan steps of the task ticked off.
---@field freed string[]             # Ids of tasks whose last open blocker this was (set with `next`).
---@field plans_closed string[]      # Ids of plan files closed because their last member is done.
---@field docs_refreshed string[]    # Generated plan blocks that were refreshed.
---@field notes string[]             # Follow-up steps that did not work; the finish itself stands.
---@field next? Tasks.NextPick       # What to start next (`next_pick`); absent when not asked for or not computable.

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
  -- Each follow-up step runs in its own pcall so that one cannot cost the others; a failure is a note.
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
