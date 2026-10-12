-- TESTS/tasks_host_spec.lua -- the persistent engine: the line protocol of `tasks_nvim.host` and the real
-- `scripts/tasks-host.lua` in a child Neovim.
--
-- The rule it holds: a question through the host gets the document `api.call` gives, byte for byte.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local api = require("tasks_nvim.api")
  local host = require("tasks_nvim.host")
  local contract = require("tasks_nvim.contract")

  -- Every document is stamped with `generated_at`, to the second: two calls that straddle a second boundary differ in
  -- that one field only. The clock is the engine's own seam; pin it, so "byte for byte" is a stable claim.
  local real_clock = contract.clock
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end

  ---A line of the child's output with the stamp blanked: the child has its own clock, which the seam cannot reach.
  ---@param line any
  ---@return any
  local function unstamp(line)
    if type(line) ~= "string" then
      return line
    end
    return (line:gsub('"generated_at":"[^"]*"', '"generated_at":"-"'))
  end

  local root = fixture.build(H)
  local real_vault = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = root

  -- ── in-process: one line in, one line out ──
  for _, case in ipairs({
    { id = "1", method = "hello", params = "" },
    { id = "2", method = "snapshot", params = "" },
    { id = "3", method = "areas", params = "" },
    { id = "4", method = "task", params = '{"id":"lib.nvim/second-one"}' },
    { id = "5", method = "next", params = '{"n":2}' },
    { id = "6", method = "bodies", params = '{"limit":10}' },
  }) do
    local line = case.id .. "\t" .. case.method .. "\t" .. case.params
    local want =
      api.call(case.method, case.params ~= "" and ('{"params":' .. case.params .. "}") or nil, {})
    eq(host.handle(line), case.id .. "\t" .. want, case.method .. ": same bytes as api.call")
    ok(not host.handle(line):sub(#case.id + 2):find("\n"), case.method .. ": one line")
  end

  -- `ops` carries its fields at the top of the request, as on the command line
  local ops = '{"dry_run":true,"ops":[{"op":"set","id":"lib.nvim/second-one","set":{"prio":1}}]}'
  eq(
    host.handle("7\tops\t" .. ops),
    "7\t" .. api.call("ops", ops, {}),
    "ops: same bytes as api.call"
  )

  -- a request the dispatcher refuses is its own error document, with the id of the question
  local refused = host.handle("8\tbogus\t")
  ok(refused ~= nil and refused:sub(1, 2) == "8\t", "an unknown method is answered with its id")
  eq(vim.json.decode(refused:sub(3)).code, "not_found")
  local badjson = host.handle("9\ttask\t{not json")
  eq(vim.json.decode(badjson:sub(3)).code, "invalid_argument")

  -- a Windows line ending is not part of the request
  eq(host.handle("10\thello\t\r"), "10\t" .. api.call("hello", nil, {}))

  -- what is no request is skipped (nil), never answered with a guess
  eq(host.handle("hello"), nil)
  eq(host.handle(""), nil)
  eq(host.handle("x\thello\t"), nil)
  eq(host.handle("1234567890123456\thello\t"), nil)

  -- ── a real child Neovim, over pipes ──
  local script = vim.fs.normalize(vim.fn.fnamemodify(here, ":p:h:h")) .. "/scripts/tasks-host.lua"
  ok(H.exists(script), "scripts/tasks-host.lua exists: " .. script)
  local lib = vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1]
  ok(lib ~= nil, "lib.nvim is on the runtimepath")
  local lib_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(lib)))
  local requests = table.concat({
    "1\thello\t",
    "2\ttask\t" .. '{"id":"lib.nvim/second-one"}',
    "garbage",
    "3\tnext\t" .. '{"n":1}',
    "",
  }, "\n")
  local child = vim
    .system({ vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }, {
      text = true,
      stdin = requests,
      env = {
        NVIM = vim.NIL,
        NVIM_LISTEN_ADDRESS = vim.NIL,
        TASKS_VAULT = root,
        LIB_NVIM_DIR = lib_dir,
      },
    })
    :wait(60000)
  eq(child.code, 0, "the host ends cleanly when its input ends; stderr: " .. tostring(child.stderr))
  local lines = {}
  for l in (child.stdout:gsub("\r", "")):gmatch("[^\n]+") do
    lines[#lines + 1] = l
  end
  eq(lines[1], "ready\t1")
  eq(unstamp(lines[2]), unstamp("1\t" .. api.call("hello", nil, {})), "hello through the child")
  eq(
    unstamp(lines[3]),
    unstamp(host.handle("2\ttask\t" .. '{"id":"lib.nvim/second-one"}')),
    "task through the child"
  )
  eq(unstamp(lines[4]), unstamp(host.handle("3\tnext\t" .. '{"n":1}')), "next through the child")
  eq(#lines, 4, "nothing else on stdout")
  has(child.stderr, "not a request")

  -- a vault that is not there is an answer, not a dead host
  local lost = vim
    .system({ vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }, {
      text = true,
      stdin = "1\tsnapshot\t\n2\thello\t\n",
      env = {
        NVIM = vim.NIL,
        NVIM_LISTEN_ADDRESS = vim.NIL,
        TASKS_VAULT = root .. "/no-such-vault",
        LIB_NVIM_DIR = lib_dir,
      },
    })
    :wait(60000)
  eq(lost.code, 0)
  local out = (lost.stdout:gsub("\r", ""))
  has(out, "1\t{")
  has(out, '"kind":"tasks.error"')
  has(out, "2\t{")

  vim.env.TASKS_VAULT = real_vault
  contract.clock = real_clock
end
