---@module 'tasks_nvim.api'
---@brief The one door of the machine contract: `call(method, request)` answers with a JSON document, never with a throw.
---@description
--- Everything outside the engine (an app, an agent, CI) asks through here and gets the canonical bytes of one document
--- of the contract (`tasks_nvim.contract`): the answer, or a `tasks.error` that says what went wrong in a code that
--- is stable (`invalid_argument`, `not_found`, `unsupported_schema`, `payload_too_large`, `io`, `internal`) and
--- whether asking again can help (`retryable`).
---
--- A request is a JSON object: `{ "schema": 1, "params": { ... } }`. `schema` may be left out (it is 1), a higher one
--- is `unsupported_schema`; `params` may be left out too. A parameter the method does not know is `invalid_argument`:
--- a request that is silently half-understood is worse than one that is refused. A request is at most 256 KiB.
---
--- Read methods (`hello`, `snapshot`, `list`, `task`, `next`, `areas`, `finished`, `links`, `done_preview`) and the write door `ops`
--- (`tasks_nvim.ops`: the fields of the request are its own, `null` is kept because it means "remove" in a patch).
---
--- Not its job: building a document (`contract`), the command line (`cli`: `tasks call`, `--format=json`).

local contract = require("tasks_nvim.contract")
local ops = require("tasks_nvim.ops")
local api_mod = require("lib.nvim.contract.api")

local M = {}

---@type table<string, Lib.Contract.ApiMethod>
local methods = {
  hello = {
    params = {},
    run = function(_, opts)
      return contract.hello(opts), nil
    end,
  },
  snapshot = {
    params = {},
    run = function(_, opts)
      return contract.snapshot(opts)
    end,
  },
  list = {
    params = {
      area = "string",
      status = "string_list",
      limit = "integer",
      offset = "integer",
      sort = "string",
    },
    run = function(params, opts)
      return contract.list(params, opts)
    end,
  },
  lists = {
    params = {},
    run = function(_, opts)
      return contract.lists(opts)
    end,
  },
  order = {
    params = { area = "string", status = "string_list", sort = "string" },
    run = function(params, opts)
      return contract.order(params, opts)
    end,
  },
  task = {
    params = { id = "string" },
    required = { "id" },
    run = function(params, opts)
      return contract.task(params.id, opts)
    end,
  },
  bodies = {
    params = { ids = "string_list", limit = "integer", offset = "integer" },
    run = function(params, opts)
      return contract.bodies(params, opts)
    end,
  },
  estimate = {
    params = { ids = "string_list", assume = "object_list" },
    run = function(params, opts)
      return contract.estimate(params, opts)
    end,
  },
  plan_for = {
    params = { id = "string", direction = "string" },
    run = function(params, opts)
      return contract.plan_for(params, opts)
    end,
  },
  check = {
    params = { area = "string", stale = "string" },
    run = function(params, opts)
      return contract.check(params, opts)
    end,
  },
  next = {
    params = { n = "integer", actor = "string", area = "string" },
    run = function(params, opts)
      return contract.next(params, opts)
    end,
  },
  areas = {
    params = {},
    run = function(_, opts)
      return contract.areas(opts)
    end,
  },
  links = {
    params = {},
    run = function(_, opts)
      return contract.links(opts)
    end,
  },
  finished = {
    params = {
      area = "string",
      plan = "string",
      since = "string",
      ["until"] = "string",
      limit = "integer",
      offset = "integer",
    },
    run = function(params, opts)
      return contract.finished(params, opts)
    end,
  },
  done_preview = {
    params = { id = "string" },
    required = { "id" },
    run = function(params, opts)
      return contract.done_preview(params.id, opts)
    end,
  },
  ops = {
    flat = true,
    keep_null = true,
    params = { client_op_id = "string", dry_run = "boolean", ops = "object_list" },
    run = function(params, opts)
      return ops.run(params, opts)
    end,
  },
}

local api = api_mod.make({
  doc = contract.doc,
  methods = methods,
  engine_opts = { "root", "today" },
  patterns = contract.ERROR_PATTERNS,
  root_of = function(engine_opts, opts)
    local root = require("tasks_nvim.vault").root(engine_opts)
    -- a vault that cannot be found is named in the message the engine gives: the path the caller handed in is still
    -- a path of this machine, so it is what gets hidden
    if not root then
      local given = opts.root or vim.env.TASKS_VAULT
      root = given and given ~= "" and require("tasks_nvim.fsio").norm(given) or nil
    end
    return root
  end,
})

---The methods and their parameters.
---@type table<string, Lib.Contract.ApiMethod>
M.METHODS = api.METHODS

---A request bigger than this is refused before it is parsed.
M.MAX_REQUEST_BYTES = api.MAX_REQUEST_BYTES

---The names of the methods, sorted.
---@return string[]
function M.methods()
  return api.methods()
end

---Answer one request. `request` is the JSON text (or an already decoded table), `opts` is `{ root?, today?, indent? }`.
---@param name string
---@param request string|table|nil
---@param opts? { root?: string, today?: string, indent?: integer }
---@return string text   # the canonical bytes of one document (an answer or a `tasks.error`)
---@return string|nil code  # the code of the error document
function M.call(name, request, opts)
  return api.call(name, request, opts or {})
end

---The smallest valid error document, as text: for the moment the real one cannot be made.
M.minimal_error = api.minimal_error

return M
