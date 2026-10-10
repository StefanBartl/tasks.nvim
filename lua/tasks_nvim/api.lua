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
--- Only read methods exist so far (`hello`, `snapshot`, `list`, `task`, `next`, `areas`); nothing here writes.
---
--- Not its job: building a document (`contract`), the command line (`cli`: `tasks call`, `--format=json`).

local contract = require("tasks_nvim.contract")

local M = {}

---A request bigger than this is refused before it is parsed.
M.MAX_REQUEST_BYTES = 256 * 1024

---@class Tasks.ApiMethod
---@field params table<string, string>   # Parameter name -> its type (`string`, `integer`, `string_list`).
---@field run fun(params: table, opts: table): table|nil, Tasks.ContractError|string|nil

---@type table<string, Tasks.ApiMethod>
M.METHODS = {
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
    params = { area = "string", status = "string_list", limit = "integer", offset = "integer" },
    run = function(params, opts)
      return contract.list(params, opts)
    end,
  },
  task = {
    params = { id = "string" },
    run = function(params, opts)
      if params.id == nil then
        return nil,
          { code = "invalid_argument", message = "task needs the parameter id", retryable = false }
      end
      return contract.task(params.id, opts)
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
}

---The names of the methods, sorted.
---@return string[]
function M.methods()
  local out = {}
  for name in pairs(M.METHODS) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---@param code string
---@param message string
---@return Tasks.ContractError
local function fail(code, message)
  return { code = code, message = message, retryable = false }
end

---An error string from below the contract, as a code. The engine's functions answer `nil, "text"`; the text is all
---there is, so this is a short list of patterns, the one fragile spot of the door (a code at the source comes later).
---@param err any
---@return Tasks.ContractError
local function classify(err)
  if type(err) == "table" and err.code then
    return err
  end
  local text = tostring(err)
  local code = "internal"
  if
    text:find("vault not found", 1, true)
    or text:find("is not a directory", 1, true)
    or text:find("no such", 1, true)
    or text:find("unknown area", 1, true)
  then
    code = "not_found"
  elseif
    text:find("cannot list", 1, true)
    or text:find("cannot read", 1, true)
    or text:find("permission", 1, true)
  then
    code = "io"
  elseif text:find("is being written", 1, true) then
    return { code = "locked", message = text, retryable = true }
  end
  return { code = code, message = text, retryable = false }
end

---@param value any
---@param kind string
---@return boolean
local function has_type(value, kind)
  if kind == "string" then
    return type(value) == "string"
  elseif kind == "integer" then
    return type(value) == "number" and value == math.floor(value)
  elseif kind == "string_list" then
    if type(value) ~= "table" or not vim.islist(value) then
      return false
    end
    for _, v in ipairs(value) do
      if type(v) ~= "string" then
        return false
      end
    end
    return true
  end
  return false
end

---Parse and check a request.
---@param name string
---@param request string|table|nil
---@return table|nil params
---@return Tasks.ContractError|nil err
local function parse_request(name, request)
  local method = M.METHODS[name]
  if not method then
    return nil,
      fail(
        "not_found",
        ("unknown method '%s' (methods: %s)"):format(name, table.concat(M.methods(), ", "))
      )
  end
  local req = request
  if type(request) == "string" then
    if #request > M.MAX_REQUEST_BYTES then
      return nil,
        fail("payload_too_large", ("a request is at most %d bytes"):format(M.MAX_REQUEST_BYTES))
    end
    if vim.trim(request) == "" then
      req = {}
    else
      local ok, decoded =
        pcall(vim.json.decode, request, { luanil = { object = true, array = true } })
      if not ok then
        return nil, fail("invalid_argument", "the request is not valid JSON")
      end
      req = decoded
    end
  end
  if req == nil then
    req = {}
  end
  if type(req) ~= "table" or (next(req) ~= nil and vim.islist(req)) then
    return nil, fail("invalid_argument", "the request must be a JSON object")
  end
  for key in pairs(req) do
    if key ~= "schema" and key ~= "params" then
      return nil,
        fail(
          "invalid_argument",
          ("unknown field '%s' in the request (fields: schema, params)"):format(tostring(key))
        )
    end
  end
  if req.schema ~= nil then
    if type(req.schema) ~= "number" then
      return nil, fail("invalid_argument", "schema must be a number")
    end
    if req.schema > contract.SCHEMA then
      return nil,
        {
          code = "unsupported_schema",
          message = ("the request asks for schema %d, this engine speaks %d: update the engine"):format(
            req.schema,
            contract.SCHEMA
          ),
          retryable = false,
        }
    end
    if req.schema < 1 then
      return nil, fail("invalid_argument", "schema must be 1 or more")
    end
  end
  local params = req.params
  if params == nil then
    params = {}
  end
  if type(params) ~= "table" or (next(params) ~= nil and vim.islist(params)) then
    return nil, fail("invalid_argument", "params must be a JSON object")
  end
  local known = {}
  for key, kind in pairs(method.params) do
    known[#known + 1] = key
    if params[key] ~= nil and not has_type(params[key], kind) then
      return nil,
        fail("invalid_argument", ("parameter '%s' must be %s"):format(key, kind:gsub("_", " ")))
    end
  end
  table.sort(known)
  for key in pairs(params) do
    if method.params[key] == nil then
      return nil,
        fail(
          "invalid_argument",
          ("%s takes no parameter '%s'%s"):format(
            name,
            tostring(key),
            #known > 0 and (" (parameters: " .. table.concat(known, ", ") .. ")") or ""
          )
        )
    end
  end
  return params, nil
end

---Answer one request.
---@param name string                     # The method: `hello`, `snapshot`, `list`, `task`, `next`, `areas`.
---@param request? string|table           # The request as JSON text (or already decoded).
---@param opts? { root?: string, indent?: integer }  # The vault; `indent` makes the text readable (golden files).
---@return string text                    # The document: the answer, or a `tasks.error`.
---@return string|nil code                # `nil` for an answer, else the error code.
function M.call(name, request, opts)
  opts = opts or {}
  local engine_opts = { root = opts.root }
  local root = require("tasks_nvim.vault").root(engine_opts)
  -- a vault that cannot be found is named in the message the engine gives: the path the caller handed in is still
  -- a path of this machine, so it is what gets hidden
  if not root then
    local given = opts.root or vim.env.TASKS_VAULT
    root = given and given ~= "" and require("tasks_nvim.fsio").norm(given) or nil
  end
  ---@param err Tasks.ContractError
  ---@return string text
  ---@return string code
  local function error_text(err)
    local text = contract.encode(contract.error_doc(err, root), { indent = opts.indent })
    -- an error document that cannot be encoded is a bug of ours; answer with the smallest valid one
    return text
      or '{"code":"internal","kind":"tasks.error","message":"cannot encode the error","plugin":"tasks.nvim","retryable":false,"schema":1}',
      err.code
  end
  local params, perr = parse_request(tostring(name), request)
  if not params then
    return error_text(perr or fail("internal", "no parameters"))
  end
  local ok, doc, err = pcall(M.METHODS[name].run, params, engine_opts)
  if not ok then
    return error_text(fail("internal", tostring(doc)))
  end
  if not doc then
    return error_text(classify(err))
  end
  local text, eerr = contract.encode(doc, { indent = opts.indent })
  if not text then
    return error_text(eerr or fail("internal", "cannot encode the document"))
  end
  return text, nil
end

return M
