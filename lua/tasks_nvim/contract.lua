---@module 'tasks_nvim.contract'
---@brief The read side of the machine contract `tasks-export/1`: the documents an app, an agent or CI reads.
---@description
--- One Lua table per document kind, built from what the engine already knows (`scan`, `plan`, `next_pick`, `model`,
--- `estimate`), never from a second reading of the files; `encode` turns a document into its canonical bytes
--- (`tasks_nvim.json`). The contract is versioned (`schema: 1`), only ever grows inside a version, and is described by
--- the JSON Schemas in `schemas/tasks-export/1/`. The Markdown files stay the single source of truth.
---
--- Documents (`kind`): `tasks.hello`, `tasks.snapshot`, `tasks.list`, `tasks.task`, `tasks.next`, `tasks.areas`,
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
---  - an empty container is `[]` or `{}` as its kind says (`tasks_nvim.json`), never the other.
---
--- Only reads: nothing here changes a file. Not its job: parsing a request, mapping an error to a code (`api`), the
--- command line (`cli`).

local estimate = require("tasks_nvim.estimate")
local fsio = require("tasks_nvim.fsio")
local json = require("tasks_nvim.json")
local model = require("tasks_nvim.model")
local next_pick = require("tasks_nvim.next_pick")
local plan = require("tasks_nvim.plan")
local plan_scope = require("tasks_nvim.plan_scope")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---The version of the contract (`schema` of every document).
M.SCHEMA = 1

M.PLUGIN = "tasks.nvim"

---The engine's own version (not the contract's).
M.ENGINE_VERSION = "0.1.0-dev"

---What this engine can answer; an app shows only what is listed here. Sorted.
---@type string[]
M.CAPABILITIES = { "areas", "etag", "hello", "list", "next", "snapshot", "task" }

---Sizes the contract promises to keep.
M.LIMITS = { title = 300, summary = 1000, body_bytes = 262144, list_items = 100, batch_ops = 100 }

---A document is never bigger than this.
M.MAX_DOC_BYTES = 8 * 1024 * 1024

---@class Tasks.ContractError
---@field code string
---@field message string
---@field retryable boolean
---@field details? table

-- ── small helpers ────────────────────────────────────────────────────────────

---@param s string
---@return string  # 64 hex digits
local function sha256(s)
  return fsio.sha256(s)
end

---@param s string
---@return string  # the first 16 hex digits of the SHA-256
local function sha16(s)
  return sha256(s):sub(1, 16)
end

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

---@param s string
---@return string
local function lower_slash(s)
  return (s:gsub("\\", "/"))
end

---`path` relative to the vault, with `/`; `nil` when it is not inside it.
---@param root string
---@param path string
---@return string|nil
local function relative(root, path)
  local p, r = lower_slash(path), lower_slash(root):gsub("/+$", "")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    return p:sub(#r + 2)
  end
  return nil
end

---A `refs:` entry or a path in a message without anything that belongs to this machine.
---@param root string
---@param s string
---@return string
local function safe_path(root, s)
  local text = lower_slash(s)
  local rel = relative(root, text)
  if rel then
    return rel
  end
  if text:match("^%a:/") or text:match("^/") or text:match("^~") then
    return "<external>/" .. (text:match("([^/]+)/*$") or "")
  end
  return text
end

---Free text (a message of the engine) with the vault root named `<vault>`.
---@param root string
---@param s string
---@return string
local function redact(root, s)
  local out = s
  for _, form in ipairs({ root, (root:gsub("/", "\\")) }) do
    local at = 1
    while true do
      local i, j = out:lower():find(form:lower(), at, true)
      if not i then
        break
      end
      out = out:sub(1, i - 1) .. "<vault>" .. out:sub(j + 1)
      at = i + #"<vault>"
    end
  end
  return out
end

local git_cache

---Short commit of this plugin checkout, once per process; "unknown" when there is no git or no checkout.
---@return string
local function engine_git()
  if git_cache then
    return git_cache
  end
  git_cache = "unknown"
  local here = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(fsio.norm(here))))
  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", plugin_root, "rev-parse", "--short", "HEAD" }, { text = true })
      :wait(2000)
  end)
  if ok and res and res.code == 0 then
    local sha = vim.trim(res.stdout or "")
    if sha:match("^%x+$") then
      git_cache = sha
    end
  end
  return git_cache
end

---The time a document is stamped with (UTC, `YYYY-MM-DDTHH:MM:SSZ`). A seam: golden files and reproducible runs set a
---fixed one; nothing else changes it.
---@return string
function M.clock()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---What the head says about the engine (same seam, same reason).
---@return { version: string, git: string, nvim: string }
function M.engine_info()
  return { version = M.ENGINE_VERSION, git = engine_git(), nvim = tostring(vim.version()) }
end

---The head every document starts with.
---@param kind string
---@param root? string
---@return table
function M.head(kind, root)
  return {
    schema = M.SCHEMA,
    plugin = M.PLUGIN,
    kind = kind,
    generated_at = M.clock(),
    vault = json.object({ id = root and vim.fs.basename(root) or "" }),
    engine = json.object(M.engine_info()),
  }
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
    plan = task.plan,
    phase = task.phase,
    done_in = task.done_in,
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
    entry.group = ("%s|%s"):format(
      task.status or "?",
      node.eff_prio and tostring(node.eff_prio) or "-"
    )
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
  table.sort(lines)
  return "rev:" .. sha256(table.concat(lines, "\n")):sub(1, 6)
end

---Put `rev` and `digest` on a document. The digest is the hash of the compact document without `generated_at` and
---without `engine`: it says what the vault contains, so it is the same for the same vault whenever and by whichever
---build of the engine it was made.
---@param doc table
---@param rev? string
---@return table
local function seal(doc, rev)
  doc.rev = rev
  local at, engine = doc.generated_at, doc.engine
  doc.generated_at, doc.engine, doc.digest = nil, nil, nil
  doc.digest = "sha256:" .. sha16(json.encode(doc))
  doc.generated_at, doc.engine = at, engine
  return doc
end

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
  doc.incomplete = view.errors
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

---An error document.
---@param err Tasks.ContractError
---@param root? string
---@return table
function M.error_doc(err, root)
  local doc = M.head("tasks.error", root)
  doc.code = err.code
  doc.message = root and redact(root, err.message) or err.message
  doc.retryable = err.retryable == true
  if err.details then
    doc.details = json.object(err.details)
  end
  return doc
end

---The canonical bytes of a document; one bigger than the limit is an error, never a cut-off document.
---@param doc table
---@param opts? Tasks.JsonOpts
---@return string|nil text
---@return Tasks.ContractError|nil err
function M.encode(doc, opts)
  local ok, text = pcall(json.encode, doc, opts)
  if not ok then
    return nil, { code = "internal", message = tostring(text), retryable = false }
  end
  -- an error document is exempt: the limit must never keep a client from being told why
  if #text > M.MAX_DOC_BYTES and doc.kind ~= "tasks.error" then
    return nil,
      {
        code = "payload_too_large",
        message = ("the document is %d bytes, more than the %d the contract allows; ask for a page or an area"):format(
          #text,
          M.MAX_DOC_BYTES
        ),
        retryable = false,
      }
  end
  return text, nil
end

return M
