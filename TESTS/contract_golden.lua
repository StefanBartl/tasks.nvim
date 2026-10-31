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
  { name = "order-roi", method = "order", request = '{"params":{"sort":"roi"}}' },
  { name = "lists-builtin", method = "lists" },
  { name = "groupings", method = "groupings" },
  { name = "views", method = "views" },
  { name = "task-alpha", method = "task", request = '{"params":{"id":"lib.nvim/alpha"}}' },
  { name = "bodies-page", method = "bodies", request = '{"params":{"limit":3,"offset":1}}' },
  {
    name = "estimate",
    method = "estimate",
    request = '{"params":{"ids":["lib.nvim/alpha","lib.nvim/beta","lib.nvim/gamma"],"assume":[{"id":"lib.nvim/alpha","effort":"M","value":4}]}}',
  },
  { name = "planfor", method = "plan_for", request = '{"params":{"id":"cascade.nvim/iota"}}' },
  { name = "check", method = "check", request = '{"params":{"area":"lib.nvim"}}' },
  { name = "next", method = "next", request = '{"params":{"n":3}}' },
  { name = "areas", method = "areas" },
  { name = "links", method = "links" },
  { name = "finished", method = "finished", request = '{"params":{"limit":3}}' },
  {
    name = "finished-plan",
    method = "finished",
    request = '{"params":{"plan":"lib.nvim/the-plan"}}',
  },
  {
    name = "finished-window",
    method = "finished",
    request = '{"params":{"since":"2025-12-31","until":"2026-01-01"}}',
  },
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
          { op = "answer", id = "lib.nvim/alpha", question = "q1", option = 1 },
          { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
          {
            op = "plan_new",
            area = "lib.nvim",
            title = "Golden plan",
            phases = { "design", "build" },
          },
        },
      })
    end,
  },
  {
    -- `new` with its relations: made with after, plan and phase; each relation that is wrong refused, nothing written
    name = "result-new-relations",
    method = "ops",
    fresh = true,
    request = function()
      local function new(title, fields)
        return { op = "new", area = "cascade.nvim", title = title, fields = fields }
      end
      return encode({
        client_op_id = "golden-new-relations",
        ops = {
          new(
            "Golden related task",
            { after = { "lib.nvim/alpha" }, plan = "lib.nvim/the-plan", phase = "test" }
          ),
          new("Golden dangling after", { after = { "lib.nvim/nowhere" } }),
          new("Golden unknown plan", { plan = "lib.nvim/no-plan" }),
          new("Golden unknown phase", { plan = "lib.nvim/the-plan", phase = "deploy" }),
        },
      })
    end,
  },
  {
    -- `add_steps` for real: appended below the last step of a plan, a section made for a task without one, a step that
    -- is a list line refused (nothing written)
    name = "result-add-steps",
    method = "ops",
    fresh = true,
    request = function(root)
      return encode({
        client_op_id = "golden-add-steps",
        ops = {
          {
            op = "add_steps",
            id = "lib.nvim/alpha",
            steps = { "fourth -- Akzeptanz 1", "fifth" },
            if_match = etag(root, "lib.nvim/alpha"),
          },
          { op = "add_steps", id = "lib.nvim/beta", steps = "only step" },
          { op = "add_steps", id = "lib.nvim/gamma", steps = { "- [ ] a list line" } },
        },
      })
    end,
  },
  {
    -- saved views for real: made, replaced on the version read, replaced on a stale one, deleted, a view that is not there
    name = "result-views",
    method = "ops",
    fresh = true,
    request = function(root)
      local views = require("tasks_nvim.views")
      local function view_etag(id)
        local area, slug = id:match("^([^/]+)/(.+)$")
        return require("tasks_nvim.fsio").etag(
          assert(require("tasks_nvim.fsio").read(views.path(root, area, slug)))
        )
      end
      return encode({
        client_op_id = "golden-views",
        ops = {
          {
            op = "view_save",
            area = "cascade.nvim",
            view = {
              title = "Golden view",
              display = "list",
              group_by = "kind",
              select = { actors = { "me" } },
            },
          },
          {
            op = "view_save",
            id = "lib.nvim/by-status",
            view = {
              title = "Columns by status",
              display = "columns",
              group_by = "status",
              collapsed = { "parked" },
            },
            if_match = view_etag("lib.nvim/by-status"),
          },
          {
            op = "view_save",
            id = "lib.nvim/by-status",
            view = { title = "Stale", display = "list", group_by = "status" },
            if_match = "sha256:0000000000000000",
          },
          {
            op = "view_delete",
            id = "lib.nvim/prio-by-actor",
            if_match = view_etag("lib.nvim/prio-by-actor"),
          },
          { op = "view_delete", id = "lib.nvim/not-there", if_match = "sha256:0000000000000000" },
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
  -- The named lists of this machine are not part of a golden: no state file, none of the configuration.
  local lists, config = require("tasks_nvim.lists"), require("tasks_nvim.config")
  local lists_path, lists_cfg = lists.path(), config.get().lists or {}
  lists.set_path(vim.fn.tempname() .. "/none/lists.json")
  config.merge({ lists = {} })
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  contract.engine_info = function()
    return { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" }
  end
  local ok, res = pcall(fn)
  contract.clock, contract.engine_info = clock, engine
  lists.set_path(lists_path)
  config.merge({ lists = lists_cfg })
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
