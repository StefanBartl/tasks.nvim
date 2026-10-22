---@module 'tasks_nvim.contract'
---@brief The read side of the machine contract `tasks-export/1`: the documents an app, an agent or CI reads.
---@description
--- One Lua table per document kind, built from what the engine already knows (`scan`, `plan`, `next_pick`, `model`,
--- `estimate`), never from a second reading of the files; `encode` turns a document into its canonical bytes
--- (`lib.nvim.json.canonical`). The contract is versioned (`schema: 1`), only ever grows inside a version, and is described by
--- the JSON Schemas in `schemas/tasks-export/1/`. The Markdown files stay the single source of truth.
---
--- Documents (`kind`): `tasks.hello`, `tasks.snapshot`, `tasks.list`, `tasks.task`, `tasks.next`, `tasks.areas`, `tasks.finished`, `tasks.links`, `tasks.groupings`, `tasks.views`,
--- `tasks.error`. Every one starts with the same head (`schema`, `plugin`, `kind`, `generated_at`, `vault.id`,
--- `engine`); a document that comes from a scan also carries `rev` (what the vault looked like) and `digest` (the hash
--- of the content: without `generated_at` and `engine`, so two runs on an unchanged vault have the same digest).
---
--- Rules the documents keep:
---  - **no path of this machine**: a file is `<area>/ROADMAP/tasks/<slug>.md`, relative to the vault; an absolute
---    `refs:` entry shows as `<external>/<name>`, and the vault root inside a message is `<vault>`;
---  - **missing means unknown, never 0**: a task without an effort has no `effort_days` and no `roi`;
---  - **a broken task is still there** (`valid: false`, `problems`), it does not vanish from the list;
---  - **a document is at most 8 MiB**; a bigger one is the error `payload_too_large`, not a cut-off document;
---  - an empty container is `[]` or `{}` as its kind says (`lib.nvim.json.canonical`), never the other.
---
--- Only reads: nothing here changes a file. Not its job: parsing a request, mapping an error to a code (`api`), the
--- command line (`cli`).

local doc_mod = require("lib.nvim.contract.doc")
local check = require("tasks_nvim.check")
local done_flow = require("tasks_nvim.done_flow")
local error_codes = require("lib.nvim.contract.errors")
local estimate = require("tasks_nvim.estimate")
local fsio = require("tasks_nvim.fsio")
local json = require("lib.nvim.json.canonical")
local links = require("tasks_nvim.links")
local model = require("tasks_nvim.model")
local next_pick = require("tasks_nvim.next_pick")
local plan = require("tasks_nvim.plan")
local plan_scope = require("tasks_nvim.plan_scope")
local scan = require("tasks_nvim.scan")
local staleness = require("tasks_nvim.staleness")
local vault = require("tasks_nvim.vault")

local M = {}

---The version of the contract (`schema` of every document).
M.SCHEMA = 1

M.PLUGIN = "tasks.nvim"

---The engine's own version (not the contract's).
M.ENGINE_VERSION = "0.1.0-dev"

---What this engine can answer; an app shows only what is listed here. Sorted.
---`ops` is the write door (`set`, `new`, `reorder`, `done`, `move_area`, `plan_new`, `tick_step`, `append_note`, `reopen`, `set_body`), `if_match` the compare-and-set on a task's
---`etag`, `done_preview` what `done` needs first, `reorder` a move inside a group, `move_area_preview` the report of a
---move to another area (the move itself is not there yet).
---@type string[]
M.CAPABILITIES = {
  "append_note",
  "areas",
  "bodies",
  "check",
  "done_preview",
  "eff_prio",
  "estimate",
  "etag",
  "finished",
  "groupings",
  "hello",
  "if_match",
  "links",
  "list",
  "lists",
  "move_area",
  "move_area_preview",
  "next",
  "ops",
  "order",
  "plan_for",
  "plan_new",
  "reminders",
  "reopen",
  "reorder",
  "set_body",
  "snapshot",
  "task",
  "tick_step",
  "view_delete",
  "view_save",
  "views",
}

---Sizes the contract promises to keep.
M.LIMITS = { title = 300, summary = 1000, body_bytes = 262144, list_items = 100, batch_ops = 100 }

---The messages of the engine that carry no code of their own, matched before the shared patterns of
---`lib.nvim.contract.errors` (`{ code, find, retryable? }`). The one fragile spot, until every source gives its code.
---@type Lib.Contract.ErrorPattern[]
M.ERROR_PATTERNS = {
  { code = "not_found", find = { "vault not found", "unknown area" } },
  {
    code = "invalid_argument",
    find = { "expected <area>/<slug>", "invalid area name", "nothing to set" },
  },
}

local plugin_root =
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(fsio.norm(debug.getinfo(1, "S").source:sub(2)))))

-- Head, seal, canonical bytes, the 8 MiB limit and the path rules are `lib.nvim.contract.doc`'s; what a document
-- CONTAINS is this module's.
local builder = doc_mod.new({
  plugin = M.PLUGIN,
  schema = M.SCHEMA,
  scope_key = "vault",
  engine_version = M.ENGINE_VERSION,
  plugin_root = plugin_root,
})

-- Seams for specs and golden files: read at call time, so a spec replaces them on this module.
local base_clock, base_engine_info = builder.clock, builder.engine_info
builder.clock = function()
  return M.clock()
end
builder.engine_info = function()
  return M.engine_info()
end

---The time a document is stamped with (UTC, `YYYY-MM-DDTHH:MM:SSZ`). A seam: golden files and reproducible runs set a
---fixed one; nothing else changes it.
---@return string
function M.clock()
  return base_clock()
end

---What the head says about the engine (same seam, same reason).
---@return { version: string, git: string, nvim: string }
function M.engine_info()
  return base_engine_info()
end

---The head every document starts with.
---@type fun(kind: string, root?: string): table
M.head = builder.head

local relative, safe_path, redact, seal =
  builder.relative, builder.safe_path, builder.redact, builder.seal

-- ── small helpers ────────────────────────────────────────────────────────────

---@param n number
---@return number
local function round2(n)
  return math.floor(n * 100 + 0.5) / 100
end

---@param s string
---@param max integer  # characters
---@return string
local function clip(s, max)
  if vim.fn.strchars(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max - 1) .. "\226\128\166"
end

---The version tag of a file's bytes: what a later write compares against.
---@param path string
---@return string|nil
local function etag_of(path)
  if fsio.is_link(path) then
    return nil
  end
  local text = fsio.read(path)
  if not text then
    return nil
  end
  return fsio.etag(text)
end

---The most reminders of finished tasks a snapshot carries (the oldest dates first).
M.REMINDERS_MAX = 100

---The finished tasks that carry a reminder. A task that is done leaves the open list, and a reminder is most often set
---exactly then ("look at the result in a week"): without this the date would be written and never seen again.
---@param root string
---@return table[] reminders  `{ id, area, title, remind, etag, done_in? }`, the oldest date first
---@return string[] errors  folders that were not read (they lead out of the vault), relative to the vault
local function done_reminders(root)
  local out = {}
  local found, _, walk_errors = scan.backlog_reminders({ root = root })
  for _, task in ipairs(found or {}) do
    out[#out + 1] = json.object({
      id = task.id,
      area = task.area,
      title = task.title,
      remind = task.remind,
      etag = etag_of(task.path),
      done_in = task.done_in,
    })
  end
  table.sort(out, function(a, b)
    if a.remind ~= b.remind then
      return a.remind < b.remind
    end
    return a.id < b.id
  end)
  while #out > M.REMINDERS_MAX do
    out[#out] = nil
  end
  local errors = {}
  for _, e in ipairs(walk_errors or {}) do
    errors[#errors + 1] = redact(root, tostring(e))
  end
  return out, errors
end

-- ── entries ──────────────────────────────────────────────────────────────────

---@param root string
---@param task Tasks.Task
---@param node? Tasks.PlanNode
---@param rank? integer
---@return table
local function task_entry(root, task, node, rank)
  local days = model.effort_days(task.effort)
  local roi = model.roi(task)
  local entry = {
    id = task.id,
    area = task.area,
    slug = task.slug,
    title = task.title,
    status = model.is_status(task.status) and task.status or nil,
    kind = model.is_kind(task.kind) and task.kind or nil,
    prio = task.prio,
    order = task.order,
    effort = days and task.effort or nil,
    effort_days = days,
    value = task.value,
    roi = roi and round2(roi) or nil,
    actor = model.actor(task),
    actor_written = task.actor ~= nil and model.is_actor(task.actor) or nil,
    severity = model.is_severity(task.severity) and task.severity or nil,
    created = model.is_date(task.created) and task.created or nil,
    updated = model.is_date(task.updated) and task.updated or nil,
    -- the date only; whether it is due is for the reader to say (a digest does not change with the day)
    remind = model.is_date(task.remind) and task.remind or nil,
    plan = task.plan,
    phase = task.phase,
    done_in = task.done_in,
    -- only when the task lists commits, so a document without them reads as before
    commits = (task.commits and #task.commits > 0) and vim.list_slice(task.commits, 1) or nil,
    tags = vim.list_slice(task.tags or {}, 1),
    category = model.categories(task),
    blocked_by = vim.list_slice(task.blocked_by or {}, 1),
    after = vim.list_slice(task.after or {}, 1),
    refs = vim.tbl_map(function(r)
      return safe_path(root, r)
    end, task.refs or {}),
    summary = clip(task.summary or "", M.LIMITS.summary),
    folder = task.folder,
    file = relative(root, task.path) or vim.fs.basename(task.path),
    valid = task.valid,
    problems = {},
  }
  if task.plan_steps then
    entry.steps = json.object({
      total = task.plan_steps.total,
      ticked = task.plan_steps.ticked,
      dropped = task.plan_steps.dropped,
    })
  end
  for i, msg in ipairs(task.errors or {}) do
    entry.problems[#entry.problems + 1] =
      { code = task.error_codes[i] or "invalid", msg = redact(root, msg) }
  end
  entry.etag = task.etag or etag_of(task.path)
  if node then
    local r = {
      state = node.state,
      stage = node.stage,
      rank = rank,
      eff_prio = node.eff_prio,
      leverage = node.leverage,
      open_blockers = vim.list_slice(node.open_blockers, 1),
    }
    if node.inversion then
      r.inversion = json.object({
        from = node.inversion.from,
        to = node.inversion.to,
        because = node.inversion.because,
      })
    end
    if node.in_cycle then
      r.in_cycle = true
    end
    if #node.same_file > 0 then
      r.same_file = vim.list_slice(node.same_file, 1)
    end
    entry.readiness = json.object(r)
    entry.group = plan.group_key(node)
  end
  return entry
end

---@param t Tasks.Task
---@return table
local function brief(t)
  return { id = t.id, title = t.title, status = t.status, prio = t.prio, effort = t.effort }
end

---@param s string[]|nil
---@return table
local function counts_of(statuses)
  local by = json.object({})
  for _, s in ipairs(statuses) do
    by[s] = (by[s] or 0) + 1
  end
  return by
end

-- ── one pass over the vault ──────────────────────────────────────────────────

---@class Tasks.ContractView
---@field root string
---@field open Tasks.Task[]                 # Open tasks, as the plan sees them.
---@field unlisted { id: string, status: string, code: string }[]
---@field plan Tasks.Plan
---@field files Tasks.PlanFile[]
---@field rank table<string, integer>       # 1-based position in plan order.
---@field errors string[]                   # Folders that could not be read (relative).
---@field all Tasks.Task[]
---@field shared Tasks.PlanShared           # What `plan_scope` read: the readiness filters ask it again.

---Scan the vault once and compute the plan once.
---@param opts? { root?: string }
---@return Tasks.ContractView|nil view
---@return string|nil err
function M.view(opts)
  return fsio.read_scope(function()
    return M.build_view(opts)
  end)
end

---`M.view` without the read scope.
---@param opts? { root?: string }
---@return Tasks.ContractView|nil view
---@return string|nil err
function M.build_view(opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, tostring(rerr)
  end
  local all, errors = scan.all({ root = root })
  if not all then
    return nil, tostring(errors)
  end
  local shared, serr =
    plan_scope.shared(root, { all = all, errors = type(errors) == "table" and errors or {} })
  if not shared then
    return nil, tostring(serr)
  end
  local built = plan.build(shared.open, shared.index)
  local rank = {}
  for i, id in ipairs(built.ids) do
    rank[id] = i
  end
  local unlisted = {}
  for _, t in ipairs(all) do
    if t.location == "roadmap" and not model.is_open_status(t.status) then
      local code = "no-status"
      if t.status == "done" then
        code = "done-in-roadmap"
      elseif type(t.status) == "string" then
        code = "unknown-status"
      end
      unlisted[#unlisted + 1] =
        { id = t.id, status = type(t.status) == "string" and t.status or "", code = code }
    end
  end
  table.sort(unlisted, function(a, b)
    return a.id < b.id
  end)
  local rel_errors = {}
  for _, e in ipairs(shared.errors) do
    rel_errors[#rel_errors + 1] = redact(root, tostring(e))
  end
  return {
    root = root,
    open = shared.open,
    unlisted = unlisted,
    plan = built,
    files = shared.files,
    rank = rank,
    errors = rel_errors,
    all = all,
    shared = shared,
  },
    nil
end

---@param view Tasks.ContractView
---@return table
local function plan_head(view)
  local p = view.plan
  local by_state = { ready = 0, decision = 0, waiting = 0, stuck = 0, freed = 0, parked = 0 }
  for _, node in pairs(p.nodes) do
    if by_state[node.state] ~= nil then
      by_state[node.state] = by_state[node.state] + 1
    end
  end
  local sizes = {}
  for i, ids in ipairs(p.stages) do
    sizes[i] = #ids
  end
  local conflicts = {}
  for _, c in ipairs(p.conflicts) do
    conflicts[#conflicts + 1] =
      { stage = c.stage, file = safe_path(view.root, c.file), ids = vim.list_slice(c.ids, 1) }
  end
  local warnings = {}
  for _, w in ipairs(p.warnings) do
    warnings[#warnings + 1] = { code = w.code, id = w.id, msg = redact(view.root, w.msg) }
  end
  return {
    summary = json.object({
      tasks = #view.open,
      ready = by_state.ready,
      decision = by_state.decision,
      waiting = by_state.waiting,
      stuck = by_state.stuck,
      freed = by_state.freed,
      parked = by_state.parked,
    }),
    critical_path = json.object({
      days = round2(p.critical.days),
      path = vim.list_slice(p.critical.path, 1),
      unknown_effort = p.critical.unknown,
    }),
    stage_sizes = sizes,
    cycles = vim.tbl_map(function(c)
      return vim.list_slice(c, 1)
    end, p.cycles),
    conflict_groups = conflicts,
    warnings = warnings,
  }
end

---@param view Tasks.ContractView
---@return table
local function areas_of(view)
  local by_area = {}
  for _, t in ipairs(view.open) do
    by_area[t.area] = by_area[t.area] or {}
    table.insert(by_area[t.area], t.status)
  end
  local out = {}
  for _, a in ipairs(vault.areas(view.root)) do
    local statuses = by_area[a.name] or {}
    out[#out + 1] = { name = a.name, open = #statuses, by_status = counts_of(statuses) }
  end
  return out
end

---`rev`: what the vault looked like, from every task and plan file by id and version tag.
---@param view Tasks.ContractView
---@param entries table[]
---@return string
local function rev_of(view, entries)
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = e.id .. "\t" .. (e.etag or "")
  end
  for _, f in ipairs(view.files) do
    lines[#lines + 1] = "plan:" .. f.id .. "\t" .. (etag_of(f.path) or "")
  end
  for _, u in ipairs(view.unlisted) do
    lines[#lines + 1] = "unlisted:" .. u.id .. "\t" .. u.status
  end
  return builder.rev_of(lines)
end

M.redact = redact
M.seal = seal
M.relative = relative

-- ── documents ────────────────────────────────────────────────────────────────

---The handshake: what this engine is and can do. Reads no task.
---@param opts? { root?: string }
---@return table doc
function M.hello(opts)
  local root = vault.root(opts)
  local doc = M.head("tasks.hello", root)
  doc.schemas = { M.SCHEMA }
  doc.capabilities = vim.list_slice(M.CAPABILITIES, 1)
  doc.limits = json.object(vim.deepcopy(M.LIMITS))
  local efforts = vim.list_slice(model.EFFORTS, 1)
  efforts[#efforts + 1] = "<n>d"
  doc.enums = json.object({
    status = vim.list_slice(model.OPEN_STATUSES, 1),
    kind = vim.list_slice(model.KINDS, 1),
    prio = vim.list_slice(model.PRIOS, 1),
    value = vim.list_slice(model.VALUES, 1),
    effort = efforts,
    actor = vim.list_slice(model.ACTORS, 1),
    category = vim.list_slice(model.CATEGORIES, 1),
    severity = vim.list_slice(model.SEVERITIES, 1),
  })
  return doc
end

---The primary document: counts, areas, plan head, plans and every open task with its readiness.
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return string|nil err
function M.snapshot(opts)
  return fsio.read_scope(function()
    return M.build_snapshot(opts)
  end)
end

---`M.snapshot` without the read scope.
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return string|nil err
function M.build_snapshot(opts)
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local entries = {}
  local statuses = {}
  -- plan order: the order a person would work in
  local ordered = vim.list_slice(view.open, 1)
  table.sort(ordered, function(a, b)
    return (view.rank[a.id] or math.huge) < (view.rank[b.id] or math.huge)
  end)
  for _, t in ipairs(ordered) do
    entries[#entries + 1] = task_entry(view.root, t, view.plan.nodes[t.id], view.rank[t.id])
    statuses[#statuses + 1] = t.status
  end
  local doc = M.head("tasks.snapshot", view.root)
  doc.counts = json.object({
    listed = #entries,
    unlisted = #view.unlisted,
    by_status = counts_of(statuses),
  })
  doc.areas = areas_of(view)
  doc.unlisted = view.unlisted
  local reminders, reminder_errors = done_reminders(view.root)
  doc.reminders = reminders
  doc.plan = json.object(plan_head(view))
  doc.plans = vim.tbl_map(function(f)
    return {
      id = f.id,
      title = f.title,
      status = f.status,
      areas = vim.list_slice(f.areas, 1),
      target = f.target,
      phase_order = vim.list_slice(f.phase_order, 1),
      gate = f.gate,
      valid = f.valid,
    }
  end, view.files)
  doc.tasks = json.memo(entries)
  doc.incomplete = vim.list_extend(vim.list_slice(view.errors, 1), reminder_errors)
  local sums = estimate.rollup(view.open)
  doc.estimate = json.object({
    tasks = sums.n,
    days = round2(sums.days),
    n_with_effort = sums.n_with_effort,
    n_without_effort = sums.n_without_effort,
    value = sums.value,
    n_with_value = sums.n_with_value,
    roi = sums.roi and round2(sums.roi) or nil,
    quick_wins = vim.list_slice(sums.quick_wins, 1),
    unestimated = vim.list_slice(sums.unestimated, 1),
  })
  return seal(doc, rev_of(view, entries)), nil
end

---The open tasks a `list` or `order` request names, in the order it names: the view, the tasks and the sort word.
---@param params table
---@param opts? { root?: string, view?: Tasks.ContractView, filter?: Tasks.Filter, readiness?: "ready"|"waiting", scores?: table<string, number> }
---@return Tasks.ContractView|nil view
---@return Tasks.Task[]|Tasks.ContractError|string|nil matching  # the error when `view` is nil
---@return string|nil sort
local function matching_tasks(params, opts)
  -- `sort` is a word of `model.SORTS`; "default" (and none) is the plan's order.
  local sort = "default"
  if params.sort ~= nil then
    local parsed, serr = model.parse_sort(params.sort)
    if not parsed then
      return nil, { code = "invalid_argument", message = serr, retryable = false }
    end
    sort = parsed
  end
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  if params.area ~= nil and not vault.has_area(view.root, params.area) then
    return nil,
      { code = "not_found", message = "unknown area: " .. tostring(params.area), retryable = false }
  end
  local want = nil
  if params.status then
    want = {}
    for _, s in ipairs(params.status) do
      want[s] = true
    end
  end
  local matching = {}
  local ordered = vim.list_slice(view.open, 1)
  table.sort(ordered, function(a, b)
    return (view.rank[a.id] or math.huge) < (view.rank[b.id] or math.huge)
  end)
  for _, t in ipairs(ordered) do
    if (params.area == nil or t.area == params.area) and (want == nil or want[t.status]) then
      matching[#matching + 1] = t
    end
  end
  if opts and opts.filter and next(opts.filter) ~= nil then
    matching = (model.filter(matching, opts.filter))
  end
  if opts and opts.readiness then
    local kept, kerr = plan_scope.filter_readiness(matching, opts.readiness, view.root, view.shared)
    if not kept then
      return nil, kerr
    end
    matching = kept
  end
  if sort ~= "default" then
    -- The same orders as the text form; a tie ends by name (`model.compare`), so a page is the same each time.
    matching = model.sort(matching, sort, { scores = opts and opts.scores })
  end
  return view, matching, sort
end

---A page of tasks in plan order, optionally of one area or status. The command line adds what the dispatcher does not
---offer (`opts.filter`: every filter of `list`; `opts.readiness`: `ready` or `waiting`).
---@param params? { area?: string, status?: string[], limit?: integer, offset?: integer }
---@param opts? { root?: string, view?: Tasks.ContractView, filter?: Tasks.Filter, readiness?: "ready"|"waiting" }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.list(params, opts)
  params = params or {}
  local limit = params.limit or M.LIMITS.list_items
  local offset = params.offset or 0
  if
    type(limit) ~= "number"
    or limit < 1
    or limit > M.LIMITS.list_items
    or limit ~= math.floor(limit)
  then
    return nil,
      {
        code = "invalid_argument",
        message = ("limit must be 1..%d"):format(M.LIMITS.list_items),
        retryable = false,
      }
  end
  if type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset) then
    return nil,
      {
        code = "invalid_argument",
        message = "offset must be a whole number of 0 or more",
        retryable = false,
      }
  end
  local view, matching = matching_tasks(params, opts)
  if not view then
    return nil, matching
  end
  local items = {}
  for i = offset + 1, math.min(offset + limit, #matching) do
    local t = matching[i]
    items[#items + 1] = task_entry(view.root, t, view.plan.nodes[t.id], view.rank[t.id])
  end
  local doc = M.head("tasks.list", view.root)
  doc.total = #matching
  doc.offset = offset
  doc.limit = limit
  doc.items = json.memo(items)
  if offset + limit < #matching then
    doc.next_offset = offset + limit
  end
  doc.incomplete = view.errors
  return seal(doc, rev_of(view, items)), nil
end

---The ids of the open tasks in the order of `sort` (one of `model.SORTS`; none or "default" is the plan's order), all in
---one document: a reader that lays tasks it already holds along an order does not page through `list` for it.
---@param params? { area?: string, status?: string[], sort?: string }
---@param opts? { root?: string, view?: Tasks.ContractView, scores?: table<string, number> }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.order(params, opts)
  params = params or {}
  local view, matching, sort = matching_tasks(params, opts)
  if not view then
    return nil, matching
  end
  local ids = {}
  for i, t in ipairs(matching) do
    ids[i] = t.id
  end
  local doc = M.head("tasks.order", view.root)
  doc.sort = sort
  doc.total = #ids
  doc.ids = json.memo(ids)
  doc.incomplete = view.errors
  return seal(doc, nil), nil
end

---The options of a list that the document carries: the fields of `lists.FIELD_ORDER` but the description and the
---name, as they are written (strings, `true` for a switch).
---@param def table
---@return table
local function list_options(def)
  local lists = require("tasks_nvim.lists")
  local out = {}
  for _, key in ipairs(lists.FIELD_ORDER) do
    if key ~= "desc" and def[key] ~= nil then
      out[key] = def[key]
    end
  end
  return json.object(out)
end

---The named lists of the engine, read only: the built-in ones, the ones saved with the editor and the ones of the
---configuration (the later source wins by name). A list is a filter and an order under a name; running one is the
---reader's job. What the engine had to leave out (a definition it rejects, a list another source shadows, a state file
---it cannot read) comes back as `notes`, in its words and without a path of this machine.
---@param opts? { root?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.lists(opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local lists = require("tasks_nvim.lists")
  local entries, raw_notes = lists.all()
  local _, status = lists.load()
  local items = {}
  for _, e in ipairs(entries) do
    local item = {
      name = e.name,
      source = e.source,
      summary = clip(lists.summary(e.def), M.LIMITS.title),
      options = list_options(e.def),
    }
    if e.def.desc then
      item.desc = clip(e.def.desc, M.LIMITS.summary)
    end
    items[#items + 1] = json.object(item)
  end
  local notes = {}
  for _, n in ipairs(raw_notes) do
    if n:find("^saved lists not used:") then
      -- (the engine's sentence names the state file of the editor: only the fact is told)
      n = "saved lists not used: the state file is " .. tostring(status)
    end
    notes[#notes + 1] = clip(redact(root, n), 600)
  end
  local doc = M.head("tasks.lists", root)
  doc.lists = json.memo(items)
  doc.notes = notes
  return seal(doc, nil), nil
end

---One task with its body and steps.
---@param id string
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.task(id, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local area, slug, perr = vault.parse_id(tostring(id))
  if not area or not slug then
    return nil,
      { code = "invalid_argument", message = perr or "expected <area>/<slug>", retryable = false }
  end
  local view, verr = opts and opts.view or nil, nil
  if not view then
    view, verr = M.view(opts)
  end
  if not view then
    return nil, verr
  end
  local found
  for _, t in ipairs(view.all) do
    if t.id == id and t.location == "roadmap" then
      found = t
      break
    end
  end
  if not found then
    return nil,
      { code = "not_found", message = "no such task: " .. tostring(id), retryable = false }
  end
  local text = not fsio.is_link(found.path) and fsio.read(found.path) or nil
  local body = ""
  if text then
    local parsed = require("lib.nvim.markdown.frontmatter").parse(text)
    body = parsed and parsed.body or text
  end
  local truncated = #body > M.LIMITS.body_bytes
  if truncated then
    body = body:sub(1, M.LIMITS.body_bytes)
  end
  local doc = M.head("tasks.task", view.root)
  doc.task = task_entry(view.root, found, view.plan.nodes[found.id], view.rank[found.id])
  doc.body = body
  doc.body_truncated = truncated
  doc.steps = vim.tbl_map(function(s)
    return { n = s.n, text = s.text, ticked = s.done == true, dropped = s.dropped == true }
  end, found.plan_steps and found.plan_steps.items or {})
  return seal(doc, rev_of(view, { doc.task })), nil
end

---The most tasks one page of `bodies` names or holds (a page ends earlier at `BODIES_PAGE_BYTES`).
M.BODIES_MAX_ITEMS = 1000

---The most body bytes one page of `bodies` carries (a document stays far below `MAX_DOC_BYTES`, also once escaped).
M.BODIES_PAGE_BYTES = 2 * 1024 * 1024

---The text of many tasks, for a reader that searches it: `{ id, etag, body, body_truncated }` for the open tasks in plan
---order, a page at a time (`offset`, `limit`; the page ends early when it holds `BODIES_PAGE_BYTES`, `next_offset` says
---where to go on), or for the tasks named in `ids` (an id that is not there is left out). The `rev` is that of the
---snapshot of the same vault, so that a reader can tell the two documents come from one state. A body is cut to
---`LIMITS.body_bytes` and says so, as in `tasks.task`; it is untrusted text.
---@param params? { ids?: string[], offset?: integer, limit?: integer }
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.bodies(params, opts)
  params = params or {}
  local limit = params.limit or M.BODIES_MAX_ITEMS
  local offset = params.offset or 0
  if
    type(limit) ~= "number"
    or limit < 1
    or limit > M.BODIES_MAX_ITEMS
    or limit ~= math.floor(limit)
  then
    return nil,
      {
        code = "invalid_argument",
        message = ("limit must be 1..%d"):format(M.BODIES_MAX_ITEMS),
        retryable = false,
      }
  end
  if type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset) then
    return nil,
      {
        code = "invalid_argument",
        message = "offset must be a whole number of 0 or more",
        retryable = false,
      }
  end
  if params.ids ~= nil and #params.ids > M.BODIES_MAX_ITEMS then
    return nil,
      {
        code = "invalid_argument",
        message = ("ids holds at most %d ids"):format(M.BODIES_MAX_ITEMS),
        retryable = false,
      }
  end
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end

  local ordered = vim.list_slice(view.open, 1)
  table.sort(ordered, function(a, b)
    return (view.rank[a.id] or math.huge) < (view.rank[b.id] or math.huge)
  end)
  local chosen = ordered
  if params.ids ~= nil then
    local want = {}
    for _, id in ipairs(params.ids) do
      want[id] = true
    end
    chosen = {}
    for _, t in ipairs(ordered) do
      if want[t.id] then
        chosen[#chosen + 1] = t
      end
    end
  end

  local items, bytes, last = {}, 0, offset
  for i = offset + 1, math.min(offset + limit, #chosen) do
    local t = chosen[i]
    local text = not fsio.is_link(t.path) and fsio.read(t.path) or nil
    local body = ""
    if text then
      local parsed = require("lib.nvim.markdown.frontmatter").parse(text)
      body = parsed and parsed.body or text
    end
    local truncated = #body > M.LIMITS.body_bytes
    if truncated then
      body = body:sub(1, M.LIMITS.body_bytes)
    end
    if #items > 0 and bytes + #body > M.BODIES_PAGE_BYTES then
      break
    end
    bytes = bytes + #body
    last = i
    -- A file that cannot be read has no version tag, and a text of nothing: it
    -- is not an item (the contract wants a tag), and the page goes on.
    local etag = t.etag or etag_of(t.path)
    if etag then
      items[#items + 1] = json.object({
        id = t.id,
        etag = etag,
        body = body,
        body_truncated = truncated,
      })
    end
  end

  local entries = {}
  for _, t in ipairs(view.open) do
    entries[#entries + 1] = { id = t.id, etag = t.etag or etag_of(t.path) }
  end
  local doc = M.head("tasks.bodies", view.root)
  doc.total = #chosen
  doc.offset = offset
  doc.limit = limit
  doc.items = json.memo(items)
  if last < #chosen then
    doc.next_offset = last
  end
  doc.incomplete = view.errors
  return seal(doc, rev_of(view, entries)), nil
end

---The most ids and the most assumptions one `estimate` request holds.
M.ESTIMATE_MAX_ITEMS = 1000

---The figures of `estimate` for some open tasks, optionally as they would be if some efforts and values were
---different (`assume`: nothing is written). The figures are those of `tasks_nvim.estimate`, the same as the snapshot
---gives for the whole vault, so a client that shows a sum of a draft never reckons it itself.
---The tasks come in the order of the snapshot (`view.open`), so the lists of the two documents agree.
---@param params? { ids?: string[], assume?: { id?: string, effort?: string, value?: integer }[] }
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.estimate(params, opts)
  params = params or {}
  local function bad(message)
    return nil, { code = "invalid_argument", message = message, retryable = false }
  end
  if params.ids ~= nil and #params.ids > M.ESTIMATE_MAX_ITEMS then
    return bad(("ids holds at most %d ids"):format(M.ESTIMATE_MAX_ITEMS))
  end
  if params.assume ~= nil and #params.assume > M.ESTIMATE_MAX_ITEMS then
    return bad(("assume holds at most %d entries"):format(M.ESTIMATE_MAX_ITEMS))
  end
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local by_id = {}
  for _, t in ipairs(view.open) do
    by_id[t.id] = t
  end
  -- the tasks asked for, in plan order; an id that is no open task is refused by name
  local chosen = {}
  if params.ids ~= nil then
    local want = {}
    for _, id in ipairs(params.ids) do
      if not by_id[id] then
        return bad(("ids: '%s' is no open task"):format(id))
      end
      want[id] = true
    end
    for _, t in ipairs(view.open) do
      if want[t.id] then
        chosen[#chosen + 1] = t
      end
    end
  else
    chosen = vim.list_slice(view.open, 1)
  end
  local in_scope = {}
  for _, t in ipairs(chosen) do
    in_scope[t.id] = true
  end
  -- the assumptions: a task with its effort and value as the entry says; what the engine would not write is refused
  local assumed = {}
  for i, entry in ipairs(params.assume or {}) do
    local where = ("assume[%d]"):format(i)
    if type(entry.id) ~= "string" or not in_scope[entry.id] then
      return bad(("%s: '%s' is not one of the tasks asked for"):format(where, tostring(entry.id)))
    end
    for key in pairs(entry) do
      if key ~= "id" and key ~= "effort" and key ~= "value" then
        return bad(
          ("%s: unknown field '%s' (fields: id, effort, value)"):format(where, tostring(key))
        )
      end
    end
    if entry.effort == nil and entry.value == nil then
      return bad(("%s: needs an effort or a value"):format(where))
    end
    if entry.effort ~= nil and not model.is_effort(entry.effort) then
      return bad(
        ("%s.effort: '%s' is not an effort (XS S M L XL, or <n>d up to %d days)"):format(
          where,
          tostring(entry.effort):sub(1, 40),
          model.MAX_EFFORT_DAYS
        )
      )
    end
    if
      entry.value ~= nil
      and not (
        type(entry.value) == "number"
        and entry.value == math.floor(entry.value)
        and entry.value >= 1
        and entry.value <= 5
      )
    then
      return bad(("%s.value: '%s' is not a value (1..5)"):format(where, tostring(entry.value)))
    end
    assumed[entry.id] = vim.tbl_extend("force", assumed[entry.id] or {}, entry)
  end
  local tasks, n_assumed = {}, 0
  for _, t in ipairs(chosen) do
    local a = assumed[t.id]
    if a then
      n_assumed = n_assumed + 1
      t = vim.tbl_extend("force", t, { effort = a.effort or t.effort, value = a.value or t.value })
    end
    tasks[#tasks + 1] = t
  end
  local sums = estimate.rollup(tasks)
  local entries = {}
  for _, t in ipairs(view.open) do
    entries[#entries + 1] = { id = t.id, etag = t.etag or etag_of(t.path) }
  end
  local doc = M.head("tasks.estimate", view.root)
  doc.tasks = sums.n
  doc.days = round2(sums.days)
  doc.range = json.object({ low = round2(sums.range.low), high = round2(sums.range.high) })
  doc.n_with_effort = sums.n_with_effort
  doc.n_without_effort = sums.n_without_effort
  doc.value = sums.value
  doc.n_with_value = sums.n_with_value
  doc.n_without_value = sums.n_without_value
  doc.roi = sums.roi and round2(sums.roi) or nil
  doc.quick_wins = vim.list_slice(sums.quick_wins, 1)
  doc.unestimated = vim.list_slice(sums.unestimated, 1)
  doc.assumed = n_assumed
  doc.incomplete = view.errors
  return seal(doc, rev_of(view, entries)), nil
end

---The most tasks one `plan_for` document names (the rest is counted in `total` and `truncated` says so).
M.PLAN_FOR_MAX_NODES = 500

---The tasks one task needs before it can start (`needs`: its hard blockers, transitively, across areas), or the tasks
---that wait for it (`unlocks`), with the edges between them, the part of the plan's critical path they lie on and the
---cycles they touch. The tasks are those of `plan --for`; a client that shows the graph never walks it itself.
---@param params? { id?: string, direction?: string }
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.plan_for(params, opts)
  params = params or {}
  if type(params.id) ~= "string" or params.id == "" then
    return nil,
      { code = "invalid_argument", message = "plan_for needs the parameter id", retryable = false }
  end
  local direction = params.direction or "needs"
  if direction ~= "needs" and direction ~= "unlocks" then
    return nil,
      {
        code = "invalid_argument",
        message = "direction must be needs or unlocks",
        retryable = false,
      }
  end
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local index = view.shared.index
  local target = index.open[params.id]
  if not target then
    return nil,
      { code = "not_found", message = "no such open task: " .. params.id, retryable = false }
  end
  -- who a task waits on (hard edges only: `blocked_by` and the gate of a plan), and who waits on it
  -- (once for each task, each blocker once: a repeated `blocked_by` entry is one edge)
  local memo = {}
  local function blockers(t)
    local hit = memo[t.id]
    if hit then
      return hit
    end
    local out, seen = {}, {}
    for _, b in ipairs(plan.hard_blockers(t, index)) do
      if index.open[b] and not seen[b] then
        seen[b] = true
        out[#out + 1] = b
      end
    end
    memo[t.id] = out
    return out
  end
  local dependents = {}
  if direction == "unlocks" then
    for _, t in ipairs(view.open) do
      for _, b in ipairs(blockers(t)) do
        dependents[b] = dependents[b] or {}
        dependents[b][#dependents[b] + 1] = t.id
      end
    end
  end
  -- breadth first from the task: the distance is the number of steps, the first way found is the shortest
  local distance, order, queue = { [target.id] = 0 }, { target.id }, { target.id }
  local head = 1
  while head <= #queue do
    local id = queue[head]
    head = head + 1
    local next_ids = direction == "needs" and blockers(index.open[id]) or (dependents[id] or {})
    for _, n in ipairs(next_ids) do
      if distance[n] == nil then
        distance[n] = distance[id] + 1
        order[#order + 1] = n
        queue[#queue + 1] = n
      end
    end
  end
  table.sort(order, function(a, b)
    if distance[a] ~= distance[b] then
      return distance[a] < distance[b]
    end
    return (view.rank[a] or math.huge) < (view.rank[b] or math.huge)
  end)
  local on_path = {}
  for _, id in ipairs(view.plan.critical.path) do
    on_path[id] = true
  end
  local total = #order
  local kept = {}
  for i = 1, math.min(total, M.PLAN_FOR_MAX_NODES) do
    kept[order[i]] = true
  end
  local nodes, edges = {}, {}
  for i = 1, math.min(total, M.PLAN_FOR_MAX_NODES) do
    local t = index.open[order[i]]
    local node = view.plan.nodes[t.id]
    nodes[#nodes + 1] = json.object({
      id = t.id,
      title = clip(t.title or "", M.LIMITS.title),
      status = t.status,
      state = node and node.state or nil,
      stage = node and node.stage or nil,
      distance = distance[t.id],
      on_critical_path = on_path[t.id] and true or nil,
    })
    local hard = {}
    for _, b in ipairs(t.blocked_by or {}) do
      hard[b] = "blocked_by"
    end
    for _, b in ipairs(blockers(t)) do
      if kept[b] then
        edges[#edges + 1] = json.object({ from = b, to = t.id, kind = hard[b] or "gate" })
      end
    end
  end
  table.sort(edges, function(a, b)
    if a.to ~= b.to then
      return a.to < b.to
    end
    return a.from < b.from
  end)
  -- a cycle is named when all its members are in `nodes` (a client can resolve every id of it)
  local cycles = {}
  for _, cycle in ipairs(view.plan.cycles) do
    local whole, touches = true, false
    for _, id in ipairs(cycle) do
      if kept[id] then
        touches = true
      else
        whole = false
      end
    end
    if touches and whole then
      cycles[#cycles + 1] = vim.list_slice(cycle, 1)
    end
  end
  local entries = {}
  for _, t in ipairs(view.open) do
    entries[#entries + 1] = { id = t.id, etag = t.etag or etag_of(t.path) }
  end
  local doc = M.head("tasks.planfor", view.root)
  doc.id = target.id
  doc.direction = direction
  doc.total = total
  doc.truncated = total > M.PLAN_FOR_MAX_NODES
  doc.nodes = json.memo(nodes)
  doc.edges = edges
  doc.cycles = cycles
  doc.incomplete = view.errors
  return seal(doc, rev_of(view, entries)), nil
end

---The most findings one `check` document holds (the rest is counted in `total` and `truncated` says so).
M.CHECK_MAX_FINDINGS = 1000

---The rule check of the vault (`tasks check`) as a document, and with `stale = "refs"` also the open tasks that name a
---file which changed after the task was last updated. It reads every task file and, for the refs, asks git: it takes
---longer than a question, so a client runs it as a job and never waits for it with a screen in its hands. The wording of
---a finding is the engine's.
---@param params? { area?: string, stale?: string }
---@param opts? { root?: string, ref_opts?: table }  # `ref_opts` reaches `staleness.compute` (specs)
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.check(params, opts)
  params = params or {}
  local function bad(message)
    return nil, { code = "invalid_argument", message = message, retryable = false }
  end
  if params.stale ~= nil and params.stale ~= "refs" then
    return bad("stale must be refs")
  end
  return fsio.read_scope(function()
    local view, err = M.build_view(opts)
    if not view then
      return nil, err
    end
    if params.area ~= nil and not vault.has_area(view.root, params.area) then
      return nil,
        { code = "not_found", message = "unknown area: " .. params.area, retryable = false }
    end
    local result, cerr = check.run({ root = view.root, area = params.area })
    if not result then
      return nil, cerr
    end
    ---@type table[]
    local findings = {}
    for _, f in ipairs(result.findings) do
      findings[#findings + 1] = json.object({
        code = f.code,
        severity = f.severity == "warn" and "warn" or "error",
        area = f.area,
        id = f.id,
        file = relative(view.root, f.path) or vim.fs.basename(f.path),
        message = clip(redact(view.root, f.message), 600),
      })
    end
    local notes = {}
    local added_warnings = 0
    if params.stale == "refs" then
      local scoped = {}
      for _, t in ipairs(view.open) do
        if params.area == nil or t.area == params.area then
          scoped[#scoped + 1] = t
        end
      end
      local ok, report = pcall(
        staleness.compute,
        scoped,
        vim.tbl_extend("force", { root = view.root }, opts and opts.ref_opts or {})
      )
      if ok then
        for _, t in ipairs(scoped) do
          local changes = report.stale[t.id]
          if changes and #changes > 0 then
            -- the refs as the snapshot names them (an absolute one is not spelled out)
            local shown = vim.tbl_map(function(c)
              return vim.tbl_extend("force", c, { ref = safe_path(view.root, c.ref) })
            end, changes)
            added_warnings = added_warnings + 1
            findings[#findings + 1] = json.object({
              code = "stale-refs",
              severity = "warn",
              area = t.area,
              id = t.id,
              file = relative(view.root, t.path) or vim.fs.basename(t.path),
              message = clip(
                redact(
                  view.root,
                  "a file named in refs changed after the task was updated: "
                    .. staleness.describe(shown, 5)
                ),
                600
              ),
            })
          end
        end
        -- a note that names a folder of this machine (`<repo>: not a git repository`) is told without it
        -- (the two notes that are the engine's own sentences are told as they are, anchored at their start: a note
        -- that begins with a folder or holds a ref must not pass for one of them; no sentence twice)
        local told = {}
        for _, n in ipairs(report.notes or {}) do
          local text = tostring(n)
          local line
          if
            text:match("^git time budget of %d+ ms used up")
            or text:match("^%d+ distinct file%(s%) beyond the limit of %d+")
          then
            line = clip(text, 300)
          elseif text:match("^vault not found") then
            line = "refs not checked"
          else
            line = "a folder could not be dated by git; file times were used"
          end
          if not told[line] then
            told[line] = true
            notes[#notes + 1] = line
          end
        end
      else
        notes[#notes + 1] = "refs could not be checked"
      end
    end
    -- one total order: errors first, then by file, code, task and wording; a cut at the limit drops the least important
    table.sort(findings, function(a, b)
      if a.severity ~= b.severity then
        return a.severity == "error"
      end
      if a.file ~= b.file then
        return a.file < b.file
      end
      if a.code ~= b.code then
        return a.code < b.code
      end
      if (a.id or "") ~= (b.id or "") then
        return (a.id or "") < (b.id or "")
      end
      return a.message < b.message
    end)
    local total = #findings
    for i = #findings, M.CHECK_MAX_FINDINGS + 1, -1 do
      findings[i] = nil
    end
    local entries = {}
    for _, t in ipairs(view.open) do
      entries[#entries + 1] = { id = t.id, etag = t.etag or etag_of(t.path) }
    end
    local doc = M.head("tasks.check", view.root)
    doc.ok = result.ok
    doc.errors = result.errors
    doc.warnings = result.warnings + added_warnings
    doc.areas = result.areas
    doc.tasks = result.tasks
    doc.stale = params.stale
    doc.total = total
    doc.truncated = total > M.CHECK_MAX_FINDINGS
    doc.findings = json.memo(findings)
    doc.notes = notes
    doc.incomplete = view.errors
    return seal(doc, rev_of(view, entries)), nil
  end)
end

---What to start next.
---@param params? { n?: integer, actor?: string, area?: string }
---@param opts? { root?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.next(params, opts)
  params = params or {}
  if
    params.n ~= nil
    and (
      type(params.n) ~= "number"
      or params.n < 0
      or params.n > 10
      or params.n ~= math.floor(params.n)
    )
  then
    return nil, { code = "invalid_argument", message = "n must be 0..10", retryable = false }
  end
  if params.actor ~= nil and not (model.is_actor(params.actor) or params.actor == "none") then
    return nil,
      {
        code = "invalid_argument",
        message = "actor must be cdx, me, pair or none",
        retryable = false,
      }
  end
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if params.area ~= nil and not vault.has_area(root, params.area) then
    return nil,
      { code = "not_found", message = "unknown area: " .. tostring(params.area), retryable = false }
  end
  local pick, err = next_pick.pick_from_vault({
    root = root,
    area = params.area,
    actor = params.actor,
    n = params.n,
  })
  if not pick then
    return nil, err
  end
  local doc = M.head("tasks.next", root)
  if pick.task then
    local t = brief(pick.task)
    t.reason = pick.reason
    doc.task = json.object(t)
  end
  doc.alternatives = vim.tbl_map(brief, pick.alternatives)
  doc.cdx = vim.tbl_map(brief, pick.cdx)
  doc.freed = vim.list_slice(pick.freed, 1)
  doc.ready = json.object({ area = pick.ready.area, vault = pick.ready.vault })
  doc.open = json.object({ area = pick.open.area, vault = pick.open.vault })
  if pick.empty then
    doc.empty = json.object({
      kind = pick.empty.kind,
      waiting = pick.empty.waiting,
      for_me = pick.empty.for_me,
      blocked_status = pick.empty.blocked_status,
      parked = pick.empty.parked,
      unlisted = pick.empty.unlisted,
      unreadable = pick.empty.unreadable,
    })
  end
  doc.incomplete = vim.tbl_map(function(e)
    return redact(root, tostring(e))
  end, pick.incomplete or {})
  return seal(doc, nil), nil
end

---The areas with their open counts.
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return string|nil err
function M.areas(opts)
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local doc = M.head("tasks.areas", view.root)
  doc.areas = areas_of(view)
  return seal(doc, nil), nil
end

---The Monday of the week a day falls in (`YYYY-MM-DD`). Plain day arithmetic (`os.time` has no answer for a year the
---platform cannot represent, and one such file name must not fail the whole document).
---@param date string  # a valid day
---@return string
local function week_start(date)
  -- 1970-01-05 was a Monday
  local since_monday = model.days_between("1970-01-05", date) % 7
  return model.add_days(date, -since_monday) or date
end

---A sum of days, to the hundredth.
---@param n number
---@return number
local function days_sum(n)
  return round2(n)
end

---One row of a count: `{ <key> = value, count, effort_days }`. The key is left out for tasks that do not carry the
---field (missing means unknown, never a value of its own).
---@param key string
---@param bucket { value: any, count: integer, days: number }
---@return table
local function count_row(key, bucket)
  return json.object({
    [key] = bucket.value,
    count = bucket.count,
    effort_days = days_sum(bucket.days),
  })
end

---Count `items` by `of(item)` into rows, the biggest first, then by value (the unknown last).
---@param items Tasks.Task[]
---@param key string
---@param of fun(t: Tasks.Task): any
---@param ascending? boolean  # order by value instead (months, weeks)
---@return table[]
local function count_by(items, key, of, ascending)
  local buckets, order = {}, {}
  for _, t in ipairs(items) do
    local v = of(t)
    local slot = v == nil and "\0unknown" or tostring(v)
    local b = buckets[slot]
    if not b then
      b = { value = v, count = 0, days = 0 }
      buckets[slot] = b
      order[#order + 1] = b
    end
    b.count = b.count + 1
    b.days = b.days + (model.effort_days(t.effort) or 0)
  end
  table.sort(order, function(a, b)
    if (a.value == nil) ~= (b.value == nil) then
      return b.value == nil
    end
    if not ascending and a.count ~= b.count then
      return a.count > b.count
    end
    return tostring(a.value) < tostring(b.value)
  end)
  return vim.tbl_map(function(b)
    return count_row(key, b)
  end, order)
end

---The finished tasks of the Backlogs and what they add up to. `since` and `until` (both days, both included) narrow
---it by the day `done` ran (the date in the file name); a task whose file has no such date is counted under
---`undated` and is only in the figures when no window is asked for. Every figure covers all the tasks that match, the
---page (`items`, newest first) only what `limit` and `offset` ask for. The area is the one the file is in now. `plan` (a
---plan id) keeps the tasks that name that plan.
---@param params? { area?: string, plan?: string, since?: string, until?: string, limit?: integer, offset?: integer }
---@param opts? { root?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.finished(params, opts)
  params = params or {}
  local limit = params.limit or M.LIMITS.list_items
  local offset = params.offset or 0
  if
    type(limit) ~= "number"
    or limit < 1
    or limit > M.LIMITS.list_items
    or limit ~= math.floor(limit)
  then
    return nil,
      {
        code = "invalid_argument",
        message = ("limit must be 1..%d"):format(M.LIMITS.list_items),
        retryable = false,
      }
  end
  if type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset) then
    return nil,
      {
        code = "invalid_argument",
        message = "offset must be a whole number of 0 or more",
        retryable = false,
      }
  end
  for _, name in ipairs({ "since", "until" }) do
    if params[name] ~= nil and not model.is_date(params[name]) then
      return nil,
        {
          code = "invalid_argument",
          message = name .. " must be a day, YYYY-MM-DD",
          retryable = false,
        }
    end
  end
  if params.since and params["until"] and params.since > params["until"] then
    return nil, { code = "invalid_argument", message = "since is after until", retryable = false }
  end
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if params.area ~= nil and not vault.has_area(root, params.area) then
    return nil,
      { code = "not_found", message = "unknown area: " .. tostring(params.area), retryable = false }
  end
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    if params.area == nil or a.name == params.area then
      names[#names + 1] = a.name
    end
  end
  local windowed = params.since ~= nil or params["until"] ~= nil
  local matching, undated, incomplete = {}, 0, {}
  local dates = {}
  for _, name in ipairs(names) do
    local tasks, errors = scan.backlog(name, { root = root })
    if type(errors) == "table" then
      for _, e in ipairs(errors) do
        incomplete[#incomplete + 1] = redact(root, tostring(e))
      end
    end
    for _, t in ipairs(tasks or {}) do
      local date = model.done_date(t.path)
      if date == nil then
        undated = undated + 1
      end
      local inside = (params.plan == nil or t.plan == params.plan)
        and (date ~= nil or not windowed)
        and (params.since == nil or (date ~= nil and date >= params.since))
        and (params["until"] == nil or (date ~= nil and date <= params["until"]))
      if inside then
        matching[#matching + 1] = t
        dates[t] = date
      end
    end
  end
  table.sort(matching, function(a, b)
    local da, db = dates[a] or "", dates[b] or ""
    if da ~= db then
      return da > db
    end
    return a.id < b.id
  end)
  local days, without = 0, 0
  for _, t in ipairs(matching) do
    local d = model.effort_days(t.effort)
    if d then
      days = days + d
    else
      without = without + 1
    end
  end
  local items = {}
  for i = offset + 1, math.min(offset + limit, #matching) do
    local t = matching[i]
    local d = model.effort_days(t.effort)
    items[#items + 1] = json.object({
      id = t.id,
      area = t.area,
      slug = t.slug,
      title = t.title,
      done = dates[t],
      kind = model.is_kind(t.kind) and t.kind or nil,
      prio = t.prio,
      effort = d and t.effort or nil,
      effort_days = d,
      value = t.value,
      tags = vim.list_slice(t.tags or {}, 1),
      plan = t.plan,
      phase = t.phase,
      done_in = t.done_in,
      commits = (t.commits and #t.commits > 0) and vim.list_slice(t.commits, 1) or nil,
      file = relative(root, t.path) or vim.fs.basename(t.path),
    })
  end
  local doc = M.head("tasks.finished", root)
  doc.total = #matching
  doc.offset = offset
  doc.limit = limit
  doc.items = json.memo(items)
  if offset + limit < #matching then
    doc.next_offset = offset + limit
  end
  doc.undated = undated
  doc.stats = json.object({
    effort_days = days_sum(days),
    without_effort = without,
    by_area = count_by(matching, "area", function(t)
      return t.area
    end),
    by_kind = count_by(matching, "kind", function(t)
      return model.is_kind(t.kind) and t.kind or nil
    end),
    by_prio = count_by(matching, "prio", function(t)
      return t.prio
    end),
    by_month = count_by(matching, "month", function(t)
      return dates[t] and dates[t]:sub(1, 7) or nil
    end, true),
    by_week = count_by(matching, "week", function(t)
      return dates[t] and week_start(dates[t]) or nil
    end, true),
  })
  doc.incomplete = incomplete
  return seal(doc, nil), nil
end

---Where the areas hang together: the links between the open tasks of different areas (`blocked_by`, `after`, a ref that
---names another area, a plan whose open tasks lie in several areas), by pair of areas with the edges, and for every
---task that touches two or more areas the areas it touches. The same `rev` as the snapshot of the same vault.
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.links(opts)
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local names = vim.tbl_map(function(a)
    return a.name
  end, vault.areas(view.root))
  local result = links.compute(view.open, names)
  local entries = vim.tbl_map(function(t)
    return { id = t.id, etag = t.etag or etag_of(t.path) }
  end, view.open)
  local doc = M.head("tasks.links", view.root)
  doc.edge_count = result.edge_count
  doc.truncated = result.truncated
  doc.pairs = vim.tbl_map(function(p)
    local kinds = {}
    for kind, n in pairs(p.kinds) do
      kinds[kind] = n
    end
    return json.object({
      a = p.a,
      b = p.b,
      count = p.count,
      kinds = json.object(kinds),
      edges = vim.tbl_map(function(e)
        return json.object({
          from = e.from,
          from_area = e.from_area,
          to_area = e.to_area,
          kind = e.kind,
          to = e.to,
          ref = e.ref and clip(e.ref, M.LIMITS.title) or nil,
        })
      end, p.edges),
    })
  end, result.pairs)
  doc.tasks = vim.tbl_map(function(t)
    return json.object({ id = t.id, areas = t.areas })
  end, result.tasks)
  doc.incomplete = view.errors
  return seal(doc, rev_of(view, entries)), nil
end

---How many values of a field that comes from the vault (tags, plans, phases) a grouping lists.
local GROUPING_VALUES_MAX = 200

---The distinct values a function names over the open tasks, sorted, cut at `LIMITS.grouping_values`.
---@param tasks table[]
---@param pick fun(t: table): string|string[]|nil
---@return string[] values
---@return boolean truncated
local function grouping_values(tasks, pick)
  local seen, values = {}, {}
  for _, t in ipairs(tasks) do
    local got = pick(t)
    if type(got) == "string" then
      got = { got }
    end
    for _, v in ipairs(got or {}) do
      -- A value that is too long is left out, not cut: a cut tag would be another tag, and a reader that writes the value
      -- of a group would write that one. The reader meets the long one on the task and shows a group of its own for it.
      if
        type(v) == "string"
        and v ~= ""
        and not seen[v]
        and vim.fn.strchars(v) <= M.LIMITS.title
      then
        seen[v] = true
        values[#values + 1] = v
      end
    end
  end
  table.sort(values)
  if #values > GROUPING_VALUES_MAX then
    return vim.list_slice(values, 1, GROUPING_VALUES_MAX), true
  end
  return values, false
end

---The fields the open tasks can be grouped by, with the values each can have and how a reader writes it. A reader that
---draws groups (columns, a grouped list, a matrix) and lets a task be dragged from one group to another asks this, so
---that the page names no field and no value itself: `status`, `prio`, `actor`, `kind`, `effort`, `value` come from the
---model, `tags`, `plan` and `phase` from the open tasks, `area` from the vault; `state` and `cross` are derived and cannot be
---written (`cross`: `several` for a task `tasks.links` names among the tasks that touch two or more areas, else `one`).
---`mode` says which operation writes it (`set` for a field of the file, `tags` for the list of tags - leaving one and
---taking another is one `set` of the whole list - and `move_area` for the area); a field without `mode` is read only.
---The same `rev` as the snapshot of the same vault.
---@param opts? { root?: string, view?: Tasks.ContractView }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.groupings(opts)
  local view, err = opts and opts.view or nil, nil
  if not view then
    view, err = M.view(opts)
  end
  if not view then
    return nil, err
  end
  local fields = {}
  ---@param name string
  ---@param values string[]|number[]
  ---@param mode? "set"|"tags"|"move_area"
  ---@param extra? table
  local function add(name, values, mode, extra)
    local item = { field = name, values = {}, truncated = false, writable = mode ~= nil }
    local numeric = type(values[1]) == "number"
    for _, v in ipairs(values) do
      item.values[#item.values + 1] = tostring(v)
    end
    item.value_type = numeric and "number" or "string"
    item.mode = mode
    for k, v in pairs(extra or {}) do
      item[k] = v
    end
    item.values = json.memo(item.values)
    fields[#fields + 1] = json.object(item)
  end
  add("status", model.OPEN_STATUSES, "set")
  add("prio", model.PRIOS, "set")
  add("actor", model.ACTORS, "set")
  add("kind", model.KINDS, "set")
  add("effort", model.EFFORTS, "set")
  add("value", model.VALUES, "set")
  local tags, tags_cut = grouping_values(view.open, function(t)
    return t.tags
  end)
  add("tags", tags, "tags", { truncated = tags_cut, multi = true })
  local plans, plans_cut = grouping_values(view.open, function(t)
    return t.plan
  end)
  add("plan", plans, "set", { truncated = plans_cut })
  local phases, phases_cut = grouping_values(view.open, function(t)
    return t.phase
  end)
  add("phase", phases, "set", { truncated = phases_cut })
  local areas = vim.tbl_map(function(a)
    return a.name
  end, vault.areas(view.root))
  table.sort(areas)
  add("area", areas, "move_area")
  add("state", { "ready", "decision", "waiting", "stuck", "freed", "parked", "unknown" }, nil)
  -- Whether a task connects areas: the reader takes it from `tasks.links` (its `tasks`), which says it for this state.
  add("cross", { "several", "one" }, nil)
  local entries = vim.tbl_map(function(t)
    return { id = t.id, etag = t.etag or etag_of(t.path) }
  end, view.open)
  local doc = M.head("tasks.groupings", view.root)
  doc.fields = json.memo(fields)
  return seal(doc, rev_of(view, entries)), nil
end

---The saved views of the tasks, from the vault (`tasks_nvim.views`): each with its selection, its grouping and how it is
---drawn, and the version tag of its file (`etag`, what a change is made on). A file that cannot be read as a view is no
---view but a line in `problems` (its id, its file, the engine's words). The `rev` is that of the views, not of the tasks:
---a view changes when its file does.
---@param opts? { root?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.views(opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local views = require("tasks_nvim.views")
  local list, problems = views.all(root)
  local lines, items = {}, {}
  for _, v in ipairs(list) do
    lines[#lines + 1] = v.id .. "\t" .. v.etag
    local select = {}
    for _, s in ipairs(views.SELECT) do
      select[s.name] = json.memo(vim.deepcopy(v.select[s.name]))
    end
    select.query = v.select.query
    items[#items + 1] = json.object({
      id = v.id,
      area = v.area,
      title = clip(v.title, M.LIMITS.title),
      display = v.display,
      group_by = v.group_by,
      group_by2 = v.group_by2,
      collapsed = json.memo(vim.deepcopy(v.collapsed)),
      select = json.object(select),
      etag = v.etag,
      created = v.created,
      updated = v.updated,
    })
  end
  local notes = {}
  for _, p in ipairs(problems) do
    lines[#lines + 1] = "problem:" .. p.id
    notes[#notes + 1] =
      json.object({ id = p.id, file = p.file, message = clip(redact(root, p.message), 600) })
  end
  local doc = M.head("tasks.views", root)
  doc.views = json.memo(items)
  doc.problems = json.memo(notes)
  return seal(doc, builder.rev_of(lines)), nil
end

---What finishing a task would do, written down: the target, the README row, the steps, the plan it closes, the
---tasks it frees, the `etag` of the file that was read and a `confirm` token for exactly that version. Nothing is
---written; `done` in `tasks-ops/1` needs the token.
---@param id string
---@param opts? { root?: string, today?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.done_preview(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local pv, err, info = done_flow.preview(id, { root = root, today = opts.today })
  if not pv then
    return nil, error_codes.classify(err, info, { patterns = M.ERROR_PATTERNS })
  end
  local doc = M.head("tasks.donepreview", root)
  doc.id = pv.id
  if pv.already then
    doc.already = true
    doc.to = relative(root, pv.to) or vim.fs.basename(pv.to)
    return seal(doc, nil), nil
  end
  doc.area = pv.area
  doc.bucket = pv.bucket
  doc.from = relative(root, pv.from) or vim.fs.basename(pv.from)
  doc.to = relative(root, pv.to) or vim.fs.basename(pv.to)
  doc.resumed = pv.resumed == true
  doc.steps_ticked = pv.steps_ticked or 0
  doc.readme = json.object({ state = pv.readme, row = pv.readme_row })
  doc.plan = pv.plan_id
  doc.closes_plan = pv.closes_plan
  doc.freed = vim.list_slice(pv.freed, 1)
  doc.etag = pv.etag
  doc.confirm = pv.confirm
  return seal(doc, nil), nil
end

---An error document.
---@type fun(err: Tasks.ContractError, root?: string): table
M.error_doc = builder.error_doc

---The canonical bytes of a document; one bigger than the limit is an error, never a cut-off document.
---@type fun(doc: table, opts?: { indent?: integer }): string|nil, Tasks.ContractError|nil
M.encode = builder.encode

---The document builder (head, seal, encode, error_doc) of this contract.
M.doc = builder

return M
