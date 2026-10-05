-- TESTS/tasks_plans_spec.lua -- plan files (`ROADMAP/plans/`), the task fields `plan:` / `phase:`, stages and gates, the
-- `--plan=` scope, marker blocks in documents, and closing a plan.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local plan = require("tasks_nvim.plan")
  local plan_view = require("tasks_nvim.plan_view")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")

  -- ── parsing a plan file ──
  local function parse(extra, body)
    local lines = { "---" }
    for _, kv in ipairs(extra) do
      lines[#lines + 1] = kv[1] .. ": " .. kv[2]
    end
    lines[#lines + 1] = "---"
    return plans.parse(
      table.concat(lines, "\n") .. "\n" .. (body or "\nOne line of goal.\n"),
      { path = "/v/a/ROADMAP/plans/big.md", area = "a" }
    )
  end
  local good = parse({
    { "title", "Big thing" },
    { "status", "doing" },
    { "areas", "[a, b]" },
    { "target", "a/last-task" },
    { "phase_order", "[clarify, build, ship]" },
    { "gate", "hard" },
    { "created", "2026-10-01" },
  })
  ok(good.valid, table.concat(good.errors, "; "))
  eq(good.id, "a/big")
  eq(good.areas, { "a", "b" })
  eq(good.phase_order, { "clarify", "build", "ship" })
  eq(good.gate, "hard")
  eq(good.target, "a/last-task")
  eq(good.summary, "One line of goal.")
  for _, case in ipairs({
    { { { "title", "T" }, { "status", "wip" } }, "plan-bad-status" },
    { { { "title", "T" } }, "plan-bad-status" },
    { { { "status", "doing" } }, "title-missing" },
    { { { "title", "T" }, { "status", "doing" }, { "gate", "soft" } }, "plan-bad-gate" },
    { { { "title", "T" }, { "status", "doing" }, { "target", "nope" } }, "plan-bad-target" },
    { { { "title", "T" }, { "status", "doing" }, { "areas", "[../x]" } }, "plan-bad-area" },
    { { { "title", "T" }, { "status", "doing" }, { "phase_order", "[Not A Word]" } }, "bad-phase" },
    { { { "title", "T" }, { "status", "doing" }, { "updated", "yesterday" } }, "bad-date" },
  }) do
    local broken = parse(case[1])
    ok(not broken.valid)
    ok(
      vim.tbl_contains(broken.error_codes, case[2]),
      "expected " .. case[2] .. ", got " .. table.concat(broken.error_codes, ",")
    )
  end
  eq(
    plans.parse("no frontmatter", { path = "/v/a/ROADMAP/plans/x.md", area = "a" }).error_codes[1],
    "frontmatter-missing"
  )

  -- ── the task fields ──
  local function task(extra)
    return model.parse_text(
      F.text(F.meta("T", "open", extra)),
      { path = "/v/a/ROADMAP/tasks/t.md", area = "a" }
    )
  end
  local member = task({ { "plan", "a/big" }, { "phase", "build" } })
  eq(member.plan, "a/big")
  eq(member.phase, "build")
  eq(task({ { "plan", "not-an-id" } }).error_codes, { "bad-plan" })
  eq(task({ { "phase", "Not A Word" } }).error_codes, { "bad-phase" })
  eq(task({}).plan, nil)

  -- ── a vault with a plan ──
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Ship the thing",
    areas = "lib.nvim,cascade.nvim",
    phases = "clarify,build,ship",
    summary = "Get the thing out.",
  }))
  eq(made.id, "lib.nvim/ship-the-thing")
  ok(H.exists(made.path))
  has(H.read(made.path), "phase_order: [clarify, build, ship]")
  has(H.read(made.path), "## Ziel und Abgrenzung")
  local second =
    assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Ship the thing" }))
  eq(second.id, "lib.nvim/ship-the-thing-2", "a taken slug is never overwritten")
  local _, terr = plans.new("lib.nvim", { root = root, title = "x", gate = "soft" })
  has(terr, "gate must be")
  local _, serr = plans.new("lib.nvim", { root = root, title = "x", status = "done" })
  has(serr, "unknown plan status")
  local _, aerr = plans.new("nope.nvim", { root = root, title = "x" })
  has(aerr, "unknown area")
  assert(vim.fn.delete(second.path) == 0)

  local all = assert(plans.all({ root = root }))
  eq(#all, 1)
  eq(assert(plans.find(made.id, { root = root })).title, "Ship the thing")
  local _, ferr = plans.find("lib.nvim/nothing", { root = root })
  has(ferr, "no such open plan")

  -- members, through the engine
  local function new(title, extra)
    return assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {}))
    ).id
  end
  local clarify = new("Clarify it", { plan = made.id, phase = "clarify", effort = "S" })
  local build = new("Build it", { plan = made.id, phase = "build", effort = "M" })
  local ship = new("Ship it", { plan = made.id, phase = "ship", effort = "XS" })
  local loose = new("Loose task")
  local _, perr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad plan", plan = "nonsense" }))
  has(perr, "plan:")
  local _, herr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad phase", phase = "Not Ok" }))
  has(herr, "phase must be")
  assert(mutate.set(loose, { plan = made.id, phase = "build" }, o))
  eq(scan.find(loose, { root = root }).plan, made.id)
  assert(mutate.set(loose, { plan = mutate.REMOVE, phase = mutate.REMOVE }, o))
  eq(scan.find(loose, { root = root }).plan, nil)
  ok(vim.tbl_contains(mutate.SETTABLE, "plan"))
  ok(vim.tbl_contains(mutate.SETTABLE, "phase"))
  local open_tasks = assert(scan.open_tasks({ root = root }))
  eq(#plans.members(made.id, open_tasks), 3)

  -- the index never shows plan or phase
  assert(index.write_area("lib.nvim", { root = root }))
  local before = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  assert(mutate.set(loose, { plan = made.id }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  eq(
    H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
    before,
    "plan and phase never reach the generated index"
  )
  assert(mutate.set(loose, { plan = mutate.REMOVE }, o))

  -- ── check ──
  local function codes(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      out[#out + 1] = (f.severity == "warn" and "warn:" or "") .. f.code
    end
    table.sort(out)
    return out
  end
  assert(index.write_area("lib.nvim", { root = root }))
  eq(
    codes(assert(check.run({ root = root }))),
    {},
    "a vault with a plan and its members checks clean"
  )
  assert(mutate.set(loose, { plan = "lib.nvim/ghost-plan" }, o))
  eq(codes(assert(check.run({ root = root }))), { "plan-unknown" })
  assert(mutate.set(loose, { plan = made.id, phase = "invented" }, o))
  eq(
    codes(assert(check.run({ root = root }))),
    { "warn:plan-phase" },
    "a stage the plan does not list"
  )
  assert(mutate.set(loose, { plan = mutate.REMOVE, phase = mutate.REMOVE }, o))
  local narrow = assert(
    plans.new(
      "lib.nvim",
      { root = root, today = F.TODAY, title = "Narrow", areas = "cascade.nvim" }
    )
  )
  assert(mutate.set(loose, { plan = narrow.id }, o))
  eq(
    codes(assert(check.run({ root = root }))),
    { "warn:plan-area" },
    "the plan does not list the task's area"
  )
  assert(mutate.set(loose, { plan = mutate.REMOVE }, o))
  vim.fn.delete(narrow.path)
  H.write(root .. "/lib.nvim/ROADMAP/plans/broken.md", "---\ntitle: Broken\nstatus: wip\n---\n")
  eq(codes(assert(check.run({ root = root }))), { "plan-bad-status" })
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/plans/broken.md")
  H.write(
    root .. "/lib.nvim/ROADMAP/plans/lost-target.md",
    "---\ntitle: Lost\nstatus: planning\ntarget: lib.nvim/never-existed\n---\n"
  )
  eq(codes(assert(check.run({ root = root }))), { "warn:plan-target-unknown" })
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/plans/lost-target.md")

  -- ── stages follow phase_order; a gate makes them real blockers ──
  local function build_plan(file_tasks, files)
    local idx = plan.index(file_tasks, {}, files)
    return plan.build(file_tasks, idx), idx
  end
  local soft_file = plans.parse(
    "---\ntitle: Soft\nstatus: doing\nphase_order: [one, two, three]\n---\n",
    { path = "/v/a/ROADMAP/plans/soft.md", area = "a" }
  )
  local function t(id, ph, extra)
    local area, slug = id:match("^([^/]+)/(.+)$")
    local m = { { "plan", "a/soft" } }
    if ph then
      m[#m + 1] = { "phase", ph }
    end
    for _, kv in ipairs(extra or {}) do
      m[#m + 1] = kv
    end
    return model.parse_text(
      F.text(F.meta(slug, "open", m)),
      { path = "/v/" .. area .. "/ROADMAP/tasks/" .. slug .. ".md", area = area }
    )
  end
  local staged = { t("a/x1", "one"), t("a/x2", "two"), t("a/x3", "three"), t("a/free") }
  staged[4] = model.parse_text(
    F.text(F.meta("free", "open")),
    { path = "/v/a/ROADMAP/tasks/free.md", area = "a" }
  )
  local sp, sidx = build_plan(staged, { soft_file })
  eq(sp.nodes["a/x1"].stage, 0)
  eq(sp.nodes["a/x2"].stage, 1, "stage two follows stage one")
  eq(sp.nodes["a/x3"].stage, 2)
  eq(sp.nodes["a/free"].stage, 0, "a task of no plan is not moved")
  ok(plan.ready(staged[2], sidx), "without a gate the order is only a hint: still startable")

  local hard_file = plans.parse(
    "---\ntitle: Hard\nstatus: doing\nphase_order: [one, two, three]\ngate: hard\n---\n",
    { path = "/v/a/ROADMAP/plans/soft.md", area = "a" }
  )
  local hp, hidx = build_plan(staged, { hard_file })
  ok(
    not plan.ready(staged[2], hidx),
    "with gate: hard a stage may not begin before the earlier one is finished"
  )
  eq(hp.nodes["a/x2"].state, "waiting")
  eq(hp.nodes["a/x2"].open_blockers, { "a/x1" })
  ok(plan.ready(staged[1], hidx))
  eq(hp.nodes["a/x1"].leverage, 2, "and the gate counts as leverage")
  -- a gap in the stages is skipped: three follows one when two has no task
  local gap = { staged[1], staged[3] }
  local gp = build_plan(gap, { hard_file })
  eq(gp.nodes["a/x3"].open_blockers, { "a/x1" })
  -- a finished plan file orders nothing
  local done_file = plans.parse(
    "---\ntitle: Done\nstatus: done\nphase_order: [one, two]\ngate: hard\n---\n",
    { path = "/v/a/ROADMAP/plans/soft.md", area = "a" }
  )
  local dp = build_plan(staged, { done_file })
  eq(dp.nodes["a/x2"].stage, 0)

  -- ── the --plan= scope through the real vault ──
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local ids = vim.split(vim.trim(run({ "plan", "--plan=" .. made.id, "--format=ids" }).out), "\n")
  eq(ids, { clarify, build, ship }, "the members in stage order: clarify, build, ship")
  local md = run({ "plan", "--plan=" .. made.id }).out
  has(md, "# Plan: plan " .. made.id)
  has(md, "**Ship the thing** (planning)")
  has(md, "Get the thing out.")
  has(md, "Stages: clarify > build > ship")
  has(md, "## Stage 2")
  eq(run({ "plan", "--plan=lib.nvim/nothing" }).code, 1)
  has(run({ "plan", "--plan=lib.nvim/nothing" }).err, "no such open plan")
  has(run({ "estimate", "--plan=" .. made.id }).out, "3 tasks")

  -- gate: hard in the real vault: list --ready follows it
  local gated = assert(plans.new("cascade.nvim", {
    root = root,
    today = F.TODAY,
    title = "Gated",
    phases = "first,second",
    gate = "hard",
  }))
  local g1 = assert(
    mutate.new(
      "cascade.nvim",
      vim.tbl_extend("force", o, { title = "G one", plan = gated.id, phase = "first" })
    )
  ).id
  local g2 = assert(
    mutate.new(
      "cascade.nvim",
      vim.tbl_extend("force", o, { title = "G two", plan = gated.id, phase = "second" })
    )
  ).id
  local ready =
    vim.split(vim.trim(run({ "list", "cascade.nvim", "--ready", "--format=ids" }).out), "\n")
  ok(vim.tbl_contains(ready, g1))
  ok(not vim.tbl_contains(ready, g2), "list --ready sees the gate: one definition")
  local nxt = run({ "next", "cascade.nvim" }).out
  lacks(nxt, g2, "and so does next")

  -- ── plan-new through the CLI ──
  local created = run({ "plan-new", "lib.nvim", "From the CLI", "--phases=a,b", "--gate=hard" })
  eq(created.code, 0, created.err)
  has(created.out, "created\tlib.nvim/from-the-cli")
  eq(run({ "plan-new", "lib.nvim" }).code, 2)
  eq(run({ "plan-new", "lib.nvim", "Bad", "--gate=soft" }).code, 1)
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/plans/from-the-cli.md")

  -- ── marker blocks: only the block changes, the rest stays byte for byte ──
  local start, finish = plan_view.block_markers("ship-the-thing")
  eq(start, "<!-- GENERATED:plan scope=ship-the-thing start -->")
  eq(finish, "<!-- GENERATED:plan end -->")
  local doc = "# Handover\r\n\r\nhand-written intro\r\n\r\n"
    .. start
    .. "\r\nOLD\r\n"
    .. finish
    .. "\r\n\r\ntail\r\n"
  local fresh, err, changed = plan_view.replace_block(doc, "ship-the-thing", "## New\n\ntext\n")
  eq(err, nil)
  ok(changed)
  eq(
    fresh,
    "# Handover\r\n\r\nhand-written intro\r\n\r\n"
      .. start
      .. "\r\n## New\r\n\r\ntext\r\n"
      .. finish
      .. "\r\n\r\ntail\r\n",
    "CRLF kept, the rest untouched"
  )
  local same, _, changed2 =
    plan_view.replace_block(assert(fresh), "ship-the-thing", "## New\n\ntext\n")
  eq(same, fresh)
  eq(changed2, false)
  local none, nerr = plan_view.replace_block(doc, "other-scope", "x")
  eq(none, nil)
  has(nerr, "no block")
  has(nerr, "ship-the-thing", "the error lists the scopes the file has")
  local open_end, oerr = plan_view.replace_block("a\n" .. start .. "\nb\n", "ship-the-thing", "x")
  eq(open_end, nil)
  has(oerr, "no `<!-- GENERATED:plan end -->`")
  local twice = start
    .. "\none\n"
    .. finish
    .. "\n"
    .. plan_view.block_markers("two")
    .. "\nx\n"
    .. finish
    .. "\n"
  eq(plan_view.block_scopes(twice), { "ship-the-thing", "two" })
  local second_only = assert(plan_view.replace_block(twice, "two", "y"))
  has(second_only, "one", "the other block is left alone")

  -- through the CLI: --write, --check, unchanged, the default scope names
  local doc_path = H.tmpdir() .. "/IMPLEMENTATION.md"
  H.write(doc_path, "# Doc\n\nintro\n\n" .. start .. "\nSTALE\n" .. finish .. "\n\nend\n")
  local stale = run({ "plan", "--plan=" .. made.id, "--write=" .. doc_path, "--check" })
  eq(stale.code, 1, "--check: out of date")
  has(stale.out, "stale\t" .. doc_path)
  eq(H.read(doc_path):find("STALE", 1, true) ~= nil, true, "--check writes nothing")
  local wrote = run({ "plan", "--plan=" .. made.id, "--write=" .. doc_path })
  eq(wrote.code, 0, wrote.err)
  has(wrote.out, "written\t" .. doc_path)
  local text = H.read(doc_path)
  lacks(text, "STALE")
  has(text, "## Ready now", "headings sit one level below the document's own")
  lacks(
    text,
    "GENERATED by `tasks plan`",
    "no generated-comment inside a block: the markers say it"
  )
  has(text, "# Doc\n\nintro\n\n")
  has(text, "\nend\n")
  eq(
    run({ "plan", "--plan=" .. made.id, "--write=" .. doc_path }).out,
    "unchanged\t" .. doc_path .. "\n"
  )
  eq(run({ "plan", "--plan=" .. made.id, "--write=" .. doc_path, "--check" }).code, 0, "current")
  local missing = run({ "plan", "lib.nvim", "--write=" .. doc_path })
  eq(missing.code, 1)
  has(missing.err, "scope=lib.nvim")
  has(missing.err, "ship-the-thing")
  eq(run({ "plan", "--plan=" .. made.id, "--write=" .. H.tmpdir() .. "/nope.md" }).code, 1)
  eq(run({ "plan", "lib.nvim", "--check" }).code, 2, "--check needs --write")
  eq(plan_view.default_scope({ plan_id = "x/y-z" }), "y-z")
  eq(plan_view.default_scope({ for_id = "x/y-z" }), "for-y-z")
  eq(plan_view.default_scope({ area = "lib.nvim" }), "lib.nvim")
  eq(plan_view.default_scope({}), "all")

  -- ── closing a plan: moved to Backlog/FEATURES, a README row, rollback ──
  local closed = assert(plans.close(made.id, o))
  eq(closed.readme, "updated")
  ok(not H.exists(made.path))
  ok(H.exists(closed.to))
  has(closed.to, "2026-10-03_ship-the-thing.md")
  has(H.read(closed.to), "status: done")
  has(H.read(root .. "/lib.nvim/Backlog/README.md"), "ship-the-thing")
  has(H.read(root .. "/lib.nvim/Backlog/README.md"), "FEATURES/2026-10-03_ship-the-thing.md")
  local again = assert(plans.close(made.id, o))
  eq(again.to, closed.to, "already finished: nothing changes")
  local _, cerr = plans.close("lib.nvim/never-was", o)
  has(cerr, "no such open plan")
  -- a failing README write puts everything back
  local rb = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Rollback me" }))
  local readme = root .. "/lib.nvim/Backlog/README.md"
  local readme_before = H.read(readme)
  local real_write = require("tasks_nvim.fsio").write_atomic
  require("tasks_nvim.fsio").write_atomic = function(path, text2)
    if path == readme then
      return false, "disk full (test)"
    end
    return real_write(path, text2)
  end
  local failed, ferr2 = plans.close(rb.id, o)
  require("tasks_nvim.fsio").write_atomic = real_write
  eq(failed, nil)
  has(ferr2, "disk full")
  ok(H.exists(rb.path), "the plan file is back")
  ok(
    not H.exists(root .. "/lib.nvim/Backlog/FEATURES/2026-10-03_rollback-me.md"),
    "and no finished copy is left"
  )
  eq(H.read(readme), readme_before, "the README is untouched")
end
