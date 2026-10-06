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

local estimate = require("tasks_nvim.estimate")
local filter_opts = require("tasks_nvim.filter_opts")
local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")
local plan_scope = require("tasks_nvim.plan_scope")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

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
  "value",
  "actor",
  "tag",
  "blocked",
  "unestimated",
  "stale-refs",
  "readiness",
  "plan",
  "phase",
}

---Highlight group per severity.
---@type table<string, string>
M.SEVERITY_HL = {
  low = "Comment",
  medium = "DiagnosticHint",
  high = "DiagnosticWarn",
  critical = "DiagnosticError",
}

---Highlight group per actor.
---@type table<string, string>
M.ACTOR_HL = { cdx = "DiagnosticInfo", me = "DiagnosticWarn", pair = "DiagnosticHint" }

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
---@field open? integer        # Open tasks before the filter (absent in a re-sort of what is on screen).
---@field skipped? integer     # Task files not listed (done, missing or unknown status).
---@field errors string[]      # Directories that could not be read.
---@field stale_report? Tasks.StalenessReport  # With `--stale=refs`: what the check found and what it could not.
---@field readiness? Tasks.DashReadiness       # Where each task stands: judged from the SAME scan as the list.
---@field plan? Tasks.Plan                     # The plan of the shown tasks (stages, waits); only with `want_plan`.

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
---@param opts { root: string, area?: string|nil, filter?: Tasks.Filter, sort?: string, scores?: table<string, number>, want_plan?: boolean }
---@return Tasks.DashLoad|nil result
---@return string|nil err
function M.load(opts)
  -- ONE pass over the whole vault: the list (one area, or all) and the readiness of its tasks (a blocker may live in
  -- another area) come from it. Two scans per refresh were what the live refresh cost before.
  if opts.area and not vault.valid_area(opts.area) then
    return nil, "invalid area name: " .. tostring(opts.area)
  end
  local all, scan_errors = scan.all({ root = opts.root })
  if not all then
    return nil, tostring(scan_errors)
  end
  local errors = type(scan_errors) == "table" and scan_errors or {}
  local open, skipped = {}, 0
  for _, t in ipairs(all) do
    if not opts.area or t.area == opts.area then
      if model.is_open_status(t.status) then
        open[#open + 1] = t
      else
        skipped = skipped + 1
      end
    end
  end
  local ran, shared = pcall(plan_scope.shared, opts.root, { all = all, errors = errors })
  if not ran then
    shared = nil
  end
  local filtered, stale_report = model.filter(open, M.with_root(opts.filter, opts.root))
  if opts.filter and opts.filter.readiness and shared then
    filtered = plan_scope.filter_readiness(filtered, opts.filter.readiness, opts.root, shared)
      or filtered
  end
  local tasks = model.sort(filtered, opts.sort, { scores = opts.scores })
  -- The plan is only for the stage view: building it costs a graph walk per soft edge (seconds for a few hundred
  -- tasks per stage), which a list refresh must not pay.
  local built
  if opts.want_plan and shared then
    local built_ok, plan_or_err = pcall(plan.build, tasks, shared.index)
    built = built_ok and plan_or_err or nil
  end
  return {
    tasks = tasks,
    open = #open,
    skipped = skipped,
    errors = errors,
    stale_report = stale_report,
    readiness = shared and M.readiness(tasks, opts.root, shared) or nil,
    plan = built,
  },
    nil
end

-- ── refresh: what changed, where the cursor goes ─────────────────────────────

---Everything a list line shows or the matcher searches, plus the modification
---time of the file (the preview shows its body), per task and in list order,
---joined into one string. Two loads with the same signature render the same
---list, so the dashboard skips the redraw (and keeps its preview) when a
---file-watcher rescan found nothing new.
---What the dashboard knows about the list beyond the files: where every task stands (`plan.classify`, judged
---against every open task of the vault), its OPEN blockers, and the sums of the list.
---@class Tasks.DashReadiness
---@field states table<string, Tasks.PlanState>
---@field open_blockers table<string, string[]>
---@field sums Tasks.Rollup

---Work it out for the shown tasks. Fail-open: when the vault cannot be read the list simply shows no readiness
---(the counts fall back to what the files say), it never breaks the dashboard.
---@param tasks Tasks.Task[]
---@param root? string
---@param shared? Tasks.PlanShared   # The pass over the vault the caller already made (`plan_scope.shared`).
---@return Tasks.DashReadiness|nil
function M.readiness(tasks, root, shared)
  local index = shared and shared.index
  if not index then
    local ok
    ok, index = pcall(plan_scope.index, root)
    if not ok or not index then
      return nil
    end
  end
  local out = { states = {}, open_blockers = {}, sums = estimate.rollup(tasks) }
  for _, t in ipairs(tasks) do
    local state, open = plan.classify(t, index)
    out.states[t.id] = state
    out.open_blockers[t.id] = open
  end
  return out
end

---@param tasks Tasks.Task[]
---@param ready? Tasks.DashReadiness
---@return string
function M.signature(tasks, ready, built)
  local uv = vim.uv or vim.loop
  local out = {}
  for _, t in ipairs(tasks) do
    local st = uv.fs_stat(t.path)
    local node = built and built.nodes[t.id]
    out[#out + 1] = table.concat({
      t.path,
      -- the stage view reads these: a plan file that moves a task to another stage changes no task file
      node and tostring(node.stage) or "",
      M.search_text(t),
      M.blocked_hint(t, ready and ready.open_blockers[t.id]) or "",
      ready and ready.states[t.id] or "",
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

---The `<- blocked_by` hint of a task: the first blocker, `(+n)` for more. With `open` (the blockers that are still
---open) only those count: a blocker that is finished is no reason to wait.
---@param t Tasks.Task
---@param open? string[]
---@return string|nil
function M.blocked_hint(t, open)
  local blockers = open or t.blocked_by
  if #blockers == 0 then
    return nil
  end
  local more = #blockers > 1 and (" (+%d)"):format(#blockers - 1) or ""
  return "\226\134\144 " .. blockers[1] .. more -- "←"
end

---One list line as `{ text, highlight }` chunks: prio, status, effort, area,
---title, blocker hint. The same shape `Snacks.picker` formats return.
---@param t Tasks.Task
---@param w { area: integer, effort: integer, status: integer }
---@param ready? Tasks.DashReadiness
---@return { [1]: string, [2]?: string }[] parts
function M.parts(t, w, ready)
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
  if t.value then
    parts[#parts + 1] = { "  v" .. t.value, "Comment" }
  end
  local actor = model.actor(t)
  if actor then
    parts[#parts + 1] = { "  [" .. actor .. "]", M.ACTOR_HL[actor] or "Comment" }
  end
  local hint = M.blocked_hint(t, ready and ready.open_blockers[t.id])
  if hint then
    parts[#parts + 1] = { "  " .. hint, "Comment" }
  end
  return parts
end

---The plain text of `parts`.
---@param t Tasks.Task
---@param w { area: integer, effort: integer, status: integer }
---@param ready? Tasks.DashReadiness
---@return string
function M.line(t, w, ready)
  local out = {}
  for _, p in ipairs(M.parts(t, w, ready)) do
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
    t.value and ("v%d"):format(t.value) or "",
    model.actor(t) or "",
    table.concat(model.categories(t), " "),
    table.concat(t.tags, " "),
    t.title,
  }, " ")
end

-- ── header and filter chips ──────────────────────────────────────────────────

---@param tasks Tasks.Task[]
---@param ready? Tasks.DashReadiness  Count by the open blockers (and add `ready`); without it by the fields alone.
---@return { open: integer, decision: integer, blocked: integer, ready?: integer }
function M.counts(tasks, ready)
  local c = { open = #tasks, decision = 0, blocked = 0, ready = nil }
  if ready then
    c.ready = 0
  end
  for _, t in ipairs(tasks) do
    if t.status == "decision" then
      c.decision = c.decision + 1
    end
    local state = ready and ready.states[t.id]
    if state then
      -- Judged by the open blockers, not by the field: a task whose blockers are all finished is not blocked
      -- (a status that still says `blocked` is one `check` reports); a `blocked` task with no blocker named is.
      if
        state == "waiting"
        or state == "stuck"
        or (t.status == "blocked" and #t.blocked_by == 0)
      then
        c.blocked = c.blocked + 1
      end
      if state == "ready" or state == "decision" then
        c.ready = (c.ready or 0) + 1
      end
    elseif t.status == "blocked" or #t.blocked_by > 0 then
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
  if f.value_min then
    chips[#chips + 1] = "value: >=" .. f.value_min
  elseif f.value and #f.value > 0 then
    chips[#chips + 1] = "value: " .. joined(f.value)
  end
  if f.actor and #f.actor > 0 then
    chips[#chips + 1] = "actor: " .. joined(f.actor)
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
  if f.unestimated then
    chips[#chips + 1] = "unestimated"
  end
  if f.readiness then
    chips[#chips + 1] = f.readiness
  end
  if f.plan and #f.plan > 0 then
    chips[#chips + 1] = "plan: " .. joined(f.plan)
  end
  if f.phase and #f.phase > 0 then
    chips[#chips + 1] = "phase: " .. joined(f.phase)
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
---@param ready? Tasks.DashReadiness  adds the number of tasks that can be started and the sums of the list
---@return string
function M.header(tasks, f, area, sort, ready)
  local c = M.counts(tasks, ready)
  local head = ("Tasks%s \194\183 %d open \194\183 %d decision \194\183 %d blocked"):format(
    area and (" (" .. area .. ")") or "",
    c.open,
    c.decision,
    c.blocked
  )
  if c.ready then
    head = head .. (" \194\183 %d ready"):format(c.ready)
  end
  if ready and ready.sums.n_with_effort > 0 then
    -- the sum of the SHOWN tasks, always with how many of them it is made of
    head = head
      .. (" \194\183 %s d (%d/%d)"):format(
        estimate.fmt_days(ready.sums.days),
        ready.sums.n_with_effort,
        ready.sums.n
      )
  end
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
  elseif dim == "value" then
    out.value, out.value_min = nil, nil
    if value ~= nil then
      local min = tostring(value):match("^>=(%d)$")
      if min then
        out.value_min = tonumber(min)
      else
        out.value = { model.to_value(value) }
      end
    end
  elseif dim == "blocked" then
    out.blocked = value and true or nil
  elseif dim == "unestimated" then
    out.unestimated = value and true or nil
  elseif dim == "stale-refs" then
    out.stale_refs = value and true or nil
  elseif dim == "readiness" then
    out.readiness = (value == "ready" or value == "waiting") and value or nil
  elseif
    dim == "status"
    or dim == "kind"
    or dim == "category"
    or dim == "severity"
    or dim == "actor"
    or dim == "tag"
    or dim == "plan"
    or dim == "phase"
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
  elseif dim == "value" then
    return { "1", "2", "3", "4", "5", ">=4" }
  elseif dim == "actor" then
    return { "cdx", "me", "pair", "none" }
  elseif dim == "readiness" then
    return { "ready", "waiting" }
  elseif dim == "plan" or dim == "phase" then
    local seen, out = {}, {}
    for _, t in ipairs(tasks) do
      local v = t[dim]
      if v and not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
    table.sort(out)
    return out
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
---between sessions, and what `filter_opts.parse` reads back.
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
  if f.value_min then
    o.value = ">=" .. f.value_min
  elseif f.value and #f.value > 0 then
    o.value = joined(f.value)
  end
  if f.actor and #f.actor > 0 then
    o.actor = joined(f.actor)
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
  if f.unestimated then
    o.unestimated = true
  end
  if f.readiness then
    o.readiness = f.readiness
  end
  if f.plan and #f.plan > 0 then
    o.plan = joined(f.plan)
  end
  if f.phase and #f.phase > 0 then
    o.phase = joined(f.phase)
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
  local f = filter_opts.parse({
    status = type(opts.status) == "string" and opts.status or nil,
    prio = (type(opts.prio) == "string" or type(opts.prio) == "number") and opts.prio or nil,
    effort = type(opts.effort) == "string" and opts.effort or nil,
    kind = type(opts.kind) == "string" and opts.kind or nil,
    tag = type(opts.tag) == "string" and opts.tag or nil,
    category = type(opts.category) == "string" and opts.category or nil,
    severity = type(opts.severity) == "string" and opts.severity or nil,
    value = (type(opts.value) == "string" or type(opts.value) == "number") and opts.value or nil,
    actor = type(opts.actor) == "string" and opts.actor or nil,
    stale = (type(opts.stale) == "string" or type(opts.stale) == "number") and opts.stale or nil,
    stale_refs = opts.stale_refs == true,
    blocked = opts.blocked == true,
    unestimated = opts.unestimated == true,
    plan = type(opts.plan) == "string" and opts.plan or nil,
    phase = type(opts.phase) == "string" and opts.phase or nil,
  })
  if f and (opts.readiness == "ready" or opts.readiness == "waiting") then
    f.readiness = opts.readiness
  end
  return f or {}
end

-- ── the stage view: tasks grouped by stage, reordered with `order` ──────────────

---@class Tasks.DashRow
---@field header? string      # A group heading (no task).
---@field task? Tasks.Task
---@field waits? string       # What the task waits for (open blockers).

---The rows of the stage view, in plan order: a heading per stage ("Stage 1 . 5 tasks . not parallel" when two of them
---name the same file), the tasks of the stage, then the ones the plan puts behind (waiting on a later stage or in a
---cycle) and a last block "unsorted" for tasks without a plan, an edge or anything waiting on them.
---@param built Tasks.Plan
---@return Tasks.DashRow[]
function M.stage_rows(built)
  local groups, order = {}, {}
  local function add(key, title, id)
    if not groups[key] then
      groups[key] = { title = title, ids = {} }
      order[#order + 1] = key
    end
    table.insert(groups[key].ids, id)
  end
  local stage_of = {}
  for i, ids in ipairs(built.stages) do
    for _, id in ipairs(ids) do
      stage_of[id] = i
    end
  end
  local unsorted = {}
  -- a task another task names in `after` has a follower: it is part of the order, not "unsorted"
  local followed = {}
  for _, nid in ipairs(built.ids) do
    for _, a in ipairs(built.nodes[nid].task.after or {}) do
      followed[a] = true
    end
  end
  for _, id in ipairs(built.ids) do
    local node = built.nodes[id]
    local t = node.task
    local lone = not t.plan
      and not followed[id]
      and #(t.blocked_by or {}) == 0
      and #(t.after or {}) == 0
      and node.leverage == 0
      and #node.open_blockers == 0
    if lone then
      unsorted[#unsorted + 1] = id
    elseif stage_of[id] then
      add(stage_of[id], ("Stage %d"):format(stage_of[id] - 1), id)
    else
      add("later", "Behind the stages", id)
    end
  end
  local conflicts = {}
  for _, c in ipairs(built.conflicts) do
    conflicts[c.stage + 1] = true
  end
  local rows = {}
  local function emit(key, title)
    local g = groups[key]
    local head = ("%s \194\183 %d task%s"):format(title, #g.ids, #g.ids == 1 and "" or "s")
    if conflicts[key] then
      head = head .. " \194\183 not parallel"
    end
    rows[#rows + 1] = { header = head }
    for _, id in ipairs(g.ids) do
      local node = built.nodes[id]
      rows[#rows + 1] = {
        task = node.task,
        waits = #node.open_blockers > 0 and table.concat(node.open_blockers, ", ") or nil,
      }
    end
  end
  for _, key in ipairs(order) do
    if key ~= "later" then
      emit(key, groups[key].title)
    end
  end
  if groups.later then
    emit("later", groups.later.title)
  end
  if #unsorted > 0 then
    rows[#rows + 1] =
      { header = ("Unsorted \194\183 %d task%s"):format(#unsorted, #unsorted == 1 and "" or "s") }
    for _, id in ipairs(unsorted) do
      rows[#rows + 1] = { task = built.nodes[id].task }
    end
  end
  return rows
end

---A readable `order` value.
---@param n number
---@return string
local function fmt_order(n)
  return (string.format("%.12g", n))
end

---Move a task one place inside a list of neighbours (`dir` -1 up, +1 down). When the two neighbours it lands between
---have an `order` of their own the task gets a fraction BETWEEN them and nothing else changes. When they do not (the
---usual start: nobody has an `order`), or two orders are equal or too close for a fraction, the group is made
---explicit first: every task of it gets its displayed position as `order`, the moved one and its mate swapped. `order`
---only breaks ties behind status and prio, so the move is visible among tasks of the same status and prio.
---@param list Tasks.Task[]   # The tasks in the order shown (of one group).
---@param id string
---@param dir integer
---@return { id: string, patch: table }[]|nil steps
---@return string|nil why
function M.order_steps(list, id, dir)
  local at
  for i, t in ipairs(list) do
    if t.id == id then
      at = i
    end
  end
  if not at then
    return nil, "not in this group"
  end
  local mate, beyond = list[at + dir], list[at + 2 * dir]
  if not mate then
    return nil, dir < 0 and "already first" or "already last"
  end
  -- the fast path: a fraction between two neighbours that have an order, in the right sequence, with room between
  local value
  if mate.order ~= nil then
    if beyond == nil then
      value = mate.order + dir
    elseif beyond.order ~= nil and (beyond.order - mate.order) * dir > 1e-6 then
      value = (mate.order + beyond.order) / 2
    end
  end
  if value ~= nil then
    return { { id = id, patch = { order = fmt_order(value) } } }, nil
  end
  -- make the group explicit: the displayed position is the order, the task and its mate swapped
  local arranged = vim.deepcopy(list)
  arranged[at], arranged[at + dir] = arranged[at + dir], arranged[at]
  local steps = {}
  for i, t in ipairs(arranged) do
    if t.order ~= i then
      steps[#steps + 1] = { id = t.id, patch = { order = tostring(i) } }
    end
  end
  return steps, nil
end

---Steps that give tasks a plan and a stage (`plan_id` / `phase` nil removes the key).
---@param tasks Tasks.Task[]
---@param plan_id string|nil
---@param phase string|nil
---@return Tasks.BatchSetStep[]
function M.assign_steps(tasks, plan_id, phase)
  local REMOVE = require("tasks_nvim.mutate").REMOVE
  local steps = {}
  for _, t in ipairs(tasks) do
    steps[#steps + 1] = {
      id = t.id,
      patch = { plan = plan_id or REMOVE, phase = phase or REMOVE },
    }
  end
  return steps
end

-- ── cycles and plans ─────────────────────────────────────────────────────────

---@alias Tasks.DashStep Tasks.CycleStep

---The cycles and the plan live in the engine (`model.cycle_status`, `model.cycle_prio`, `batch.plan_cycle`): what an
---`s` / `p` press means is not a property of the picker. These are the dashboard's names for them.
M.cycle_status = model.cycle_status
M.cycle_prio = model.cycle_prio

---Plan an `s` / `p` press (see `batch.plan_cycle`). Pure; nothing is written.
---@param tasks Tasks.Task[]
---@param field "status"|"prio"
---@param count? integer  steps to advance (`3p` is three presses); default 1
---@return Tasks.CycleStep[]
function M.plan_cycle(tasks, field, count)
  return require("tasks_nvim.batch").plan_cycle(tasks, field, count)
end

-- ── applying ─────────────────────────────────────────────────────────────────

---@alias Tasks.DashSetResult Tasks.BatchSetResult

---Run a plan through the engine's batch (`tasks_nvim.batch.set_many`): one write per task, ONE index
---regeneration per area that changed, a failing task does not stop the others. A step planned from a displayed
---value is refused when the task no longer has it.
---@param steps Tasks.BatchSetStep[]
---@param opts { root: string, today?: string }
---@return Tasks.DashSetResult
function M.apply_set(steps, opts)
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
  -- what the done chain did beyond the finish (the same facts `:Tasks done` reports): the steps ticked, the plans
  -- closed, the documents refreshed, and what did not work -- the finish stands, but nobody may be left in the dark
  if (res.steps_ticked or 0) > 0 then
    lines[#lines + 1] = ("%d plan step%s ticked off"):format(
      res.steps_ticked,
      res.steps_ticked == 1 and "" or "s"
    )
  end
  for _, plan_id in ipairs(res.plans_closed or {}) do
    lines[#lines + 1] = "plan " .. plan_id .. " is finished"
  end
  for _, doc in ipairs(res.docs_refreshed or {}) do
    lines[#lines + 1] = "plan block refreshed in " .. doc
  end
  for _, note in ipairs(res.notes or {}) do
    lines[#lines + 1] = note
  end
  local level = "info"
  if #res.failed > 0 or #res.index_errors > 0 then
    level = (#res.done + #res.already == 0) and "error" or "warn"
  elseif #(res.notes or {}) > 0 then
    level = "warn"
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
---@return Tasks.Target|nil target
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
