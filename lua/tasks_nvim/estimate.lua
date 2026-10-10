---@module 'tasks_nvim.estimate'
---@brief Sums of effort and value over a set of tasks, always saying how many tasks are missing from the sum.
---@description
--- Pure: tasks in, a table of numbers out. Used by `:Tasks estimate`, `tasks estimate`, the plan header and the
--- dashboard header, so every place shows the same figures.
---
--- Rules the figures keep:
---  - a sum names how much it is made of ("22 d from 17 of 20 tasks"): a task without an estimate is not 0, it is
---    missing, and the numbers say so;
---  - the effort sum is a figure from a SCALE (`model.effort_days`), not a promise, and the T-shirt sizes are rough:
---    next to the sum goes a range (every size at its low and at its high end), without it the sum looks more exact
---    than it is;
---  - the return on effort is value over days across the tasks that have BOTH numbers only;
---  - the split by actor answers "how much of this is mine to do" (`model.actor`: the written value, else derived).
---
--- Not its job: finding the tasks (`scan`), the order (`plan`), asking the user for the missing numbers
--- (`ui.cmd`).

local model = require("tasks_nvim.model")

local M = {}

---The text that travels with every sum.
M.CAVEAT = "estimate from the scale, not a promise"

---The range of a T-shirt size in days: low and high end. A size is not a number; the plain scale of
---`model.effort_days` is the middle of it. Days written as `0.5d` have no range.
---@type table<string, { [1]: number, [2]: number }>
M.RANGE_DAYS = {
  XS = { 0.15, 0.35 },
  S = { 0.35, 0.8 },
  M = { 0.7, 1.5 },
  L = { 2, 5 },
  XL = { 3, 8 },
}

---The built-in quick-win definition: a value of at least 4 ...
M.QUICK_WIN_VALUE = 4

---... and at most this effort in days (`S`). `setup({ quick_wins = { min_value, max_effort } })` changes both.
M.QUICK_WIN_DAYS = 0.5

---@class Tasks.QuickWinThresholds
---@field value integer   Minimum value.
---@field days number     Maximum effort in days.
---@field effort string   The maximum effort as written (`S`, `0.5d`).

---The quick-win thresholds in force: the `quick_wins` config section, else the built-in definition.
---@return Tasks.QuickWinThresholds
function M.thresholds()
  local cfg = require("tasks_nvim.config").get().quick_wins or {}
  local effort = type(cfg.max_effort) == "string" and cfg.max_effort or "S"
  local days = model.effort_days(effort) or M.QUICK_WIN_DAYS
  local value = type(cfg.min_value) == "number" and cfg.min_value or M.QUICK_WIN_VALUE
  return { value = value, days = days, effort = effort }
end

---A quick win has BOTH numbers written: a value at the threshold or above and an effort at the threshold or below.
---A task missing either is unestimated, never a quick win.
---@param task Tasks.Task
---@param th? Tasks.QuickWinThresholds
---@return boolean
function M.is_quick_win(task, th)
  th = th or M.thresholds()
  local days = model.effort_days(task.effort)
  return days ~= nil and task.value ~= nil and task.value >= th.value and days <= th.days
end

---@class Tasks.ActorShare
---@field n integer        # Tasks.
---@field days number      # Effort of those with a known effort.
---@field n_without_effort integer

---@class Tasks.Rollup
---@field n integer
---@field days number                      # Sum of the known efforts (scale).
---@field n_with_effort integer
---@field n_without_effort integer
---@field range { low: number, high: number }
---@field value integer                    # Sum of the known values.
---@field n_with_value integer
---@field n_without_value integer
---@field roi? number                      # value / days over the tasks with both numbers; nil when there are none.
---@field n_roi integer                    # Tasks that went into `roi`.
---@field quick_wins string[]              # Ids with a high value and a small effort, best roi first.
---@field unestimated string[]             # Ids missing the effort or the value.
---@field by_actor table<string, Tasks.ActorShare>  # `me`, `cdx`, `pair` and `none` (nobody classified it).
---@field progress? { done_days: number, total_days: number, pct: integer, n_done: integer, n_done_without_effort: integer }

---The low and high end of an effort, in days.
---@param effort any
---@return number|nil low
---@return number|nil high
local function range_of(effort)
  local days = model.effort_days(effort)
  if not days then
    return nil, nil
  end
  local pair = M.RANGE_DAYS[effort]
  if pair then
    return pair[1], pair[2]
  end
  return days, days
end

---Sum up `tasks`.
---@param tasks Tasks.Task[]
---@param opts? { done?: Tasks.Task[] }  # Finished tasks of the same scope: they make the progress figure.
---@return Tasks.Rollup
function M.rollup(tasks, opts)
  opts = opts or {}
  ---@type Tasks.Rollup
  local r = {
    n = #tasks,
    days = 0,
    n_with_effort = 0,
    n_without_effort = 0,
    range = { low = 0, high = 0 },
    value = 0,
    n_with_value = 0,
    n_without_value = 0,
    n_roi = 0,
    quick_wins = {},
    unestimated = {},
    by_actor = {
      me = { n = 0, days = 0, n_without_effort = 0 },
      cdx = { n = 0, days = 0, n_without_effort = 0 },
      pair = { n = 0, days = 0, n_without_effort = 0 },
      none = { n = 0, days = 0, n_without_effort = 0 },
    },
  }
  local roi_days, roi_value = 0, 0
  local wins = {}
  local th = M.thresholds()
  for _, t in ipairs(tasks) do
    local days = model.effort_days(t.effort)
    local share = r.by_actor[model.actor(t) or "none"]
    share.n = share.n + 1
    if days then
      r.days = r.days + days
      r.n_with_effort = r.n_with_effort + 1
      local low, high = range_of(t.effort)
      r.range.low = r.range.low + (low or days)
      r.range.high = r.range.high + (high or days)
      share.days = share.days + days
    else
      r.n_without_effort = r.n_without_effort + 1
      share.n_without_effort = share.n_without_effort + 1
    end
    if t.value then
      r.value = r.value + t.value
      r.n_with_value = r.n_with_value + 1
    else
      r.n_without_value = r.n_without_value + 1
    end
    if days and t.value then
      roi_days = roi_days + math.max(days, 0.25)
      roi_value = roi_value + t.value
      r.n_roi = r.n_roi + 1
      if M.is_quick_win(t, th) then
        wins[#wins + 1] = t
      end
    else
      r.unestimated[#r.unestimated + 1] = t.id
    end
  end
  if r.n_roi > 0 then
    r.roi = roi_value / roi_days
  end
  table.sort(wins, model.compare_roi)
  for _, t in ipairs(wins) do
    r.quick_wins[#r.quick_wins + 1] = t.id
  end

  if opts.done then
    local done_days, n_without = 0, 0
    for _, t in ipairs(opts.done) do
      local days = model.effort_days(t.effort)
      if days then
        done_days = done_days + days
      else
        n_without = n_without + 1
      end
    end
    local total = done_days + r.days
    r.progress = {
      done_days = done_days,
      total_days = total,
      pct = total > 0 and math.floor(done_days / total * 100 + 0.5) or 0,
      n_done = #opts.done,
      n_done_without_effort = n_without,
    }
  end
  return r
end

---Days as the figures show them: `22`, `7.5`, `0.25`.
---@param days number
---@return string
function M.fmt_days(days)
  local text = ("%.2f"):format(days):gsub("0+$", ""):gsub("%.$", "")
  return text
end

---One line: what the tasks add up to and how much of it is guessed, missing or somebody's.
---@param r Tasks.Rollup
---@return string
function M.describe(r)
  local parts = { ("%d task%s"):format(r.n, r.n == 1 and "" or "s") }
  if r.n_with_effort > 0 then
    local text = ("%s d from %d of %d"):format(M.fmt_days(r.days), r.n_with_effort, r.n)
    if r.range.high > r.range.low then
      text = text .. (" (range %s-%s d)"):format(M.fmt_days(r.range.low), M.fmt_days(r.range.high))
    end
    parts[#parts + 1] = text
  else
    parts[#parts + 1] = "no effort estimated"
  end
  if r.n_with_value > 0 then
    parts[#parts + 1] = ("value %d (%d of %d)"):format(r.value, r.n_with_value, r.n)
  end
  if r.roi then
    parts[#parts + 1] = ("roi %.1f"):format(r.roi)
  end
  local split = {}
  for _, key in ipairs({ "me", "cdx", "pair" }) do
    local share = r.by_actor[key]
    if share.n > 0 then
      split[#split + 1] = ("%s %s d"):format(key, M.fmt_days(share.days))
    end
  end
  if r.by_actor.none.n > 0 then
    split[#split + 1] = ("unclear %d"):format(r.by_actor.none.n)
  end
  if #split > 0 then
    parts[#parts + 1] = table.concat(split, " / ")
  end
  if r.progress and r.progress.total_days > 0 then
    parts[#parts + 1] = ("%d%% done (%s of %s d)"):format(
      r.progress.pct,
      M.fmt_days(r.progress.done_days),
      M.fmt_days(r.progress.total_days)
    )
  end
  return table.concat(parts, " \194\183 ") .. " -- " .. M.CAVEAT
end

return M
