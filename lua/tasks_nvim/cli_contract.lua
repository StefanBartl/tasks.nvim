---@module 'tasks_nvim.cli_contract'
---@brief The command-line side of the machine contract: `call`, `areas`, `show`, `plans`, `list --done` and the JSON
---forms of `list` and `next`.
---@description
--- A thin layer over `tasks_nvim.api`: the documents and their errors are the contract's, this module only maps
--- command-line words to a request and the answer to an exit code. `cli.lua` registers it (`register`); the helpers it
--- needs from `cli.lua` (area argument, filter parsing) come in as `helpers`, so the two files need not require each
--- other.
---
---  - `call <method> [--params=<json>|-] [--pretty]`: any method of the dispatcher (`-`: the JSON comes on stdin; for `ops`
---    it is the whole request, for the others the `params`), the document on stdout. Exit 0 for an
---    answer, 2 for `invalid_argument`, 1 for any other error; an error is a `tasks.error` document, also on stdout.
---  - `--capabilities`: the `tasks.hello` document (`call hello`)
---  - `list --format=json [--limit=N] [--offset=N]`: the `tasks.list` document of the same filters as the text form; the
---    order is the plan's, `--sort` has no meaning there and is refused
---  - `next --format=json`, `areas --format=json|tsv`, `show <id> [--format=json|text]`, `plans [area]`
---  - `list --done`: the finished tasks of the Backlogs (tab-separated, like the open ones)
---
--- Reads, except `call ops` (the write door; exit 1 when an operation failed). Not its job: the documents (`contract`),
--- the request check (`api`).

local api = require("tasks_nvim.api")
local contract = require("tasks_nvim.contract")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.CliContractHelpers
---@field area_arg fun(ctx: Tasks.CliCtx, name: string): string|nil, boolean
---@field filter_from fun(opt: table): Tasks.Filter|nil, string|nil
---@field to_int fun(text: string, flag: string): integer|nil, string|nil
---@field cellv fun(s: any): string

---The exit code of an answer: 0, or 2 for a bad request and 1 for everything else.
---@param code string|nil
---@return integer
local function exit_code(code)
  if code == nil then
    return 0
  end
  return code == "invalid_argument" and 2 or 1
end

---Print a document (or the error document) and return the exit code.
---@param ctx Tasks.CliCtx
---@param doc table|nil
---@param err Tasks.ContractError|string|nil
---@param opts? { pretty?: boolean }
---@return integer
local function emit(ctx, doc, err, opts)
  local indent = opts and opts.pretty and 2 or nil
  if doc then
    local text, eerr = contract.encode(doc, { indent = indent })
    if text then
      ctx.out(text .. "\n")
      return 0
    end
    err = eerr
  end
  local e = type(err) == "table" and err
    or { code = "internal", message = tostring(err), retryable = false }
  local root = vault.root({ root = ctx.eo.root })
  local text = contract.encode(contract.error_doc(e, root), { indent = indent })
  ctx.out((text or "{}") .. "\n")
  return exit_code(e.code)
end

---`--format=json` for an answer that failed before a document existed: the error document, not a text line.
---@param ctx Tasks.CliCtx
---@param code string
---@param message string
---@return integer
local function usage_error(ctx, code, message)
  return emit(ctx, nil, { code = code, message = message, retryable = false })
end

-- ── call ─────────────────────────────────────────────────────────────────────

---@param ctx Tasks.CliCtx
---@return integer
local function run_call(ctx)
  local args = ctx.args
  local method = args.pos[1]
  if not method or #args.pos > 1 then
    ctx.warn(
      "error: usage: call <method> [--params=<json>|-] [--pretty]   (methods: "
        .. table.concat(api.methods(), ", ")
        .. ")"
    )
    return 2
  end
  local request = nil
  local params = args.opt.params
  if params == "-" then
    -- the JSON on stdin: no limit of the command line, the shell never sees it. One byte more than the limit is read,
    -- so a request that is too big is told so instead of being cut off and misread.
    params = io.stdin:read(api.MAX_REQUEST_BYTES + 1) or ""
  end
  if params ~= nil then
    local def = api.METHODS[method]
    -- `ops` carries its fields at the top of the request; the read methods carry theirs under `params`
    request = (def and def.flat) and tostring(params) or ('{"params":' .. tostring(params) .. "}")
  end
  local text, code = api.call(method, request, {
    root = ctx.eo.root,
    today = ctx.eo.today,
    indent = args.opt.pretty and 2 or nil,
  })
  ctx.out(text .. "\n")
  -- a request of `ops` that was answered but not carried out in full (`ok: false`) is a failure for the shell too
  if code == nil and method == "ops" then
    local decoded = select(2, pcall(vim.json.decode, text))
    if type(decoded) == "table" and decoded.ok == false then
      return 1
    end
  end
  return exit_code(code)
end

---`--capabilities` without a command: the handshake.
---@param ctx Tasks.CliCtx
---@return integer
function M.capabilities(ctx)
  local text, code =
    api.call("hello", nil, { root = ctx.eo.root, indent = ctx.args.opt.pretty and 2 or nil })
  ctx.out(text .. "\n")
  return exit_code(code)
end

-- ── areas, show, plans ───────────────────────────────────────────────────────

---`areas --format=tsv|json` (the plain list of names is `cli.lua`'s).
---@param ctx Tasks.CliCtx
---@param format "tsv"|"json"
---@return integer
function M.areas(ctx, format)
  if #ctx.args.pos > 0 then
    ctx.warn("error: areas takes no argument")
    return 2
  end
  if format == "json" then
    local doc, err = contract.areas({ root = ctx.eo.root })
    return emit(ctx, doc, err)
  end
  local root, rerr = vault.root({ root = ctx.eo.root })
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local doc, err = contract.areas({ root = root })
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return 1
  end
  for _, a in ipairs(doc.areas) do
    ctx.say(("%s\t%d"):format(fsio.clean(a.name), a.open))
  end
  return 0
end

---@param ctx Tasks.CliCtx
---@return integer
local function run_show(ctx)
  local id = ctx.args.pos[1]
  local format = ctx.args.opt.format or "text"
  if not id or #ctx.args.pos > 1 then
    ctx.warn("error: usage: show <area>/<slug> [--format=text|json]")
    return 2
  end
  if format ~= "text" and format ~= "json" then
    ctx.warn("error: --format must be text or json")
    return 2
  end
  local doc, err = contract.task(id, { root = ctx.eo.root })
  if format == "json" then
    return emit(ctx, doc, err)
  end
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return type(err) == "table" and exit_code(err.code) or 1
  end
  local t = doc.task
  ---@param key string
  ---@param value any
  local function field(key, value)
    if value ~= nil and value ~= "" and not (type(value) == "table" and #value == 0) then
      ctx.say(
        ("%s: %s"):format(
          key,
          type(value) == "table" and table.concat(value, ", ") or tostring(value)
        )
      )
    end
  end
  field("id", t.id)
  field("title", t.title)
  field("status", t.status)
  field("kind", t.kind)
  field("prio", t.prio)
  field("effort", t.effort)
  field("value", t.value)
  field("actor", t.actor)
  field("plan", t.plan)
  field("phase", t.phase)
  field("tags", t.tags)
  field("blocked_by", t.blocked_by)
  field("after", t.after)
  field("refs", t.refs)
  field("file", t.file)
  if t.readiness then
    field(
      "readiness",
      ("%s (stage %s, rank %s)"):format(
        t.readiness.state,
        tostring(t.readiness.stage or "-"),
        tostring(t.readiness.rank)
      )
    )
  end
  for _, p in ipairs(t.problems) do
    ctx.say(("problem: %s: %s"):format(p.code, p.msg))
  end
  ctx.say("")
  ctx.out(doc.body)
  if doc.body ~= "" and doc.body:sub(-1) ~= "\n" then
    ctx.say("")
  end
  return t.valid and 0 or 1
end

---@param ctx Tasks.CliCtx
---@param helpers Tasks.CliContractHelpers
---@return integer
local function run_plans(ctx, helpers)
  local area, ok = helpers.area_arg(ctx, "plans")
  if not ok then
    return 2
  end
  local files, err
  if area then
    files, err = plans.area(area, { root = ctx.eo.root })
  else
    files, err = plans.all({ root = ctx.eo.root })
  end
  if not files then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, f in ipairs(files) do
    ctx.say(
      table.concat({ fsio.clean(f.id), f.status or "-", f.location, fsio.clean(f.title) }, "\t")
    )
  end
  return 0
end

-- ── list: the JSON form and the finished tasks ───────────────────────────────

---`list --format=json`: the same filters as the text form, in the contract's document.
---@param ctx Tasks.CliCtx
---@param filter Tasks.Filter
---@param area string|nil
---@param helpers Tasks.CliContractHelpers
---@return integer
function M.list_json(ctx, filter, area, helpers)
  local opt = ctx.args.opt
  if opt.sort ~= nil then
    return usage_error(
      ctx,
      "invalid_argument",
      "--sort has no meaning with --format=json: the order is the plan's (see readiness.rank)"
    )
  end
  if opt.ready and opt.waiting then
    return usage_error(ctx, "invalid_argument", "--ready and --waiting exclude each other")
  end
  local params = { area = area }
  if opt.limit ~= nil then
    local n = helpers.to_int(opt.limit --[[@as string]], "--limit")
    params.limit = n or -1
  end
  if opt.offset ~= nil then
    local n = helpers.to_int(opt.offset --[[@as string]], "--offset")
    params.offset = n or -1
  end
  filter.ref_opts = { root = ctx.eo.root }
  local doc, err = contract.list(params, {
    root = ctx.eo.root,
    filter = filter,
    readiness = (opt.ready and "ready") or (opt.waiting and "waiting") or nil,
  })
  return emit(ctx, doc, err)
end

---`next --format=json`.
---@param ctx Tasks.CliCtx
---@param area string|nil
---@param count integer
---@param actor string|nil
---@return integer
function M.next_json(ctx, area, count, actor)
  local doc, err = contract.next(
    { area = area, actor = actor, n = count - 1 },
    { root = ctx.eo.root }
  )
  return emit(ctx, doc, err)
end

---`list --done`: finished tasks, newest first, one line each.
---@param ctx Tasks.CliCtx
---@param filter Tasks.Filter
---@param area string|nil
---@param format string
---@param helpers Tasks.CliContractHelpers
---@return integer
function M.list_done(ctx, filter, area, format, helpers)
  local root, rerr = vault.root({ root = ctx.eo.root })
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local areas = area and { area }
    or vim.tbl_map(function(a)
      return a.name
    end, vault.areas(root))
  local done = {}
  for _, name in ipairs(areas) do
    local tasks = scan.backlog(name, { root = root })
    for _, t in ipairs(tasks or {}) do
      done[#done + 1] = t
    end
  end
  if next(filter) ~= nil then
    done = (model.filter(done, filter))
  end
  table.sort(done, function(a, b)
    local fa, fb = vim.fs.basename(a.path), vim.fs.basename(b.path)
    if fa ~= fb then
      return fa > fb
    end
    return a.id < b.id
  end)
  for _, t in ipairs(done) do
    if format == "ids" then
      ctx.say(fsio.clean(t.id))
    else
      ctx.say(table.concat({
        fsio.clean(t.id),
        helpers.cellv(t.status),
        helpers.cellv(t.prio),
        helpers.cellv(t.effort),
        helpers.cellv(t.kind),
        helpers.cellv(t.updated or t.created),
        helpers.cellv(t.title),
      }, "\t"))
    end
  end
  return 0
end

-- ── registration ─────────────────────────────────────────────────────────────

---Add the commands of this module to the tables of `cli.lua`.
---@param commands table<string, fun(ctx: Tasks.CliCtx): integer>
---@param specs table<string, Tasks.CliSpec>
---@param helpers Tasks.CliContractHelpers
function M.register(commands, specs, helpers)
  specs.call = { value = { "params" }, flag = { "pretty" } }
  commands.call = run_call
  specs.show = { value = { "format" }, flag = {} }
  commands.show = run_show
  specs.plans = { value = {}, flag = {} }
  commands.plans = function(ctx)
    return run_plans(ctx, helpers)
  end
end

return M
