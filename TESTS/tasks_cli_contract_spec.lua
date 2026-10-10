-- TESTS/tasks_cli_contract_spec.lua -- the command line side of the contract: call, --capabilities, the JSON forms of
-- list and next, areas, show, plans, list --done.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local cli = require("tasks_nvim.cli")

  local root = fixture.build(H)
  local common = { "--vault=" .. root, "--today=2026-01-01" }

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, errs = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end

  ---@param r { out: string }
  ---@return table
  local function doc(r)
    local decoded = vim.json.decode(r.out)
    ok(type(decoded) == "table", "stdout is one JSON document: " .. r.out:sub(1, 80))
    return decoded
  end

  -- ── call ──
  local r = run({ "call", "hello" })
  eq(r.code, 0, r.err)
  eq(doc(r).kind, "tasks.hello")
  ok(r.out:sub(-1) == "\n" and not r.out:sub(1, -2):find("\n"), "compact: one line")
  r = run({ "call", "hello", "--pretty" })
  has(r.out, '\n  "capabilities"', "--pretty is readable")
  r = run({ "--capabilities" })
  eq({ r.code, doc(r).kind }, { 0, "tasks.hello" }, "--capabilities is the handshake")
  r = run({ "call", "snapshot" })
  eq({ r.code, doc(r).kind, #doc(r).tasks }, { 0, "tasks.snapshot", 14 })
  lacks(r.out, root, "no path of this machine on the command line either")
  r = run({ "call", "list", '--params={"limit":3,"status":["open"]}' })
  eq({ r.code, #doc(r).items, doc(r).total }, { 0, 3, 9 })
  r = run({ "call", "task", '--params={"id":"lib.nvim/alpha"}' })
  eq({ r.code, doc(r).task.id }, { 0, "lib.nvim/alpha" })

  -- an error is a document on stdout, with the exit code of its kind
  r = run({ "call", "frobnicate" })
  eq({ r.code, doc(r).code }, { 1, "not_found" })
  r = run({ "call", "list", "--params={nope" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" }, "a bad request is exit 2")
  r = run({ "call", "list", '--params={"colour":1}' })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" })
  r = run({ "call" })
  eq(r.code, 2)
  has(r.err, "usage: call")
  r = run({ "call", "hello", "snapshot" })
  eq(r.code, 2, "one method")

  -- ── list --format=json: the filters of the text form, the plan's order ──
  r = run({ "list", "--format=json" })
  eq({ r.code, doc(r).kind, doc(r).total }, { 0, "tasks.list", 14 })
  r = run({ "list", "--format=json", "--status=doing" })
  eq({ doc(r).total, doc(r).items[1].id }, { 1, "lib.nvim/beta" })
  r = run({ "list", "cascade.nvim", "--format=json" })
  eq(doc(r).total, 4, "an area")
  r = run({ "list", "all", "--format=json" })
  eq(doc(r).total, 14, "`all` is every area")
  r = run({ "list", "--format=json", "--prio=1" })
  eq(doc(r).total, 2, "--prio=1: alpha and its twin")
  r = run({ "list", "--format=json", "--value=>=4", "--effort=<=S" })
  eq(doc(r).total, 2, "the quick wins of the fixture (alpha, zeta)")
  r = run({ "list", "--format=json", "--ready" })
  eq(
    doc(r).total,
    7,
    "--ready: every task whose readiness is ready or decision, including the AI one"
  )
  r = run({ "list", "--format=json", "--waiting" })
  eq(
    doc(r).total,
    5,
    "--waiting: an open blocker, stuck ones included (beta, iota, epsilon, the cycle)"
  )
  r = run({ "list", "--format=json", "--limit=2", "--offset=2" })
  eq({ #doc(r).items, doc(r).offset, doc(r).next_offset }, { 2, 2, 4 })
  r = run({ "list", "--format=json", "--limit=0" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" }, "limit 0")
  r = run({ "list", "--format=json", "--limit=x" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" }, "a limit that is no number")
  r = run({ "list", "--format=json", "--sort=roi" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" }, "--sort has no meaning with json")
  has(doc(r).message, "plan's")
  r = run({ "list", "--format=json", "--ready", "--waiting" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" })
  r = run({ "list", "--format=json", "nope.nvim" })
  eq(r.code, 1, "an unknown area")
  r = run({ "list", "--limit=3" })
  eq(r.code, 2)
  has(r.err, "go with --format=json")

  -- the text form is unchanged, and `all` works there too
  r = run({ "list", "all" })
  eq(r.code, 0, r.err)
  eq(#vim.split(vim.trim(r.out), "\n"), 14, "list all: 14 open tasks")
  r = run({ "list", "--format=csv" })
  eq(r.code, 2)
  has(r.err, "tsv, ids or json")

  -- ── list --done ──
  r = run({ "list", "--done" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/old-done\tdone\t")
  has(r.out, "Old and done")
  r = run({ "list", "--done", "--format=ids" })
  eq(vim.trim(r.out), "lib.nvim/old-done")
  r = run({ "list", "--done", "cascade.nvim" })
  eq(r.out, "", "an area without finished tasks")
  r = run({ "list", "--done", "--format=json" })
  eq(r.code, 2)
  r = run({ "list", "--done", "--sort=roi" })
  eq(r.code, 2)

  -- ── next ──
  r = run({ "next", "--format=json", "--n=2" })
  eq({ r.code, doc(r).kind, doc(r).task.id }, { 0, "tasks.next", "lib.nvim/alpha-twin" })
  eq(#doc(r).alternatives, 1, "--n=2: the pick and one more")
  r = run({ "next", "--format=json", "--actor=cdx" })
  eq(doc(r).task.id, "lib.nvim/alpha", "the AI queue")
  r = run({ "next", "--format=json", "--actor=robot" })
  eq(r.code, 2, "the text-mode check stays")
  r = run({ "next", "--format=yaml" })
  eq(r.code, 2)
  r = run({ "next" })
  eq(r.code, 0, "the text form is unchanged")
  has(r.out, "next: lib.nvim/alpha-twin")

  -- ── areas ──
  r = run({ "areas" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim\t10")
  has(r.out, "cascade.nvim\t4")
  r = run({ "areas", "--format=json" })
  eq({ r.code, doc(r).kind }, { 0, "tasks.areas" })
  r = run({ "areas", "--format=xml" })
  eq(r.code, 2)
  r = run({ "areas", "lib.nvim" })
  eq(r.code, 2)

  -- ── show ──
  r = run({ "show", "lib.nvim/alpha" })
  eq(r.code, 0, r.err)
  has(r.out, "id: lib.nvim/alpha")
  has(r.out, "readiness: ready (stage 0, rank")
  has(r.out, "The body of alpha.")
  has(r.out, "refs: docs/shared.md, <external>/secret.md")
  r = run({ "show", "lib.nvim/alpha", "--format=json" })
  eq({ r.code, doc(r).kind, doc(r).task.id }, { 0, "tasks.task", "lib.nvim/alpha" })
  r = run({ "show", "lib.nvim/broken" })
  eq(r.code, 1, "a task with problems is exit 1")
  has(r.out, "problem: bad-prio:")
  r = run({ "show", "lib.nvim/nope" })
  eq(r.code, 1)
  has(r.err, "no such task")
  r = run({ "show", "lib.nvim/nope", "--format=json" })
  eq({ r.code, doc(r).code }, { 1, "not_found" })
  r = run({ "show", "../x", "--format=json" })
  eq({ r.code, doc(r).code }, { 2, "invalid_argument" })
  r = run({ "show" })
  eq(r.code, 2)

  -- ── plans ──
  r = run({ "plans" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/the-plan\tdoing\troadmap\tThe plan")
  r = run({ "plans", "cascade.nvim" })
  eq(r.out, "")
  r = run({ "plans", "nope.nvim" })
  eq(r.code, 2)

  -- ── a vault that is not there: a document, not a stack trace ──
  local out, errs = {}, {}
  local code = cli.run({ "call", "snapshot", "--vault=" .. root .. "/missing" }, {
    out = function(t)
      out[#out + 1] = t
    end,
    err = function(t)
      errs[#errs + 1] = t
    end,
  })
  local missing = vim.json.decode(table.concat(out))
  eq({ code, missing.code }, { 1, "not_found" })
  lacks(table.concat(out), root, "and without the path")
end
