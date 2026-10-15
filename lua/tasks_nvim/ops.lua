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
---  - `new` { area, title, fields?, body? }: create a task; `body` (text, at most 20000 characters) replaces the template
---    sections of the file; `fields` are the plain keys (kind, prio, effort, tags, category,
---    severity, value, actor, summary, refs, status, slug). Relations are set afterwards
---  - `reorder` { id, after?, before?, group?, if_match? }: move a task inside its group (`batch.reorder`)
---  - `done` { id, confirm, done_in?, remind? }: finish a task. `confirm` is the token of `done_preview` for the version of the
---    file that was shown; a task that changed since is a `conflict`
---  - `tick_step` { id, n, done?, if_match? }: tick (`done` true, the default) or untick step `n` of the `## Plan` section of an
---    open task; a dropped step is refused; the answer has an `inverse`
---  - `append_note` { id, text, if_match? }: add one dated line to the notes of an open task (`## Notizen` / `## Notes`,
---    made when missing); no `inverse`
---  - `set_body` { id, body, if_match? }: replace the text below the frontmatter of an open task (at most 100000 characters, no
---    control character but the line break and the tab; an empty text is allowed and leaves one blank line); the answer has an
---    `inverse` (the old text) when the old text is within the same limit
---  - `reopen` { id, status?, if_match? }: bring a finished task back to `ROADMAP/tasks` (status `open`, or the one
---    given), take its row out of the Backlog README; an open task is `unchanged`; a folder task is refused; no `inverse`
---  - `move_area` { id, to_area, if_match? }: a dry run answers the report of `moves.preview` (new id, conflicts, what names
---    the old id); without it the open task moves to the other area under the same slug and every `blocked_by`, `after`,
---    `refs` and plan `target` that named the old id names the new one, all or nothing (`moves.move`); the answer has an
---    `inverse` (`move_area` back, with the version of the moved file)
---  - `plan_new` { area, title, areas?, target?, phases?, gate?, status?, summary?, slug? }: make a plan file; a dry run names
---    the id it would get and whether the slug had to be changed (`plans.new`)
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
local errors = require("lib.nvim.contract.errors")
local contract_ops = require("lib.nvim.contract.ops")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local json = require("lib.nvim.json.canonical")
local model = require("tasks_nvim.model")
local moves = require("tasks_nvim.moves")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local steps = require("tasks_nvim.steps")
local vault = require("tasks_nvim.vault")

local M = {}

---The write door (`lib.nvim.contract.ops`), made at the bottom of this file.
---@type Lib.Contract.Ops
local door

---The operations, in the order the documentation names them.
M.OPS = {
  "set",
  "new",
  "reorder",
  "done",
  "move_area",
  "plan_new",
  "tick_step",
  "append_note",
  "reopen",
  "set_body",
}

---Longest `client_op_id`.
M.MAX_CLIENT_OP_ID = 64

---Longest `body` of `new`, in characters.
M.MAX_BODY = 20000

---Longest `body` of `set_body`, in characters (the text a task file may grow to is not bounded by `new`).
M.MAX_SET_BODY = 100000

---Longest entry of a list value (a tag, a ref, an id).
M.MAX_ENTRY = 300

---What each operation may carry, and of what type. A field that is not listed is refused.
---@type table<string, table<string, string>>
local FIELDS = {
  set = { id = "string", patch = "object", if_match = "string", expect = "object" },
  new = { area = "string", title = "string", fields = "object", body = "string" },
  reorder = {
    id = "string",
    after = "string",
    before = "string",
    group = "string",
    if_match = "string",
  },
  done = { id = "string", confirm = "string", done_in = "strings", remind = "string" },
  move_area = { id = "string", to_area = "string", if_match = "string" },
  tick_step = { id = "string", n = "integer", done = "boolean", if_match = "string" },
  append_note = { id = "string", text = "string", if_match = "string" },
  reopen = { id = "string", status = "string", if_match = "string" },
  set_body = { id = "string", body = "string", if_match = "string" },
  plan_new = {
    area = "string",
    title = "string",
    areas = "strings",
    target = "string",
    phases = "strings",
    gate = "string",
    status = "string",
    summary = "string",
    slug = "string",
  },
}

---@param names table<string, any>
---@return string
local function sorted_names(names)
  local out = vim.tbl_keys(names)
  table.sort(out)
  return table.concat(out, ", ")
end

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

-- ── what a front end may write ───────────────────────────────────────────────

-- `has_control` and `too_long` are the contract's own (lib.nvim.contract.ops): a NUL byte, a raw C1 byte and invalid
-- UTF-8 are refused there, and the echo of a refused value is printable. One rule for every front end, not a copy.
local too_long = contract_ops.too_long

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

local has_control = contract_ops.has_control

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
  return door.failure(ctx.root, err, info)
end

---@param code string
---@param message string
---@param details? table
---@return table
local function refuse(code, message, details)
  return door.refuse(code, message, details)
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
    -- A reminder may be set and taken away on a finished task (it is bookkeeping); nothing else of it may change.
    local only_remind = next(op.patch) == "remind" and next(op.patch, "remind") == nil
    task = only_remind and scan.find_done(id, { root = ctx.root }) or nil
    if not task then
      return failure(ctx, ferr)
    end
  end
  for _, kv in ipairs(pairs_) do
    -- first the characters, then the length: `strchars` cannot take a NUL byte
    if has_control(kv[2]) then
      return refuse("invalid_argument", kv[1] .. " contains a control character")
    end
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
    -- the overview of an area lists the open tasks: a finished one is not in it
    if task.location ~= "backlog" then
      ctx.touched[task.area] = true
    end
    entry.inverse = json.object({
      op = "set",
      id = r.id,
      patch = r.before,
      if_match = r.etag_after,
    })
  end
  return entry
end

---The answer of an operation that changed the text of one task (`tick_step`, `append_note`).
---@param ctx Tasks.OpsCtx
---@param r table  # What `mutate.edit_text` gave.
---@return table entry
local function text_entry(ctx, r)
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    ctx.touched[r.area] = true
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_tick_step(op, ctx)
  if op.id == nil or op.n == nil then
    return refuse("invalid_argument", "tick_step needs id and n")
  end
  local done = op.done ~= false
  local r, err, info = mutate.edit_text(op.id, function(text)
    local new_text, step, serr = steps.set_step(text, op.n, done)
    if not new_text then
      return nil, serr
    end
    return new_text, nil, { was = step and step.done or false }
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = text_entry(ctx, r)
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "tick_step",
      id = r.id,
      n = op.n,
      done = r.extra and r.extra.was or false,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_reopen(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "reopen needs id")
  end
  local r, err, info = mutate.reopen(op.id, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    status = op.status,
    if_match = op.if_match,
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
  if r.path and r.changed then
    entry.file = rel(ctx, r.path)
  end
  if #r.notes > 0 then
    entry.notes = r.notes
  end
  if r.changed and not ctx.dry then
    ctx.touched[r.area] = true
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_append_note(op, ctx)
  if op.id == nil or op.text == nil then
    return refuse("invalid_argument", "append_note needs id and text")
  end
  -- the steps module refuses what is not one line; the rest of what a front end may not write is judged here, as for
  -- every other text (the 8-bit controls and the Unicode line separators end a line in other tools)
  if has_control(op.text) then
    return refuse("invalid_argument", "text contains a control character")
  end
  local r, err, info = mutate.edit_text(op.id, function(text)
    return steps.add_note(text, op.text, ctx.today)
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return text_entry(ctx, r)
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_set_body(op, ctx)
  if op.id == nil or op.body == nil then
    return refuse("invalid_argument", "set_body needs id and body")
  end
  if has_control(op.body) then
    return refuse("invalid_argument", "body contains a control character")
  end
  if too_long(op.body, M.MAX_SET_BODY) then
    return refuse("payload_too_large", ("body is longer than %d characters"):format(M.MAX_SET_BODY))
  end
  local r, err, info = mutate.edit_text(op.id, function(text)
    local parsed = fm.parse(text)
    if not parsed or not parsed.has_block or parsed.unterminated then
      return nil, "the file has no frontmatter block to write below"
    end
    local old = fsio.lf(parsed.body)
    local trimmed = vim.trim(fsio.lf(op.body))
    local new_body = "\n" .. (trimmed ~= "" and (trimmed .. "\n") or "")
    if parsed.eol == "\r\n" then
      new_body = new_body:gsub("\n", "\r\n")
    end
    parsed.body = new_body
    return fm.serialize(parsed), nil, { old = old }
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = text_entry(ctx, r)
  -- the way back is the old text; none when it could not be sent again (too long, a control character)
  local old = r.extra and r.extra.old
  if
    r.changed
    and not ctx.dry
    and type(old) == "string"
    and not has_control(old)
    and not too_long(old, M.MAX_SET_BODY)
  then
    entry.inverse = json.object({
      op = "set_body",
      id = r.id,
      body = old,
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
  -- first the characters, then the length: `strchars` cannot take a NUL byte
  if has_control(op.area) then
    return refuse("invalid_argument", "area contains a control character")
  end
  if has_control(op.title) then
    return refuse("invalid_argument", "title contains a control character")
  end
  for key, value in pairs(fields) do
    if has_control(value) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  if op.body ~= nil and has_control(op.body) then
    return refuse("invalid_argument", "body contains a control character")
  end
  local over = over_limit("title", op.title)
  if too_long(op.body, M.MAX_BODY) then
    over = ("body is longer than %d characters"):format(M.MAX_BODY)
  end
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
      body = op.body,
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
    -- The way back that puts the moved task behind its old neighbour restores the place, not the numbers: a task
    -- that had no `order` keeps one, and the neighbours the move numbered stay numbered. `restore` gives every file
    -- the move wrote its old `order` back (also a single one).
    if #r.restore > 0 then
      local restore = {}
      for _, w in ipairs(r.restore) do
        restore[#restore + 1] = json.object({
          op = "set",
          id = w.id,
          patch = json.object({ order = w.was ~= nil and batch.order_text(w.was) or vim.NIL }),
          if_match = w.etag_after,
        })
      end
      entry.restore = json.array(restore)
    end
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
  if has_control(op.done_in) then
    return refuse("invalid_argument", "done_in contains a control character")
  end
  if op.remind ~= nil then
    local _, rerr = model.resolve_remind(op.remind, ctx.today)
    if rerr then
      return refuse("invalid_argument", rerr)
    end
  end
  local flow, err, info = done_flow.run(op.id, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = etag,
    done_in = op.done_in,
    remind = op.remind,
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
    local r, err, info = moves.move(op.id, op.to_area, {
      root = ctx.root,
      today = ctx.today,
      index = false,
      if_match = op.if_match,
    })
    if not r then
      return mutate_failure(ctx, err, info)
    end
    ctx.touched[r.from_area] = true
    ctx.touched[r.area] = true
    local changed = { r.id, r.new_id }
    local rewritten = {}
    for _, w in ipairs(r.rewritten) do
      changed[#changed + 1] = w.id
      rewritten[#rewritten + 1] = { kind = w.kind, id = w.id }
    end
    local entry = {
      ok = true,
      id = r.id,
      outcome = "moved",
      new_id = r.new_id,
      etag_after = r.etag_after,
      etag_before = r.etag_before,
      file = rel(ctx, r.to),
      rewritten = rewritten,
      changed_ids = changed,
      inverse = json.object({
        op = "move_area",
        id = r.new_id,
        to_area = r.from_area,
        if_match = r.etag_after,
      }),
    }
    if #r.notes > 0 then
      entry.notes = r.notes
    end
    return entry
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

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_plan_new(op, ctx)
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", "plan_new needs area and title")
  end
  for _, key in ipairs({
    "area",
    "title",
    "summary",
    "slug",
    "target",
    "gate",
    "status",
    "areas",
    "phases",
  }) do
    if has_control(op[key]) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  local over = over_limit("title", op.title)
    or over_limit("area", op.area)
    or (op.slug and over_limit("slug", op.slug))
    or (op.target and over_limit("target", op.target))
    or (op.summary and over_limit("summary", op.summary))
    or (op.areas and over_limit("areas", op.areas))
    or (op.phases and over_limit("phases", op.phases))
  if over then
    return refuse("payload_too_large", over)
  end
  if type(op.summary) == "string" and op.summary:find("[\r\n]") then
    return refuse("invalid_argument", "summary must be one line")
  end
  local r, err, info = require("tasks_nvim.plans").new(op.area, {
    root = ctx.root,
    today = ctx.today,
    title = op.title,
    areas = op.areas,
    target = op.target,
    phases = op.phases,
    gate = op.gate,
    status = op.status,
    summary = op.summary,
    slug = op.slug,
    dry_run = ctx.dry,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    slug = r.slug,
    renamed = r.renamed,
    changed_ids = ctx.dry and {} or { r.id },
  }
end

---@type table<string, fun(op: table, ctx: Tasks.OpsCtx): table>
local HANDLERS = {
  set = do_set,
  new = do_new,
  reorder = do_reorder,
  done = do_done,
  move_area = do_move_area,
  plan_new = do_plan_new,
  tick_step = do_tick_step,
  append_note = do_append_note,
  reopen = do_reopen,
  set_body = do_set_body,
}

-- ── the request ──────────────────────────────────────────────────────────────

---The door: shape check, the loop over the operations, the `tasks.result` document and the entries a document
---cannot hold are `lib.nvim.contract.ops`'s; what an operation DOES is a handler above.
local ops = {}
for _, name in ipairs(M.OPS) do
  ops[name] = { fields = FIELDS[name], run = HANDLERS[name] }
end

door = contract_ops.make({
  doc = contract.doc,
  order = M.OPS,
  ops = ops,
  limits = { batch_ops = contract.LIMITS.batch_ops, client_op_id = M.MAX_CLIENT_OP_ID },
  patterns = contract.ERROR_PATTERNS,
  ---@param params table
  ---@param opts { root?: string, today?: string }
  ---@return Tasks.OpsCtx|nil ctx
  ---@return Tasks.ContractError|string|nil err
  context = function(params, opts)
    local root, rerr = vault.root(opts)
    if not root then
      return nil, rerr
    end
    local today = opts.today or model.today()
    if not model.is_date(today) then
      return nil, errors.fail("invalid_argument", "today is not a date (YYYY-MM-DD)")
    end
    return { root = root, today = today, dry = params.dry_run == true, touched = {} }
  end,
  ---The index of every area that changed, once.
  ---@param ctx Tasks.OpsCtx
  ---@param results table[]
  finish = function(ctx, results)
    if ctx.dry then
      return
    end
    local areas = vim.tbl_keys(ctx.touched)
    table.sort(areas)
    local by_area = {}
    for _, area in ipairs(areas) do
      local res, ierr = index.write_area(area, { root = ctx.root })
      by_area[area] = res and { action = res.action }
        or { action = "error", error = contract.redact(ctx.root, tostring(ierr)) }
    end
    for _, entry in ipairs(results) do
      local area = entry.id and entry.id:match("^([^/]+)/")
      if entry.ok and by_area[area] and #entry.changed_ids > 0 then
        entry.index = json.object(by_area[area])
      end
    end
  end,
})

---Run a request and answer it with a `tasks.result` document.
---@param params { client_op_id?: string, dry_run?: boolean, ops?: table[] }  # The request without its `schema`.
---@param opts? { root?: string, today?: string }
---@return table|nil doc
---@return Lib.Contract.Error|Tasks.ContractError|string|nil err
function M.run(params, opts)
  return door.run(params, opts)
end

return M
