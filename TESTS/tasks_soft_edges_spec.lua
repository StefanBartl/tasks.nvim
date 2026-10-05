-- TESTS/tasks_soft_edges_spec.lua -- the fields `after` (soft edge) and `order` (sort hint): parse, write, check, and
-- what the plan shows of them (stages, order, same-file).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")

  -- ── parse ──
  local function task(extra)
    return model.parse_text(
      F.text(F.meta("T", "open", extra)),
      { path = "/v/a/ROADMAP/tasks/t.md", area = "a" }
    )
  end
  eq(task({ { "after", "[a/x, b/y]" } }).after, { "a/x", "b/y" })
  eq(task({}).after, {})
  eq(task({ { "order", "2.5" } }).order, 2.5)
  eq(task({ { "order", "-1" } }).order, -1)
  local bad_order = task({ { "order", "soon" } })
  eq(bad_order.error_codes, { "bad-order" })
  eq(bad_order.order, nil)
  eq(task({ { "order", "inf" } }).error_codes, { "bad-order" }, "not a number a sort can use")
  local bad_after = task({ { "after", "[not-an-id]" } })
  eq(bad_after.error_codes, { "bad-after" })

  -- ── write: new, set, remove ──
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local base = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Soft base" })))
  local made = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend("force", o, { title = "Soft made", after = { base.id }, order = "2.5" })
    )
  )
  local read = scan.find(made.id, { root = root })
  eq(read.after, { base.id })
  eq(read.order, 2.5)
  has(H.read(made.path), "after: [" .. base.id .. "]")
  has(H.read(made.path), "order: 2.5")
  local _, aerr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad a", after = "nope" }))
  has(aerr, "after:")
  local _, oerr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad o", order = "x" }))
  has(oerr, "order must be a number")
  ok(vim.tbl_contains(mutate.SETTABLE, "after"))
  ok(vim.tbl_contains(mutate.SETTABLE, "order"))
  assert(mutate.set(made.id, { order = " 4 ", after = "[" .. base.id .. ", lib.nvim/other]" }, o))
  read = scan.find(made.id, { root = root })
  eq(read.order, 4)
  eq(read.after, { base.id, "lib.nvim/other" })
  local _, serr = mutate.set(made.id, { order = "later" }, o)
  has(serr, "order must be a number")
  local _, serr2 = mutate.set(made.id, { after = "[nonsense]" }, o)
  has(serr2, "after:")
  assert(mutate.set(made.id, { order = mutate.REMOVE, after = mutate.REMOVE }, o))
  read = scan.find(made.id, { root = root })
  eq(read.order, nil)
  eq(read.after, {})

  -- a task without them reads and writes as before; the index never shows them
  assert(mutate.set(made.id, { after = base.id, order = "1" }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  local before = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  assert(mutate.set(made.id, { after = mutate.REMOVE, order = mutate.REMOVE }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  eq(
    H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
    before,
    "after and order never reach the generated index"
  )

  -- ── check ──
  local function codes(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      out[#out + 1] = (f.severity == "warn" and "warn:" or "") .. f.code
    end
    table.sort(out)
    return out
  end
  assert(mutate.set(made.id, { after = base.id }, o))
  eq(codes(assert(check.run({ root = root }))), {}, "a soft edge to an open task checks clean")
  assert(mutate.set(made.id, { after = made.id }, o))
  eq(codes(assert(check.run({ root = root }))), { "after-self" })
  assert(mutate.set(made.id, { after = "lib.nvim/ghost" }, o))
  eq(codes(assert(check.run({ root = root }))), { "after-dangling" })
  assert(mutate.set(made.id, { after = "nope.nvim/ghost" }, o))
  eq(
    codes(assert(check.run({ root = root }))),
    { "after-dangling" },
    "an unknown area is dangling too"
  )
  local finished =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Soft finished" })))
  assert(mutate.done(finished.id, o))
  assert(mutate.set(made.id, { after = finished.id }, o))
  eq(codes(assert(check.run({ root = root }))), {}, "a finished target is fine: the edge is met")
  assert(mutate.set(made.id, { after = mutate.REMOVE }, o))
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/handmade.md",
    F.text(F.meta("Handmade", "open", { { "after", "[oops]" }, { "order", "never" } }))
  )
  local seen = codes(assert(check.run({ root = root, area = "lib.nvim" })))
  ok(vim.tbl_contains(seen, "bad-after"))
  ok(vim.tbl_contains(seen, "bad-order"))
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/handmade.md")

  -- ── what the plan shows ──
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function run(argv)
    local out, err = {}, {}
    local args = vim.list_extend(vim.deepcopy(argv), common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local c1 = run({ "new", "cascade.nvim", "Plan one", "--refs=lua/shared.lua", "--order=2" })
  local c2 = run({ "new", "cascade.nvim", "Plan two", "--refs=lua/shared.lua", "--order=1" })
  local c3 = run({ "new", "cascade.nvim", "Plan three", "--after=cascade.nvim/plan-one" })
  eq(c1.code + c2.code + c3.code, 0, c1.err .. c2.err .. c3.err)
  local plan_ids = vim.split(vim.trim(run({ "plan", "cascade.nvim", "--format=ids" }).out), "\n")
  local pos = {}
  for i, id in ipairs(plan_ids) do
    pos[id] = i
  end
  ok(
    pos["cascade.nvim/plan-two"] < pos["cascade.nvim/plan-one"],
    "order 1 before order 2 in the same stage"
  )
  ok(
    pos["cascade.nvim/plan-three"] > pos["cascade.nvim/plan-one"],
    "the soft edge puts three behind one"
  )
  local md = run({ "plan", "cascade.nvim" }).out
  has(md, "same-file with cascade.nvim/plan-one")
  has(md, "Not parallel: `lua/shared.lua`")
  local tsv = run({ "plan", "cascade.nvim", "--format=tsv" }).out
  ok(
    tsv:find("1\tcascade.nvim/plan-three\tready", 1, true) ~= nil,
    "three is still ready (a soft edge never blocks), in stage 1"
  )
  local usage = run({ "help" })
  has(usage.out, "--after=id,id")
end
