-- TESTS/contract_golden.lua -- the golden files of the contract: which documents, how they are asked for, how they
-- are rendered. Shared by the spec (compares) and TESTS/golden/regenerate.lua (writes), so the two cannot drift.

local G = {}

G.dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/golden/tasks-export-1"

---Each case: the file name (without `.json`), the method and the request text (`nil`: no request).
---@type { name: string, method: string, request: string|nil }[]
G.cases = {
  { name = "hello", method = "hello" },
  { name = "snapshot", method = "snapshot" },
  { name = "list-page", method = "list", request = '{"params":{"limit":5,"offset":0}}' },
  { name = "task-alpha", method = "task", request = '{"params":{"id":"lib.nvim/alpha"}}' },
  { name = "next", method = "next", request = '{"params":{"n":3}}' },
  { name = "areas", method = "areas" },
  { name = "error-unsupported-schema", method = "list", request = '{"schema":2}' },
  { name = "error-unknown-parameter", method = "list", request = '{"params":{"colour":"red"}}' },
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
---@param case { method: string, request: string|nil }
---@return string
function G.render(root, case)
  return G.fixed(function()
    local text =
      require("tasks_nvim.api").call(case.method, case.request, { root = root, indent = 2 })
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
