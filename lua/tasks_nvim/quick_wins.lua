---@module 'tasks_nvim.quick_wins'
---@brief The quick-win report, pure: tasks in, a report table or text out.
---@description
--- A quick win is a task with BOTH numbers written, a value at the threshold or above and an effort at the threshold
--- or below (`estimate.is_quick_win`, thresholds from `setup({ quick_wins = {...} })`). This module only groups and
--- renders; the rule lives in `estimate`, so every place that names quick wins agrees.
---
--- Next to the quick wins it names what the rule cannot see, never as a quick win:
---  - `small_unrated`: a small effort but no value -- one number away from being a candidate;
---  - `valuable_unsized`: a high value but no (valid) effort.
---
--- Every cell that comes from a task file goes through `fsio.md_cell` / `fsio.clean`: a title is data, not markup.
---
--- Only `write` touches the disk (the `--report=<file>` of both front ends: one rule for what may be replaced).
---
--- Not its job: finding the tasks (`scan`), showing a window (`ui`).

local estimate = require("tasks_nvim.estimate")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")

local M = {}

---@class Tasks.QuickWinReport
---@field thresholds Tasks.QuickWinThresholds
---@field n integer                     # Tasks the report looked at.
---@field wins Tasks.Task[]             # Best return on effort first.
---@field small_unrated Tasks.Task[]    # Small effort, no value.
---@field valuable_unsized Tasks.Task[] # High value, no (valid) effort.

---@class Tasks.QuickWinTextOpts
---@field title? string      # Names the scope ("lib.nvim", "all areas").
---@field by_actor? boolean  # Split the quick wins into me / pair / cdx / unclear.
---@field paths? boolean     # A column with the absolute path of each task file.
---@field block? boolean     # Not used by `tsv` / `ids`; for `markdown`: no generated-comment.

---@param tasks Tasks.Task[]
---@param th? Tasks.QuickWinThresholds
---@return Tasks.QuickWinReport
function M.build(tasks, th)
  th = th or estimate.thresholds()
  ---@type Tasks.QuickWinReport
  local r = { thresholds = th, n = #tasks, wins = {}, small_unrated = {}, valuable_unsized = {} }
  for _, t in ipairs(tasks) do
    local days = model.effort_days(t.effort)
    if estimate.is_quick_win(t, th) then
      r.wins[#r.wins + 1] = t
    elseif days ~= nil and days <= th.days and t.value == nil then
      r.small_unrated[#r.small_unrated + 1] = t
    elseif days == nil and t.value ~= nil and t.value >= th.value then
      r.valuable_unsized[#r.valuable_unsized + 1] = t
    end
  end
  table.sort(r.wins, model.compare_roi)
  table.sort(r.small_unrated, model.compare)
  table.sort(r.valuable_unsized, model.compare)
  return r
end

---@param n number|nil
---@return string
local function fmt_roi(n)
  return n and ("%.1f"):format(n) or "-"
end

---@param t Tasks.Task
---@return string
local function actor_of(t)
  return model.actor(t) or "-"
end

---Tab-separated lines of the quick wins: `id prio effort value roi actor title` (no header; a script reads them).
---@param report Tasks.QuickWinReport
---@return string[]
function M.tsv(report)
  local out = {}
  for _, t in ipairs(report.wins) do
    out[#out + 1] = table.concat({
      fsio.clean(t.id),
      tostring(t.prio or "-"),
      t.effort or "-",
      tostring(t.value or "-"),
      fmt_roi(model.roi(t)),
      actor_of(t),
      fsio.clean(t.title),
    }, "\t")
  end
  return out
end

---The ids of the quick wins, best first.
---@param report Tasks.QuickWinReport
---@return string[]
function M.ids(report)
  local out = {}
  for _, t in ipairs(report.wins) do
    out[#out + 1] = fsio.clean(t.id)
  end
  return out
end

---@param lines string[]
---@param tasks Tasks.Task[]
---@param opts Tasks.QuickWinTextOpts
local function table_of(lines, tasks, opts, with_numbers)
  local head = { "#", "Task", "Prio", "Effort", "Value", "ROI", "Actor", "Title" }
  if not with_numbers then
    head = { "Task", "Prio", "Effort", "Value", "Title" }
  end
  if opts.paths then
    head[#head + 1] = "File"
  end
  lines[#lines + 1] = "| " .. table.concat(head, " | ") .. " |"
  lines[#lines + 1] = "|" .. string.rep(" --- |", #head)
  for i, t in ipairs(tasks) do
    local cells
    if with_numbers then
      cells = {
        tostring(i),
        fsio.md_cell(t.id),
        t.prio and ("P" .. t.prio) or "-",
        t.effort or "-",
        tostring(t.value or "-"),
        fmt_roi(model.roi(t)),
        actor_of(t),
        fsio.md_cell(t.title),
      }
    else
      cells = {
        fsio.md_cell(t.id),
        t.prio and ("P" .. t.prio) or "-",
        t.effort or "-",
        tostring(t.value or "-"),
        fsio.md_cell(t.title),
      }
    end
    if opts.paths then
      cells[#cells + 1] = "`" .. fsio.clean(t.path):gsub("`", "") .. "`"
    end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  lines[#lines + 1] = ""
end

local ACTOR_ORDER = { "me", "pair", "cdx", "-" }
local ACTOR_LABEL =
  { me = "for me", pair = "pair", cdx = "for an AI session", ["-"] = "unclassified" }

---The report as Markdown.
---@param report Tasks.QuickWinReport
---@param opts? Tasks.QuickWinTextOpts
---@return string
function M.markdown(report, opts)
  opts = opts or {}
  local th = report.thresholds
  local lines = {}
  if not opts.block then
    lines[#lines + 1] = "<!-- GENERATED by `tasks quickwins` -- do not edit -->"
    lines[#lines + 1] = "# Quick wins" .. (opts.title and (" -- " .. fsio.clean(opts.title)) or "")
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = ("A quick win has a value of %d or more and an effort of %s or less, both written on the task. %d of %d tasks."):format(
    th.value,
    th.effort,
    #report.wins,
    report.n
  )
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("## Quick wins (%d)"):format(#report.wins)
  lines[#lines + 1] = ""
  if #report.wins == 0 then
    lines[#lines + 1] = "_none_"
    lines[#lines + 1] = ""
  elseif opts.by_actor then
    local groups = {}
    for _, t in ipairs(report.wins) do
      local a = actor_of(t)
      groups[a] = groups[a] or {}
      table.insert(groups[a], t)
    end
    for _, a in ipairs(ACTOR_ORDER) do
      if groups[a] then
        lines[#lines + 1] = ("### %s (%d)"):format(ACTOR_LABEL[a], #groups[a])
        lines[#lines + 1] = ""
        table_of(lines, groups[a], opts, true)
      end
    end
  else
    table_of(lines, report.wins, opts, true)
  end
  if #report.small_unrated > 0 then
    lines[#lines + 1] = ("## Small, but no value yet (%d)"):format(#report.small_unrated)
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      "One number away from a candidate: give them a value (`tasks set <id> value=N`) and they show up above."
    lines[#lines + 1] = ""
    table_of(lines, report.small_unrated, opts, false)
  end
  if #report.valuable_unsized > 0 then
    lines[#lines + 1] = ("## Valuable, but no effort yet (%d)"):format(#report.valuable_unsized)
    lines[#lines + 1] = ""
    table_of(lines, report.valuable_unsized, opts, false)
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n") .. "\n"
end

---Write the report Markdown. An existing file is replaced only when an earlier run generated it (its text says so):
---a hand-written document at that path is never overwritten.
---@param path string  As the user typed it (`~` and `$VAR` are expanded).
---@param text string
---@return boolean ok
---@return string target  The absolute path, or the reason when not ok.
function M.write(path, text)
  local target = fsio.doc_path(path)
  local existing = fsio.read(target)
  if existing and not existing:find("GENERATED by `tasks quickwins`", 1, true) then
    return false,
      ("%s exists and was not generated by `tasks quickwins`; refusing to overwrite it"):format(
        target
      )
  end
  local ok, err = fsio.write_atomic(target, text, { follow_symlinks = true })
  if not ok then
    return false, ("cannot write %s: %s"):format(target, tostring(err))
  end
  return true, target
end

return M
