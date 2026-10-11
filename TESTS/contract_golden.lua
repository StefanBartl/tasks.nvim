-- TESTS/contract_golden.lua -- the golden files of the contract: which documents, how they are asked for, how they
-- are rendered. Shared by the spec (compares) and TESTS/golden/regenerate.lua (writes), so the two cannot drift.

local G = {}

G.dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/golden/tasks-export-1"

---The day the write cases run on (`updated` of a changed task, the date in a finished file's name).
G.today = "2026-01-02"

---The version tag of a task file of the vault.
---@param root string
---@param id string
---@return string
local function etag(root, id)
  return assert(require("tasks_nvim.scan").find(id, { root = root })).etag
end

---A JSON request text.
---@param value table
---@return string
local function encode(value)
  return vim.json.encode(value)
end

---Each case: the file name (without `.json`), the method and the request text (`nil`: no request; a function builds it
---from the vault it runs on). `fresh`: the case WRITES, so it runs on a vault of its own and cannot change what the
---other cases see.
---@type { name: string, method: string, request: string|(fun(root: string): string)|nil, fresh: boolean|nil }[]
G.cases = {
  { name = "hello", method = "hello" },
  { name = "snapshot", method = "snapshot" },
  { name = "list-page", method = "list", request = '{"params":{"limit":5,"offset":0}}' },
  { name = "task-alpha", method = "task", request = '{"params":{"id":"lib.nvim/alpha"}}' },
  { name = "next", method = "next", request = '{"params":{"n":3}}' },
  { name = "areas", method = "areas" },
  { name = "error-unsupported-schema", method = "list", request = '{"schema":2}' },
  { name = "error-unknown-parameter", method = "list", request = '{"params":{"colour":"red"}}' },
  { name = "donepreview", method = "done_preview", request = '{"params":{"id":"lib.nvim/delta"}}' },
  {
    -- every operation as a dry run: nothing is written, the answer says what would happen
    name = "result-dry-run",
    method = "ops",
    request = function(root)
      return encode({
        client_op_id = "golden-dry",
        dry_run = true,
        ops = {
          {
            op = "set",
            id = "cascade.nvim/eta",
            patch = { summary = "Golden summary", tags = { "golden" } },
            if_match = etag(root, "cascade.nvim/eta"),
          },
          { op = "new", area = "cascade.nvim", title = "Golden new task", fields = { prio = 2 } },
          { op = "reorder", id = "lib.nvim/alpha-twin", before = "lib.nvim/alpha" },
          { op = "done", id = "lib.nvim/delta" },
          { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
        },
      })
    end,
  },
  {
    -- the same kinds of operations for real, on a vault of their own, with the failures a client has to handle
    name = "result-run",
    method = "ops",
    fresh = true,
    request = function(root)
      local mutate = require("tasks_nvim.mutate")
      return encode({
        client_op_id = "golden-run",
        ops = {
          {
            op = "set",
            id = "cascade.nvim/eta",
            patch = { summary = "Golden summary", tags = { "golden" } },
            if_match = etag(root, "cascade.nvim/eta"),
          },
          {
            op = "set",
            id = "lib.nvim/gamma",
            patch = { prio = 1 },
            if_match = "sha256:0000000000000000",
          },
          { op = "new", area = "cascade.nvim", title = "Golden new task", fields = { prio = 2 } },
          { op = "reorder", id = "lib.nvim/alpha-twin", before = "lib.nvim/alpha" },
          {
            op = "done",
            id = "lib.nvim/delta",
            confirm = mutate.confirm_token("lib.nvim/delta", etag(root, "lib.nvim/delta")),
          },
          { op = "set", id = "lib.nvim/alpha", patch = { blocked_by = { "lib.nvim/beta" } } },
          { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
        },
      })
    end,
  },
}

---Run `fn` with the clock and the engine info fixed, then put them back.
---@generic T
---@param fn fun(): T
---@return T
function G.fixed(fn)
  local contract = require("tasks_nvim.contract")
  local clock, engine = contract.clock, contract.engine_info
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  contract.engine_info = function()
    return { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" }
  end
  local ok, res = pcall(fn)
  contract.clock, contract.engine_info = clock, engine
  if not ok then
    error(res, 0)
  end
  return res
end

---The readable canonical text of one case.
---@param root string
---@param case { method: string, request: string|(fun(root: string): string)|nil, fresh: boolean|nil }
---@param build? fun(): string  # Makes a vault of its own, for a case that writes.
---@return string
function G.render(root, case, build)
  if case.fresh then
    assert(build, "the case " .. tostring(case.method) .. " writes: it needs a vault of its own")
    root = build()
  end
  local request = case.request
  if type(request) == "function" then
    request = request(root)
  end
  return G.fixed(function()
    local text = require("tasks_nvim.api").call(
      case.method,
      request,
      { root = root, indent = 2, today = G.today }
    )
    return text .. "\n"
  end)
end

---@param name string
---@return { name: string, method: string, request: string|nil }
function G.case(name)
  for _, c in ipairs(G.cases) do
    if c.name == name then
      return c
    end
  end
  error("no golden case " .. name)
end

return G
