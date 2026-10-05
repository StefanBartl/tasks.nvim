---@module 'tasks_nvim.ui.dash_core'
---@brief The pure half of the task dashboard: list lines, filter chips, cycles, batch planning and batch apply.
---@description
--- Everything the dashboard (`tasks_dash`) decides without touching a window:
--- how a task becomes a list line, what the header and the filter chips say,
--- how the filter changes, which value `s` / `p` advance a task to, and the
--- batches that write the result through the engine. No picker, no notify, no
--- prompt -- the callers report, so each piece can be specced against a
--- fixture vault.
---
--- Key responsibilities:
---  - `load`: scan, keep the open tasks, filter, sort (same rules as `:Tasks list`,
---    including the `--sort=` orders; `cycle_sort` is the `o` key)
---  - `parts` / `line` / `widths`: one list line as highlighted chunks or plain text
---  - `header` / `chips` / `set_dim` / `dim_choices` / `filter_to_options`: filter state
---  - `cycle_status` / `cycle_prio` / `plan_cycle`: the `s` / `p` mechanic (the
---    `picker.lua` Tab-cycle, with status and prio instead of git actions)
---  - `apply_set` / `apply_done`: run a plan through `tasks.mutate` as ONE batch,
---    regenerating each touched area's index once at the end
---  - `signature` / `relocate`: refresh support -- did a rescan change the list, and where
---    do the cursor and the marks go afterwards (found again by task id)
---  - `EXPORT_CHOICES` / `export_target`: the `e` key's target menu
---
--- Not its job: windows, keys, prompts, notifications (`tasks_dash`), the
--- delivery itself (`tasks_view`), the rules (the engine).

local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")

local M = {}

---Highlight group per status word.
---@type table<string, string>
M.STATUS_HL = {
  doing = "DiagnosticInfo",
  decision = "DiagnosticWarn",
  blocked = "DiagnosticError",
  open = "Normal",
  parked = "Comment",
}

---Highlight group per prio.
---@type table<integer, string>
M.PRIO_HL = { [1] = "DiagnosticError", [2] = "DiagnosticWarn", [3] = "DiagnosticHint" }

---Filter dimensions the `f` key offers, in menu order.
---@type string[]
M.FILTER_DIMS = {
  "status",
  "prio",
  "effort",
  "kind",
  "category",
  "severity",
  "tag",
  "blocked",
  "stale-refs",
}

---Highlight group per severity.
---@type table<string, string>
M.SEVERITY_HL = {
  low = "Comment",
  medium = "DiagnosticHint",
  high = "DiagnosticWarn",
  critical = "DiagnosticError",
}

---What the `effort` entry of the `f` menu offers: the sizes, then "this or smaller".
---@type string[]
M.EFFORT_CHOICES = { "XS", "S", "M", "L", "XL", "<=S", "<=M" }

---The label of the menu entries that clear things.
M.CLEAR = "(any)"
M.CLEAR_ALL = "(clear all filters)"

---@param s string
---@param width integer
---@return string
local function pad(s, width)
  local missing = width - vim.fn.strdisplaywidth(s)
  return missing > 0 and (s .. string.rep(" ", missing)) or s
end

-- ── loading ──────────────────────────────────────────────────────────────────

---@class Tasks.DashLoad
---@field tasks Tasks.Task[]   # Open tasks that passed the filter, sorted.
---@field open integer         # Open tasks before the filter.
---@field skipped integer      # Task files not listed (done, missing or unknown status).
---@field errors string[]      # Directories that could not be read.

---A filter whose `stale_refs` lookup knows the vault root (a copy; the stored
---filter stays free of it).
---@param f Tasks.Filter|nil
---@param root string|nil
---@return Tasks.Filter|nil
function M.with_root(f, root)
  if f and f.stale_refs and root then
    return vim.tbl_extend("keep", { ref_opts = { root = root } }, f)
  end
  return f
end

---Scan, keep the open tasks, filter and sort -- what `:Tasks list` shows.
---@param opts { root: string, area?: string|nil, filter?: Tasks.Filter, sort?: string, scores?: table<string, number> }
---@return Tasks.DashLoad|nil result
---@return string|nil err
function M.load(opts)
  local open, skipped, errors = scan.open_tasks({ root = opts.root, area = opts.area })
  if not open then
    return nil, tostring(skipped)
  end
  local filtered, stale_report = model.filter(open, M.with_root(opts.filter, opts.root))
  return {
    tasks = model.sort(filtered, opts.sort, { scores = opts.scores }),
    open = #open,
    skipped = skipped,
    errors = errors,
    stale_report = stale_report,
  },
    nil
end

-- ── refresh: what changed, where the cursor goes ─────────────────────────────

---Everything a list line shows or the matcher searches, plus the modification
---time of the file (the preview shows its body), per task and in list order,
---joined into one string. Two loads with the same signature render the same
---list, so the dashboard skips the redraw (and keeps its preview) when a
---file-watcher rescan found nothing new.
---@param tasks Tasks.Task[]
---@return string
function M.signature(tasks)
  local uv = vim.uv or vim.loop
  local out = {}
  for _, t in ipairs(tasks) do
    local st = uv.fs_stat(t.path)
    out[#out + 1] = table.concat({
      t.path,
      M.search_text(t),
      M.blocked_hint(t) or "",
      st and ("%d.%d"):format(st.mtime.sec, st.mtime.nsec) or "?",
    }, "\t")
  end
  return table.concat(out, "\n")
end

---Where the cursor and the marks go after the list was rebuilt: found again by
---task id, not by line number, so a rescan that moved or dropped rows leaves the
---selection on the same tasks. A task that is gone is simply not restored.
---@param ids string[]       # The ids of the new list, top to bottom.
---@param cursor_id string|nil
---@param marked_ids string[]
---@return { cursor: integer|nil, marked: integer[] } plan  # 1-based positions in `ids`
function M.relocate(ids, cursor_id, marked_ids)
  local pos = {}
  for i, id in ipairs(ids) do
    pos[id] = i
  end
  local marked = {}
  for _, id in ipairs(marked_ids) do
    if pos[id] then
      marked[#marked + 1] = pos[id]
    end
  end
  table.sort(marked)
  return { cursor = cursor_id and pos[cursor_id] or nil, marked = marked }
end

-- ── list lines ───────────────────────────────────────────────────────────────

---Column widths for a list: the longest area name, the longest effort.
---@param tasks Tasks.Task[]
---@return { area: integer, effort: integer, status: integer }
function M.widths(tasks)
  local w = { area = 4, effort = 1, status = 0 }
  for _, s in ipairs(model.STATUSES) do
    w.status = math.max(w.status, #s)
  end
  for _, t in ipairs(tasks) do
    w.area = math.max(w.area, vim.fn.strdisplaywidth(t.area))
    w.effort = math.max(w.effort, #(t.effort or ""))
  end
  return w
end

---The `<- blocked_by` hint of a task: the first blocker, `(+n)` for more.
---@param t Tasks.Task
---@return string|nil
function M.blocked_hint(t)
  if #t.blocked_by == 0 then
    return nil
  end
  local more = #t.blocked_by > 1 and (" (+%d)"):format(#t.blocked_by - 1) or ""
  return "\226\134\144 " .. t.blocked_by[1] .. more -- "←"
end

---One list line as `{ text, highlight }` chunks: prio, status, effort, area,
---title, blocker hint. The same shape `Snacks.picker` formats return.
---@param t Tasks.Task
---@param w { area: integer, effort: integer, status: integer }
---@return { [1]: string, [2]?: string }[] parts
function M.parts(t, w)
  local parts = {
    { t.prio and ("P%d"):format(t.prio) or "--", M.PRIO_HL[t.prio or 0] or "Comment" },
    { " " },
    { pad(t.status or "?", w.status), M.STATUS_HL[t.status or ""] or "Comment" },
    { " " },
    { pad(t.effort or "-", w.effort), "Comment" },
    { " " },
    { pad(t.area, w.area), "Directory" },
    { " " },
    { t.title },
  }
  if t.severity then
    parts[#parts + 1] = { "  [" .. t.severity .. "]", M.SEVERITY_HL[t.severity] or "Comment" }
  end
  local hint = M.blocked_hint(t)
  if hint then
    parts[#parts + 1] = { "  " .. hint, "Comment" }
  end
  return parts
end

---The plain text of `parts`.
---@param t Tasks.Task
---@param w { area: integer, effort: integer, status: integer }
---@return string
function M.line(t, w)
  local out = {}
  for _, p in ipairs(M.parts(t, w)) do
    out[#out + 1] = p[1]
  end
  return table.concat(out)
end

---What the picker's matcher searches: everything a line shows, plus the id and tags.
---@param t Tasks.Task
---@return string
function M.search_text(t)
  return table.concat({
    t.id,
    t.prio and ("P%d"):format(t.prio) or "",
    t.status or "",
    t.effort or "",
    t.kind or "",
    t.severity or "",
    table.concat(model.categories(t), " "),
    table.concat(t.tags, " "),
    t.title,
  }, " ")
end

-- ── header and filter chips ──────────────────────────────────────────────────

---@param tasks Tasks.Task[]
---@return { open: integer, decision: integer, blocked: integer }
function M.counts(tasks)
  local c = { open = #tasks, decision = 0, blocked = 0 }
  for _, t in ipairs(tasks) do
    if t.status == "decision" then
      c.decision = c.decision + 1
    end
    if t.status == "blocked" or #t.blocked_by > 0 then
      c.blocked = c.blocked + 1
    end
  end
  return c
end

---@param v string|string[]|integer|integer[]
---@return string
local function joined(v)
  if type(v) == "table" then
    local out = {}
    for _, x in ipairs(v) do
      out[#out + 1] = tostring(x)
    end
    return table.concat(out, ",")
  end
  return tostring(v)
end

---The chip of a non-default sort order (`sort: prio-effort`), nil for the default.
---@param sort string|nil
---@return string|nil
function M.sort_chip(sort)
  if sort == nil or sort == "default" or not vim.tbl_contains(model.SORTS, sort) then
    return nil
  end
  return "sort: " .. sort
end

---A stored sort word back; anything that is no longer a sort order is the default.
---@param value any
---@return string
function M.sort_from_stored(value)
  local order = model.parse_sort(value)
  return order or "default"
end

---The next sort order after `cur`, wrapping around (`o` key); an unknown or
---missing one counts as the default and so moves on to the second.
---@param cur string|nil
---@return string
function M.cycle_sort(cur)
  for i, s in ipairs(model.SORTS) do
    if s == (cur or "default") then
      return model.SORTS[i % #model.SORTS + 1]
    end
  end
  return model.SORTS[2]
end

---One chip per active filter dimension, in a fixed order.
---@param f Tasks.Filter|nil
---@return string[] chips
function M.chips(f)
  f = f or {}
  local chips = {}
  if f.status and #f.status > 0 then
    chips[#chips + 1] = "status: " .. joined(f.status)
  end
  if f.prio_max then
    chips[#chips + 1] = "prio: <=" .. f.prio_max
  elseif f.prio and #f.prio > 0 then
    chips[#chips + 1] = "prio: " .. joined(f.prio)
  end
  if f.effort_max then
    chips[#chips + 1] = "effort: <=" .. f.effort_max
  elseif f.effort and #f.effort > 0 then
    chips[#chips + 1] = "effort: " .. joined(f.effort)
  end
  if f.kind and #f.kind > 0 then
    chips[#chips + 1] = "kind: " .. joined(f.kind)
  end
  if f.category and #f.category > 0 then
    chips[#chips + 1] = "category: " .. joined(f.category)
  end
  if f.severity and #f.severity > 0 then
    chips[#chips + 1] = "severity: " .. joined(f.severity)
  end
  if f.tag and #f.tag > 0 then
    chips[#chips + 1] = "tag: " .. joined(f.tag)
  end
  if f.stale then
    chips[#chips + 1] = ("stale: >=%dd"):format(f.stale)
  end
  if f.stale_refs then
    chips[#chips + 1] = "stale: refs"
  end
  if f.blocked then
    chips[#chips + 1] = "blocked"
  end
  return chips
end

---@param f Tasks.Filter|nil
---@return boolean
function M.filter_is_empty(f)
  return #M.chips(f) == 0
end

---`Tasks (lib.nvim) · 41 open · 3 decision · 5 blocked  [status: open] [prio: <=2] [sort: prio-effort]`
---@param tasks Tasks.Task[]  the shown (filtered) tasks
---@param f Tasks.Filter|nil
---@param area string|nil
---@param sort string|nil  a non-default order adds a chip
---@return string
function M.header(tasks, f, area, sort)
  local c = M.counts(tasks)
  local head = ("Tasks%s \194\183 %d open \194\183 %d decision \194\183 %d blocked"):format(
    area and (" (" .. area .. ")") or "",
    c.open,
    c.decision,
    c.blocked
  )
  local chips = M.chips(f)
  local sort_chip = M.sort_chip(sort)
  if sort_chip then
    chips[#chips + 1] = sort_chip
  end
  if #chips == 0 then
    return head
  end
  local out = {}
  for _, chip in ipairs(chips) do
    out[#out + 1] = "[" .. chip .. "]"
  end
  return head .. "  " .. table.concat(out, " ")
end

---Copy of a filter with one dimension replaced (`value == nil` clears it).
---`prio` takes `1`, `2`, `3` or `<=N`, `effort` a size / day value or `<=<size>`;
---`blocked` takes `true`/`nil`.
---@param f Tasks.Filter|nil
---@param dim string
---@param value string|boolean|nil
---@return Tasks.Filter
function M.set_dim(f, dim, value)
  local out = vim.deepcopy(f or {})
  if dim == "prio" then
    out.prio, out.prio_max = nil, nil
    if value ~= nil then
      local max = tostring(value):match("^<=(%d)$")
      if max then
        out.prio_max = tonumber(max)
      else
        out.prio = { model.to_prio(value) }
      end
    end
  elseif dim == "effort" then
    out.effort, out.effort_max = nil, nil
    if value ~= nil then
      local max = tostring(value):match("^<=(.+)$")
      if max then
        out.effort_max = max
      else
        out.effort = { tostring(value) }
      end
    end
  elseif dim == "blocked" then
    out.blocked = value and true or nil
  elseif dim == "stale-refs" then
    out.stale_refs = value and true or nil
  elseif
    dim == "status"
    or dim == "kind"
    or dim == "category"
    or dim == "severity"
    or dim == "tag"
  then
    out[dim] = value ~= nil and { tostring(value) } or nil
  end
  return out
end

---The values the `f` menu offers for a dimension (without the clearing entry).
---@param dim string
---@param tasks Tasks.Task[]  open tasks of the scope, unfiltered (for the tags)
---@return string[]
function M.dim_choices(dim, tasks)
  if dim == "status" then
    return vim.deepcopy(model.OPEN_STATUSES)
  elseif dim == "prio" then
    return { "1", "2", "3", "<=2" }
  elseif dim == "kind" then
    return vim.deepcopy(model.KINDS)
  elseif dim == "category" then
    return vim.deepcopy(model.CATEGORIES)
  elseif dim == "effort" then
    return vim.deepcopy(M.EFFORT_CHOICES)
  elseif dim == "severity" then
    return vim.deepcopy(model.SEVERITIES)
  elseif dim == "tag" then
    local seen, out = {}, {}
    for _, t in ipairs(tasks) do
      for _, tag in ipairs(t.tags) do
        if not seen[tag] then
          seen[tag] = true
          out[#out + 1] = tag
        end
      end
    end
    table.sort(out)
    return out
  end
  return {}
end

---The textual options (`--status=` ... form) of a filter: what is stored
---between sessions, and what `model.filter_from_options` reads back.
---@param f Tasks.Filter|nil
---@return table<string, string|boolean|integer>
function M.filter_to_options(f)
  f = f or {}
  local o = {}
  if f.status and #f.status > 0 then
    o.status = joined(f.status)
  end
  if f.prio_max then
    o.prio = "<=" .. f.prio_max
  elseif f.prio and #f.prio > 0 then
    o.prio = joined(f.prio)
  end
  if f.effort_max then
    o.effort = "<=" .. f.effort_max
  elseif f.effort and #f.effort > 0 then
    o.effort = joined(f.effort)
  end
  if f.kind and #f.kind > 0 then
    o.kind = joined(f.kind)
  end
  if f.category and #f.category > 0 then
    o.category = joined(f.category)
  end
  if f.severity and #f.severity > 0 then
    o.severity = joined(f.severity)
  end
  if f.tag and #f.tag > 0 then
    o.tag = joined(f.tag)
  end
  if f.stale then
    o.stale = f.stale
  end
  if f.stale_refs then
    o.stale_refs = true
  end
  if f.blocked then
    o.blocked = true
  end
  return o
end

---Read stored options back. Anything that no longer parses (a status word
---that was dropped) gives an empty filter, never an error.
---@param opts any
---@return Tasks.Filter
function M.filter_from_stored(opts)
  if type(opts) ~= "table" then
    return {}
  end
  local f = model.filter_from_options({
    status = type(opts.status) == "string" and opts.status or nil,
    prio = (type(opts.prio) == "string" or type(opts.prio) == "number") and opts.prio or nil,
    effort = type(opts.effort) == "string" and opts.effort or nil,
    kind = type(opts.kind) == "string" and opts.kind or nil,
    tag = type(opts.tag) == "string" and opts.tag or nil,
    category = type(opts.category) == "string" and opts.category or nil,
    severity = type(opts.severity) == "string" and opts.severity or nil,
    stale = (type(opts.stale) == "string" or type(opts.stale) == "number") and opts.stale or nil,
    stale_refs = opts.stale_refs == true,
    blocked = opts.blocked == true,
  })
  return f or {}
end

-- ── cycles and plans ─────────────────────────────────────────────────────────

---The next open status after `cur`, wrapping around; an unknown or missing
---status starts at the first.
---@param cur string|nil
---@return string
function M.cycle_status(cur)
  for i, s in ipairs(model.OPEN_STATUSES) do
    if s == cur then
      return model.OPEN_STATUSES[i % #model.OPEN_STATUSES + 1]
    end
  end
  return model.OPEN_STATUSES[1]
end

---The next prio after `cur`: none -> 1 -> 2 -> 3 -> none (`nil` = remove the key).
---@param cur integer|nil
---@return integer|nil
function M.cycle_prio(cur)
  if cur == nil then
    return model.PRIOS[1]
  end
  for i, p in ipairs(model.PRIOS) do
    if p == cur then
      return model.PRIOS[i + 1]
    end
  end
  return model.PRIOS[1]
end

---@class Tasks.DashStep
---@field id string
---@field field "status"|"prio"
---@field from string|integer|nil
---@field to string|integer|nil   # nil: the key is removed.
---@field checked? boolean         # Planned from a displayed value: `apply_set` re-reads it before writing.
---@field patch table<string, any>

---Plan an `s` / `p` press: every task advances from ITS OWN current value, so
---a mixed selection stays mixed (the same rule as the per-row cycle in
---`picker.lua`). Pure; nothing is written.
---@param tasks Tasks.Task[]
---@param field "status"|"prio"
---@param count? integer  steps to advance (`3p` is three presses); default 1
---@return Tasks.DashStep[]
function M.plan_cycle(tasks, field, count)
  local plan = {}
  local steps = math.max(1, count or 1)
  for _, t in ipairs(tasks) do
    local from, to
    if field == "status" then
      from = t.status
      to = from
      for _ = 1, steps do
        to = M.cycle_status(to)
      end
    else
      from = t.prio
      to = from
      for _ = 1, steps do
        to = M.cycle_prio(to)
      end
    end
    plan[#plan + 1] = {
      id = t.id,
      field = field,
      from = from,
      to = to,
      checked = true,
      patch = { [field] = to == nil and mutate.REMOVE or to },
    }
  end
  return plan
end

-- ── applying ─────────────────────────────────────────────────────────────────

---@alias Tasks.DashSetResult Tasks.BatchSetResult

---Run a cycle plan through the engine's batch (`tasks_nvim.batch.set_many`): one write per task, ONE index
---regeneration per area that changed, a failing task does not stop the others. A step planned from a displayed
---value is refused when the task no longer has it.
---@param plan Tasks.DashStep[]
---@param opts { root: string, today?: string }
---@return Tasks.DashSetResult
function M.apply_set(plan, opts)
  local steps = {}
  for _, step in ipairs(plan) do
    steps[#steps + 1] = {
      id = step.id,
      patch = step.patch,
      expect = step.checked and { key = step.field, value = step.from } or nil,
    }
  end
  return require("tasks_nvim.batch").set_many(steps, opts)
end

---One summary for the whole batch: the level and the text (first line the
---counts, then one line per failure / index problem).
---@param field string
---@param res Tasks.DashSetResult
---@return "info"|"warn"|"error" level
---@return string text
function M.describe_set(field, res)
  local lines = {
    ("%s: %d changed, %d unchanged, %d failed (%d index%s regenerated)"):format(
      field,
      #res.changed,
      #res.unchanged,
      #res.failed,
      #res.areas,
      #res.areas == 1 and "" or "es"
    ),
  }
  for _, f in ipairs(res.failed) do
    lines[#lines + 1] = ("%s: %s"):format(f.id, f.err)
  end
  for _, e in ipairs(res.index_errors) do
    lines[#lines + 1] = "index " .. e
  end
  local level = "info"
  if #res.failed > 0 or #res.index_errors > 0 then
    level = (#res.changed + #res.unchanged == 0) and "error" or "warn"
  end
  return level, table.concat(lines, "\n")
end

---@alias Tasks.DashDoneResult Tasks.BatchDoneResult

---Finish tasks (rule R6) through the engine's batch (`tasks_nvim.batch.done_many`).
---@param ids string[]
---@param opts { root: string, today?: string, date?: string }
---@return Tasks.DashDoneResult
function M.apply_done(ids, opts)
  return require("tasks_nvim.batch").done_many(ids, opts)
end

---@param res Tasks.DashDoneResult
---@return "info"|"warn"|"error" level
---@return string text
function M.describe_done(res)
  local lines = {
    ("done: %d finished, %d already finished, %d failed (%d index%s regenerated)"):format(
      #res.done,
      #res.already,
      #res.failed,
      #res.areas,
      #res.areas == 1 and "" or "es"
    ),
  }
  for _, f in ipairs(res.failed) do
    lines[#lines + 1] = ("%s: %s"):format(f.id, f.err)
  end
  for _, d in ipairs(res.done) do
    if d.readme == "missing" then
      lines[#lines + 1] = d.id .. ": Backlog/README.md does not exist, no row added"
    end
  end
  for _, e in ipairs(res.index_errors) do
    lines[#lines + 1] = "index " .. e
  end
  local level = "info"
  if #res.failed > 0 or #res.index_errors > 0 then
    level = (#res.done + #res.already == 0) and "error" or "warn"
  end
  return level, table.concat(lines, "\n")
end

-- ── export ───────────────────────────────────────────────────────────────────

---@class Tasks.DashExport
---@field label string
---@field to "buffer"|"clipboard"|"qf"|"file"|"mdview"
---@field format? "md"|"csv"
---@field ask_path? boolean

---The targets of the `e` key: the sinks `--to=` knows.
---@type Tasks.DashExport[]
M.EXPORT_CHOICES = {
  { label = "Scratch buffer (Markdown)", to = "buffer", format = "md" },
  { label = "Clipboard (Markdown)", to = "clipboard", format = "md" },
  { label = "Quickfix list", to = "qf" },
  { label = "File ... (Markdown)", to = "file", format = "md", ask_path = true },
  { label = "Clipboard (CSV)", to = "clipboard", format = "csv" },
  { label = "File ... (CSV)", to = "file", format = "csv", ask_path = true },
  -- Last, so the positions the other entries have stay as they were.
  { label = "Preview in browser (mdview)", to = "mdview", format = "md" },
}

---Turn a menu choice (and the path the user typed, for a file) into what
---`tasks_view.deliver` takes.
---@param choice Tasks.DashExport
---@param path? string
---@return { kind: string, path?: string }|nil target
---@return string|nil err
function M.export_target(choice, path)
  if choice.to == "file" then
    local p = vim.trim(path or "")
    if p == "" then
      return nil, "no file path given"
    end
    return { kind = "file", path = p }, nil
  end
  return { kind = choice.to }, nil
end

return M
