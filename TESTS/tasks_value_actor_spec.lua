-- TESTS/tasks_value_actor_spec.lua -- the `value` (1-5, expected benefit) and `actor` (cdx / me / pair) fields:
-- model, derived roi and actor, filters, `--sort=roi`, mutate, check, CSV, the CLI and the actor migration.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; a few cases
-- hand the readers wrong types on purpose.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local batch = require("tasks_nvim.batch")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local filter_opts = require("tasks_nvim.filter_opts")

  ---@param extra table[]
  ---@param slug string
  ---@param status? string
  ---@return Tasks.Task
  local function task(slug, extra, status)
    return model.parse_text(
      F.text(F.meta(slug, status or "open", extra)),
      { path = "/v/a/ROADMAP/tasks/" .. slug .. ".md", area = "a" }
    )
  end

  ---@param list Tasks.Task[]
  ---@return string[]
  local function slugs(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = t.slug
    end
    return out
  end

  -- ── value: parse ──
  eq(model.VALUES, { 1, 2, 3, 4, 5 })
  eq(model.to_value("4"), 4)
  eq(model.to_value(5), 5)
  eq(model.to_value("0"), nil)
  eq(model.to_value("6"), nil)
  eq(model.to_value("high"), nil)
  eq(task("v4", { { "value", "4" } }).value, 4)
  local bad_value = task("vbad", { { "value", "9" } })
  eq(bad_value.value, nil, "an invalid value is not kept")
  ok(not bad_value.valid)
  eq(bad_value.error_codes, { "bad-value" })
  eq(task("vnone", {}).value, nil)

  -- ── actor: parse and derivation ──
  eq(task("acdx", { { "actor", "cdx" } }).actor, "cdx")
  local bad_actor = task("abad", { { "actor", "robot" } })
  eq(bad_actor.error_codes, { "bad-actor" })
  ok(not bad_actor.valid)
  eq(model.actor(task("w1", { { "actor", "pair" } })), "pair", "the written value wins")
  eq(
    model.actor(task("w2", { { "actor", "cdx" } }, "decision")),
    "cdx",
    "even over a decision status"
  )
  eq(model.actor(task("d1", {}, "decision")), "me", "a decision is yours")
  eq(model.actor(task("n1", { { "tags", "[needs-user]" } })), "me", "the tag needs-user is yours")
  eq(model.actor(task("n2", { { "tags", "[agent]" } })), nil, "the tag agent is NOT read as cdx")
  eq(model.actor(task("n3", {})), nil, "nothing known: unclear")
  eq(
    model.actor(task("bad", { { "actor", "robot" } })),
    nil,
    "an invalid word derives nothing wrong"
  )

  -- ── roi: derived, absent without both numbers ──
  local r1 = task("r1", { { "value", "4" }, { "effort", "S" } }) -- 4 / 0.5 = 8
  local r2 = task("r2", { { "value", "5" }, { "effort", "XL" } }) -- 5 / 5 = 1
  local r3 = task("r3", { { "value", "2" }, { "effort", "XS" } }) -- 2 / 0.25 = 8
  local r4 = task("r4", { { "value", "3" } })
  local r5 = task("r5", { { "effort", "M" } })
  local r6 = task("r6", { { "value", "5" }, { "effort", "0.1d" } }) -- the floor: 5 / 0.25 = 20
  eq(model.roi(r1), 8)
  eq(model.roi(r2), 1)
  eq(model.roi(r6), 20, "the effort floor of a quarter day")
  eq(model.roi(r4), nil, "no effort: no figure, not 0")
  eq(model.roi(r5), nil, "no value: no figure, not 0")

  -- ── sort roi ──
  eq(model.parse_sort("roi"), "roi")
  local sorted = model.sort({ r5, r2, r4, r1, r6 }, "roi")
  eq(
    slugs(sorted),
    { "r6", "r1", "r2", "r4", "r5" },
    "highest roi first, then the tasks without a figure"
  )
  eq(
    slugs(model.sort({ r3, r1 }, "roi")),
    { "r1", "r3" },
    "equal roi falls back to the default order"
  )

  -- ── filters ──
  local all = { r1, r2, r3, r4, r5, r6 }
  eq(slugs(model.filter(all, { value = { 4, 5 } })), { "r1", "r2", "r6" })
  eq(slugs(model.filter(all, { value_min = 4 })), { "r1", "r2", "r6" })
  eq(slugs(model.filter(all, { value = 3 })), { "r4" })
  local who = {
    task("x-cdx", { { "actor", "cdx" } }),
    task("x-me", { { "actor", "me" } }),
    task("x-dec", {}, "decision"),
    task("x-none", {}),
  }
  eq(
    slugs(model.filter(who, { actor = "me" })),
    { "x-me", "x-dec" },
    "me includes the derived ones"
  )
  eq(slugs(model.filter(who, { actor = { "cdx", "pair" } })), { "x-cdx" })
  eq(slugs(model.filter(who, { actor = "none" })), { "x-none" }, "none: nobody classified it")

  -- filter_opts: words and refusals
  local f = assert(filter_opts.parse({ value = ">=4", actor = "cdx,none" }))
  eq(f.value_min, 4)
  eq(f.actor, { "cdx", "none" })
  f = assert(filter_opts.parse({ value = "4,5" }))
  eq(f.value, { 4, 5 })
  for _, bad in ipairs({ ">=0", ">=9", "0", "6", "high", "" }) do
    local nf, err = filter_opts.parse({ value = bad })
    eq(nf, nil, "refused value: '" .. bad .. "'")
    has(err, "--value")
  end
  local af, aerr = filter_opts.parse({ actor = "robot" })
  eq(af, nil)
  has(aerr, "unknown actor")
  local ef, eerr = filter_opts.parse({ actor = "" })
  eq(ef, nil)
  has(eerr, "--actor needs a value")

  -- ── mutate: new / set / remove ──
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend("force", o, { title = "Valued", value = "4", actor = "cdx", effort = "S" })
    )
  )
  local read = scan.find(made.id, { root = root })
  eq(read.value, 4)
  eq(read.actor, "cdx")
  has(H.read(made.path), "value: 4")
  has(H.read(made.path), "actor: cdx")
  local _, verr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad v", value = "7" }))
  has(verr, "value must be 1, 2, 3, 4 or 5")
  local _, aerr2 =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad a", actor = "x" }))
  has(aerr2, "unknown actor 'x'")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/bad-v.md"), "nothing is created for a bad value")

  assert(mutate.set(made.id, { value = "5", actor = "pair" }, o))
  read = scan.find(made.id, { root = root })
  eq(read.value, 5)
  eq(read.actor, "pair")
  local _, serr = mutate.set(made.id, { value = "0" }, o)
  has(serr, "value must be")
  local _, serr2 = mutate.set(made.id, { actor = "robot" }, o)
  has(serr2, "unknown actor")
  assert(mutate.set(made.id, { value = mutate.REMOVE, actor = mutate.REMOVE }, o))
  read = scan.find(made.id, { root = root })
  eq(read.value, nil, "an empty value removes the key")
  eq(read.actor, nil)
  ok(vim.tbl_contains(mutate.SETTABLE, "value"))
  ok(vim.tbl_contains(mutate.SETTABLE, "actor"))

  -- a task without the fields reads and writes exactly as before
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain one" })))
  ok(not H.read(plain.path):find("value:", 1, true), "no value key unless asked for")
  ok(not H.read(plain.path):find("actor:", 1, true), "no actor key unless asked for")

  -- the generated index shows neither field: it is byte-identical with and without them
  assert(index.write_area("lib.nvim", { root = root }))
  local index_path = root .. "/lib.nvim/ROADMAP/TASKS.md"
  local before = H.read(index_path)
  assert(mutate.set(plain.id, { value = "3", actor = "me" }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  eq(H.read(index_path), before, "value and actor never reach the generated index")

  -- ── check ──
  local function codes(res)
    local out = {}
    for _, finding in ipairs(res.findings) do
      out[#out + 1] = (finding.severity == "warn" and "warn:" or "") .. finding.code
    end
    table.sort(out)
    return out
  end
  assert(mutate.set(plain.id, { value = mutate.REMOVE, actor = mutate.REMOVE }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  eq(codes(assert(check.run({ root = root }))), {}, "clean before the checks below")
  local waits =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Waits", actor = "cdx" })))
  local decide = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Decide", status = "decision" }))
  )
  assert(mutate.set(waits.id, { blocked_by = "[" .. decide.id .. "]" }, o))
  local res = assert(check.run({ root = root }))
  eq(codes(res), { "warn:actor-cdx-waits-on-me" }, "an AI task that waits on a decision of yours")
  ok(res.ok, "a warning, never an error")
  assert(mutate.set(waits.id, { actor = "pair" }, o))
  eq(codes(assert(check.run({ root = root }))), {}, "pair (the human takes part) is fine")
  assert(mutate.set(waits.id, { actor = mutate.REMOVE }, o))
  eq(codes(assert(check.run({ root = root }))), {}, "no written actor: no warning")

  -- hand-written bad values are errors
  local bad_path = root .. "/lib.nvim/ROADMAP/tasks/handmade.md"
  H.write(bad_path, F.text(F.meta("Handmade", "open", { { "value", "11" }, { "actor", "robot" } })))
  res = assert(check.run({ root = root, area = "lib.nvim" }))
  local seen = codes(res)
  ok(vim.tbl_contains(seen, "bad-value"), "bad-value is reported")
  ok(vim.tbl_contains(seen, "bad-actor"), "bad-actor is reported")
  ok(not res.ok)
  vim.fn.delete(bad_path)

  -- ── CSV: the new columns are appended after Severity ──
  local view = require("tasks_nvim.ui.view")
  local sample = task("csv", { { "value", "4" }, { "effort", "S" }, { "actor", "cdx" } })
  local csv = view.render({ sample }, { format = "csv" })
  local header = vim.split(csv, "\n", { plain = true })[1]
  has(header, "Severity,Value,ROI,Actor")
  has(csv, ",4,8.00,cdx")

  -- ── CLI ──
  local croot = F.vault(H)
  local common = { "--vault=" .. croot, "--today=" .. F.TODAY }
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
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
  local c1 = run({ "new", "lib.nvim", "Cli valued", "--value=5", "--actor=cdx", "--effort=XS" })
  eq(c1.code, 0, c1.err)
  local c2 = run({ "new", "lib.nvim", "Cli other", "--value=2", "--effort=XL" })
  eq(c2.code, 0, c2.err)
  local c3 = run({ "new", "lib.nvim", "Cli decision", "--status=decision" })
  eq(c3.code, 0, c3.err)
  local c4 = run({ "new", "lib.nvim", "Cli tagged", "--tags=needs-user" })
  eq(c4.code, 0, c4.err)
  local listed = run({ "list", "lib.nvim", "--sort=roi", "--format=ids", "--value=>=2" })
  eq(listed.code, 0, listed.err)
  eq(
    vim.split(vim.trim(listed.out), "\n"),
    { "lib.nvim/cli-valued", "lib.nvim/cli-other" },
    "roi order"
  )
  local mine = run({ "list", "lib.nvim", "--actor=me", "--sort=default", "--format=ids" })
  eq(mine.code, 0, mine.err)
  eq(
    vim.split(vim.trim(mine.out), "\n"),
    { "lib.nvim/cli-decision", "lib.nvim/cli-tagged" },
    "--actor=me finds the decision and the needs-user task"
  )
  local bad = run({ "list", "--value=nine" })
  eq(bad.code, 2)
  has(bad.err, "--value")

  -- the guard rail: starting a task that is for you warns (and still works)
  local guard = run({ "set", "lib.nvim/cli-decision", "status=doing" })
  eq(guard.code, 0, "no refusal")
  has(guard.err, "actor: me")
  local quiet = run({ "set", "lib.nvim/cli-valued", "status=doing" })
  eq(quiet.err, "", "no warning for a task that is not yours")
  eq(
    run({ "set", "lib.nvim/cli-decision", "status=decision" }).code,
    0,
    "back to waiting for the decision"
  )

  -- ── migrate-actor: dry run writes nothing, --write writes, the rest stays empty ──
  local function actor_of(id)
    return scan.find(id, { root = croot }).actor
  end
  local dry = run({ "migrate-actor", "lib.nvim" })
  eq(dry.code, 0, dry.err)
  has(dry.out, "propose\tlib.nvim/cli-decision\tme\tstatus: decision")
  has(dry.out, "propose\tlib.nvim/cli-tagged\tme\ttag needs-user")
  has(dry.err, "dry run")
  eq(actor_of("lib.nvim/cli-decision"), nil, "the dry run changed nothing")
  eq(actor_of("lib.nvim/cli-tagged"), nil)
  local wrote = run({ "migrate-actor", "lib.nvim", "--write" })
  eq(wrote.code, 0, wrote.err)
  has(wrote.out, "set\tlib.nvim/cli-decision\tme")
  eq(actor_of("lib.nvim/cli-decision"), "me")
  eq(actor_of("lib.nvim/cli-tagged"), "me")
  eq(actor_of("lib.nvim/cli-other"), nil, "an unclassifiable task stays empty")
  local again = run({ "migrate-actor", "lib.nvim", "--write" })
  eq(again.code, 0)
  eq(again.out, "", "nothing left to propose the second time")
  has(again.err, "0 proposed")

  local proposals, left = batch.plan_actor_migration({
    task("m1", {}, "decision"),
    task("m2", { { "actor", "cdx" } }, "decision"),
    task("m3", {}),
  })
  eq(#proposals, 1, "a task with a written actor is never proposed")
  eq(proposals[1].id, "a/m1")
  eq(left, 1)

  -- ── dashboard core: row, chips, filter menu and the stored filter ──
  local core = require("tasks_nvim.ui.dash_core")
  local shown = task("dash", { { "value", "4" }, { "effort", "S" }, { "actor", "cdx" } })
  local text = core.line(shown, { area = 1, effort = 1, status = 4 })
  has(text, "v4")
  has(text, "[cdx]")
  has(core.search_text(shown), "cdx")
  ok(vim.tbl_contains(core.FILTER_DIMS, "value"))
  ok(vim.tbl_contains(core.FILTER_DIMS, "actor"))
  eq(core.dim_choices("actor", {}), { "cdx", "me", "pair", "none" })
  local chip_filter = core.set_dim(core.set_dim({}, "value", ">=4"), "actor", "me")
  eq(core.chips(chip_filter), { "value: >=4", "actor: me" })
  local stored = core.filter_to_options(chip_filter)
  eq(stored, { value = ">=4", actor = "me" })
  local back = core.filter_from_stored(stored)
  eq(back.value_min, 4)
  eq(back.actor, { "me" })
  eq(core.set_dim(chip_filter, "value", nil).value_min, nil, "clearing the dimension")

  -- ── the form offers both fields ──
  local form = require("tasks_nvim.form")
  local lines = form.template({ areas = { "lib.nvim" }, title = "Form task", area = "lib.nvim" })
  local template = table.concat(lines, "\n")
  has(template, "## value")
  has(template, "## actor")
  for i, l in ipairs(lines) do
    if l:match("^%- %[ %] 4$") or l:match("^%- %[ %] cdx$") then
      lines = form.toggle(lines, i) or lines
    end
  end
  local parsed = assert(form.validate(form.parse(lines), { "lib.nvim" }))
  eq(parsed.opts.value, "4", "a ticked value reaches mutate.new as written")
  eq(parsed.opts.actor, "cdx")
end
