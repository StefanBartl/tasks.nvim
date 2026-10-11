---@module 'tasks_nvim.ops'
---@brief The write door of the machine contract, `tasks-ops/1`: a list of operations, answered with one `tasks.result`.
---@description
--- A front end that is not the editor (an app, an agent) changes the vault only through here. A request is
---
---   { "schema": 1, "client_op_id": "c-81f2", "dry_run": false, "ops": [ { "op": "set", ... }, ... ] }
---
--- and the answer is a `tasks.result` with one entry per operation: what happened (`changed`, `unchanged`, `created`,
--- `done`, or `failed` with an error that says why), the version of the file before and after (`etag_before`,
--- `etag_after`), and for an undo the `inverse` operation. Operations:
---
---  - `set` { id, patch, if_match?, expect? }: change frontmatter keys; `null` in the patch removes a key.
---    `if_match` (the task's `etag`) and `expect` ({ key, value }) are checked UNDER the file lock, so two writers
---    cannot both win; a change of the relations (`blocked_by`, `after`, `plan`, `phase`) is judged first
---    (`tasks_nvim.edges`)
---  - `new` { area, title, fields? }: create a task; `fields` are the plain keys (kind, prio, effort, tags, category,
---    severity, value, actor, summary, refs, status, slug). Relations are set afterwards
---  - `reorder` { id, after?, before?, group?, if_match? }: move a task inside its group (`batch.reorder`)
---  - `done` { id, confirm, done_in? }: finish a task. `confirm` is the token of `done_preview` for the version of the
---    file that was shown; a task that changed since is a `conflict`
---  - `move_area` { id, to_area }: only as a dry run in this version (the report of `moves.preview`)
---
--- Rules the door keeps:
---  - **the shape is checked first**, for the whole request: an unknown operation or field, a wrong type, too many
---    operations is `invalid_argument` and nothing runs. After that every operation runs on its own: one that fails
---    does not stop the others (this is NOT all-or-nothing, and the answer never says "ok" for a part);
---  - **`dry_run`** checks everything - the patch, the version, the relations, the slug - and writes nothing;
---  - **limits are kept on writing** (title 300, summary 1000, lists of 100, 300 characters an entry), and a `refs`
---    entry that is new must be a plain relative path (no `..`, no drive or network prefix, no colon but a line
---    suffix); entries the task already has stay as they are;
---  - **no path of this machine in an error**, ids only;
---  - the index of an area is written once at the end, however many tasks of it changed.
---
--- Not its job: parsing the request line (`api`), the documents of the read side (`contract`).

local batch = require("tasks_nvim.batch")
local contract = require("tasks_nvim.contract")
local done_flow = require("tasks_nvim.done_flow")
local edges = require("tasks_nvim.edges")
local errors = require("tasks_nvim.errors")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local json = require("tasks_nvim.json")
local model = require("tasks_nvim.model")
local moves = require("tasks_nvim.moves")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---The operations, in the order the documentation names them.
M.OPS = { "set", "new", "reorder", "done", "move_area" }

---Longest `client_op_id`.
M.MAX_CLIENT_OP_ID = 64

---Longest entry of a list value (a tag, a ref, an id).
M.MAX_ENTRY = 300

---What each operation may carry, and of what type. A field that is not listed is refused.
---@type table<string, table<string, string>>
local FIELDS = {
  set = { id = "string", patch = "object", if_match = "string", expect = "object" },
  new = { area = "string", title = "string", fields = "object", body = "null" },
  reorder = {
    id = "string",
    after = "string",
    before = "string",
    group = "string",
    if_match = "string",
  },
  done = { id = "string", confirm = "string", done_in = "strings" },
  move_area = { id = "string", to_area = "string" },
}

---The plain keys `new` takes in `fields`.
---@type table<string, boolean>
local NEW_FIELDS = {
  kind = true,
  prio = true,
  effort = true,
  tags = true,
  category = true,
  severity = true,
  value = true,
  actor = true,
  summary = true,
  refs = true,
  status = true,
  slug = true,
}

---@param value any
---@param kind string
---@return boolean
local function typed(value, kind)
  if kind == "string" then
    return type(value) == "string"
  elseif kind == "object" then
    return type(value) == "table" and (next(value) == nil or not vim.islist(value))
  elseif kind == "strings" then
    if type(value) == "string" then
      return true
    end
    if type(value) ~= "table" or not vim.islist(value) then
      return false
    end
    for _, v in ipairs(value) do
      if type(v) ~= "string" then
        return false
      end
    end
    return true
  elseif kind == "null" then
    return false -- only ever absent (a `body` is a later version)
  end
  return false
end

---@param names table<string, any>
---@return string
local function sorted_names(names)
  local out = vim.tbl_keys(names)
  table.sort(out)
  return table.concat(out, ", ")
end

---Check the shape of a request, all of it, before anything runs.
---@param params { client_op_id?: string, dry_run?: boolean, ops?: table[] }
---@return Tasks.ContractError|nil err
local function check_shape(params)
  local list = params.ops
  if list == nil then
    return errors.fail("invalid_argument", "ops: the list of operations is missing")
  end
  if #list == 0 then
    return errors.fail("invalid_argument", "ops: the list of operations is empty")
  end
  if #list > contract.LIMITS.batch_ops then
    return errors.fail(
      "payload_too_large",
      ("ops: at most %d operations in one request, got %d"):format(contract.LIMITS.batch_ops, #list)
    )
  end
  local cid = params.client_op_id
  if cid ~= nil and (#cid < 1 or #cid > M.MAX_CLIENT_OP_ID or not cid:match("^[%w._:%-]+$")) then
    return errors.fail(
      "invalid_argument",
      ("client_op_id must be 1 to %d characters of letters, digits and . _ : -"):format(
        M.MAX_CLIENT_OP_ID
      )
    )
  end
  for i, op in ipairs(list) do
    local name = op.op
    if type(name) ~= "string" or not FIELDS[name] then
      return errors.fail(
        "invalid_argument",
        ("ops[%d]: unknown operation %s (operations: %s)"):format(
          i,
          vim.inspect(name),
          table.concat(M.OPS, ", ")
        )
      )
    end
    for key, value in pairs(op) do
      if key ~= "op" then
        local kind = FIELDS[name][key]
        if not kind then
          return errors.fail(
            "invalid_argument",
            ("ops[%d] (%s): unknown field '%s' (fields: %s)"):format(
              i,
              name,
              tostring(key),
              sorted_names(FIELDS[name])
            )
          )
        end
        -- a JSON `null` for a field is the same as leaving it out
        if value ~= vim.NIL and not typed(value, kind) then
          return errors.fail(
            "invalid_argument",
            ("ops[%d] (%s): %s must be %s"):format(
              i,
              name,
              key,
              kind == "object" and "an object"
                or (kind == "strings" and "text or a list of text" or "text")
            )
          )
        end
      end
    end
  end
  return nil
end

-- ── what a front end may write ───────────────────────────────────────────────

---@param s any
---@param max integer
---@return boolean
local function too_long(s, max)
  return type(s) == "string" and vim.fn.strchars(s) > max
end

---A value over the limits the contract keeps, as a message; nil when it is fine.
---@param key string
---@param value any
---@return string|nil
local function over_limit(key, value)
  local limits = contract.LIMITS
  if key == "title" and too_long(value, limits.title) then
    return ("title is longer than %d characters"):format(limits.title)
  elseif key == "summary" and too_long(value, limits.summary) then
    return ("summary is longer than %d characters"):format(limits.summary)
  elseif type(value) == "table" and value ~= vim.NIL then
    if #value > limits.list_items then
      return ("%s has more than %d entries"):format(key, limits.list_items)
    end
    for _, entry in ipairs(value) do
      if too_long(entry, M.MAX_ENTRY) then
        return ("an entry of %s is longer than %d characters"):format(key, M.MAX_ENTRY)
      end
    end
  elseif too_long(value, M.MAX_ENTRY) and key ~= "title" and key ~= "summary" then
    return ("%s is longer than %d characters"):format(key, M.MAX_ENTRY)
  end
  return nil
end

---Why a `refs` entry may not be written by a front end that is not the author, or nil: a plain relative path (with an
---optional line or range suffix), a `repo@commit` or an id. No `..`, no drive or network prefix, no absolute path,
---no control character, no colon but the position suffix.
---@param ref string
---@return string|nil reason
local function bad_ref(ref)
  if ref:find("%c") then
    return "a control character"
  end
  if ref:match("^%a:") then
    return "a drive prefix"
  end
  if ref:match("^[/\\]") then
    return "an absolute or network path"
  end
  for seg in (ref:gsub("\\", "/")):gmatch("[^/]+") do
    if seg == ".." then
      return "a '..' segment"
    end
  end
  if ref:find(":", 1, true) then
    local path = ref:match("^(.-):%d+:%d+$")
      or ref:match("^(.-):%d+%-%d+$")
      or ref:match("^(.-):%d+$")
    if not path or path:find(":", 1, true) then
      return "a colon that is not a line suffix"
    end
  end
  return nil
end

---@param s string
---@return string
local function clip(s)
  return vim.fn.strchars(s) > 40 and (vim.fn.strcharpart(s, 0, 39) .. "\226\128\166") or s
end

-- ── one operation ────────────────────────────────────────────────────────────

---@class Tasks.OpsCtx
---@field root string
---@field today string
---@field dry boolean
---@field touched table<string, boolean>   # Areas whose index must be written.

---The entry of an operation that did not happen.
---@param ctx Tasks.OpsCtx
---@param err any
---@param info? table
---@return table
local function failure(ctx, err, info)
  local e = vim.deepcopy(errors.classify(err, info))
  e.message = contract.redact(ctx.root, e.message)
  if e.details then
    e.details = json.object(e.details)
  end
  return { ok = false, outcome = "failed", error = e }
end

---@param code string
---@param message string
---@param details? table
---@return table
local function refuse(code, message, details)
  local e = errors.fail(code, message)
  e.details = details and json.object(details) or nil
  return { ok = false, outcome = "failed", error = e }
end

---A failure from `mutate` whose reason has no code: its validation messages are all about the request.
---@param ctx Tasks.OpsCtx
---@param err any
---@param info? table
---@return table
local function mutate_failure(ctx, err, info)
  local entry = failure(ctx, err, info)
  if entry.error.code == "internal" then
    entry.error.code = "invalid_argument"
  end
  return entry
end

---@param ctx Tasks.OpsCtx
---@param path string
---@return string
local function rel(ctx, path)
  return contract.relative(ctx.root, path) or vim.fs.basename(path)
end

---@param path string
---@return string|nil
local function etag_of_file(path)
  local text = fsio.read(path)
  return text and fsio.etag(text) or nil
end

---The relations a patch sets, in the shape `edges.validate` takes.
---@param pairs_ table[]
---@return Tasks.EdgeProposal
local function proposal_of(pairs_)
  ---@type Tasks.EdgeProposal
  local proposal = {}
  for _, kv in ipairs(pairs_) do
    local key, value = kv[1], kv[2]
    if key == "blocked_by" or key == "after" then
      proposal[key] = value == vim.NIL and {} or (type(value) == "table" and value or { value })
    elseif key == "plan" or key == "phase" then
      -- `false` removes the relation (`x and false or y` would yield `y`, so spell it out)
      if value == vim.NIL then
        proposal[key] = false
      else
        proposal[key] = value
      end
    end
  end
  return proposal
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_set(op, ctx)
  local id = op.id
  if id == nil or op.patch == nil then
    return refuse("invalid_argument", "set needs id and patch")
  end
  local pairs_, perr = mutate.check_patch(op.patch)
  if not pairs_ then
    return refuse("invalid_argument", tostring(perr))
  end
  local task, ferr = scan.find(id, { root = ctx.root })
  if not task then
    return failure(ctx, ferr)
  end
  for _, kv in ipairs(pairs_) do
    local over = over_limit(kv[1], kv[2])
    if over then
      return refuse("payload_too_large", over)
    end
    if kv[1] == "refs" and kv[2] ~= vim.NIL then
      local known = {}
      for _, r in ipairs(task.refs or {}) do
        known[r] = true
      end
      for _, ref in ipairs(kv[2]) do
        local why = not known[ref] and bad_ref(ref)
        if why then
          return refuse("invalid_argument", ("refs: '%s' has %s"):format(clip(ref), why))
        end
      end
    end
  end
  local expect
  if op.expect ~= nil then
    local key = op.expect.key
    if type(key) ~= "string" or not vim.tbl_contains(mutate.SETTABLE, key) then
      return refuse("invalid_argument", "expect.key must be one of the keys set can change")
    end
    local value = op.expect.value
    expect = { key = key, value = value ~= vim.NIL and value or nil }
  end
  local proposal = proposal_of(pairs_)
  if next(proposal) ~= nil then
    local problems, eerr = edges.validate(task.id, proposal, { root = ctx.root })
    if not problems then
      return failure(ctx, eerr)
    end
    if #problems > 0 then
      return refuse("invalid_argument", problems[1].message, { problems = problems })
    end
  end
  local r, err, info = mutate.set(id, op.patch, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    expect = expect,
    dry_run = ctx.dry,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    ctx.touched[task.area] = true
    entry.inverse = json.object({
      op = "set",
      id = r.id,
      patch = r.before,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_new(op, ctx)
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", "new needs area and title")
  end
  local fields = {}
  for key, value in pairs(op.fields or {}) do
    if not NEW_FIELDS[key] then
      return refuse(
        "invalid_argument",
        ("fields: unknown field '%s' (fields: %s)"):format(tostring(key), sorted_names(NEW_FIELDS))
      )
    end
    if value ~= vim.NIL then
      fields[key] = value
    end
  end
  local over = over_limit("title", op.title)
  for key, value in pairs(fields) do
    over = over or over_limit(key, value)
  end
  if over then
    return refuse("payload_too_large", over)
  end
  if type(fields.refs) == "table" then
    for _, ref in ipairs(fields.refs) do
      local why = type(ref) == "string" and bad_ref(ref)
      if why then
        return refuse("invalid_argument", ("refs: '%s' has %s"):format(clip(ref), why))
      end
    end
  end
  local r, err, info = mutate.new(
    op.area,
    vim.tbl_extend("force", fields, {
      root = ctx.root,
      today = ctx.today,
      index = false,
      title = op.title,
      dry_run = ctx.dry,
    })
  )
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    changed_ids = ctx.dry and {} or { r.id },
  }
  if not ctx.dry then
    ctx.touched[r.area] = true
    entry.etag_after = etag_of_file(r.path)
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_reorder(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "reorder needs id")
  end
  local r, err, info = batch.reorder(op.id, {
    after = op.after,
    before = op.before,
    group = op.group,
    if_match = op.if_match,
  }, { root = ctx.root, today = ctx.today, index = false, dry_run = ctx.dry })
  if not r then
    return failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    group = r.group,
    renumbered = r.renumbered,
    writes = #r.writes,
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = ctx.dry and {} or r.changed_ids,
  }
  if r.changed and not ctx.dry then
    for _, area in ipairs(r.areas) do
      ctx.touched[area] = true
    end
    entry.inverse = json.object({
      op = "reorder",
      id = r.id,
      after = r.inverse and r.inverse.after,
      before = r.inverse and r.inverse.before,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_done(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "done needs id")
  end
  if ctx.dry then
    local pv, err, info = done_flow.preview(op.id, { root = ctx.root, today = ctx.today })
    if not pv then
      return failure(ctx, err, info)
    end
    return {
      ok = true,
      id = pv.id,
      outcome = pv.already and "unchanged" or "would_done",
      to = rel(ctx, pv.to),
      etag_before = pv.etag,
      changed_ids = {},
    }
  end
  if op.confirm == nil then
    return refuse(
      "invalid_argument",
      "done needs the confirm token of done_preview for the version of the task that was shown"
    )
  end
  local etag = mutate.confirm_etag(op.id, op.confirm)
  if not etag then
    return refuse("invalid_argument", "the confirm token is not one for " .. op.id)
  end
  local flow, err, info = done_flow.run(op.id, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = etag,
    done_in = op.done_in,
    pick_next = false,
  })
  if not flow then
    return failure(ctx, err, info)
  end
  local done = flow.done
  local area = done.area
  if area and not done.already then
    ctx.touched[area] = true
  end
  local changed = { done.id }
  for _, plan_id in ipairs(flow.plans_closed) do
    changed[#changed + 1] = plan_id
  end
  local notes = {}
  for _, note in ipairs(flow.notes) do
    notes[#notes + 1] = contract.redact(ctx.root, note)
  end
  return {
    ok = true,
    id = done.id,
    outcome = done.already and "unchanged" or "done",
    to = done.to and rel(ctx, done.to) or nil,
    etag_before = etag,
    steps_ticked = flow.steps_ticked,
    plans_closed = flow.plans_closed,
    notes = notes,
    changed_ids = done.already and {} or changed,
  }
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_move_area(op, ctx)
  if op.id == nil or op.to_area == nil then
    return refuse("invalid_argument", "move_area needs id and to_area")
  end
  if not ctx.dry then
    return refuse(
      "invalid_argument",
      "move_area can only be asked as a dry run in this version (dry_run: true): the report says what the move would break"
    )
  end
  local report, err, info = moves.preview(op.id, op.to_area, { root = ctx.root })
  if not report then
    return failure(ctx, err, info)
  end
  local conflicts = {}
  for _, c in ipairs(report.conflicts) do
    conflicts[#conflicts + 1] = { code = c.code, message = c.message }
  end
  local references = {}
  for _, ref in ipairs(report.references) do
    references[#references + 1] = {
      kind = ref.kind,
      id = ref.id,
      path = ref.path and rel(ctx, ref.path) or nil,
    }
  end
  return {
    ok = report.ok,
    id = report.id,
    outcome = report.ok and "would_move" or "blocked",
    move = json.object({
      new_id = report.new_id,
      to_area = report.to_area,
      from = rel(ctx, report.from),
      to = rel(ctx, report.to),
      folder = report.folder,
      conflicts = conflicts,
      references = references,
      notes = report.notes,
    }),
    changed_ids = {},
  }
end

---@type table<string, fun(op: table, ctx: Tasks.OpsCtx): table>
local HANDLERS = {
  set = do_set,
  new = do_new,
  reorder = do_reorder,
  done = do_done,
  move_area = do_move_area,
}

-- ── the request ──────────────────────────────────────────────────────────────

---Run a request and answer it with a `tasks.result` document.
---@param params { client_op_id?: string, dry_run?: boolean, ops?: table[] }  # The request without its `schema`.
---@param opts? { root?: string, today?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.run(params, opts)
  opts = opts or {}
  local shape = check_shape(params)
  if shape then
    return nil, shape
  end
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, errors.fail("invalid_argument", "today is not a date (YYYY-MM-DD)")
  end
  ---@type Tasks.OpsCtx
  local ctx = { root = root, today = today, dry = params.dry_run == true, touched = {} }

  local results = {}
  local all_ok = true
  local list = params.ops or {}
  for i, op in ipairs(list) do
    -- a JSON `null` for a field of the operation is the same as leaving it out
    for key, value in pairs(op) do
      if value == vim.NIL then
        op[key] = nil
      end
    end
    local ran, entry = pcall(HANDLERS[op.op], op, ctx)
    if not ran then
      entry = refuse("internal", contract.redact(root, tostring(entry)))
    end
    entry.n = i
    entry.op = op.op
    entry.changed_ids = entry.changed_ids or {}
    if not entry.ok then
      all_ok = false
    end
    results[#results + 1] = entry
  end

  -- the index of every area that changed, once
  if not ctx.dry then
    local areas = vim.tbl_keys(ctx.touched)
    table.sort(areas)
    local by_area = {}
    for _, area in ipairs(areas) do
      local res, ierr = index.write_area(area, { root = root })
      by_area[area] = res and { action = res.action }
        or { action = "error", error = contract.redact(root, tostring(ierr)) }
    end
    for _, entry in ipairs(results) do
      local area = entry.id and entry.id:match("^([^/]+)/")
      if entry.ok and by_area[area] and #entry.changed_ids > 0 then
        entry.index = json.object(by_area[area])
      end
    end
  end

  local doc = contract.head("tasks.result", root)
  doc.client_op_id = params.client_op_id
  doc.dry_run = ctx.dry
  doc.ok = all_ok
  doc.results = results
  return contract.seal(doc, nil), nil
end

return M
