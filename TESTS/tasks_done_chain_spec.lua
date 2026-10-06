-- TESTS/tasks_done_chain_spec.lua -- what finishing a task sets in motion: its own plan steps ticked (written with the
-- finish), the plan file closed with its last member, the generated blocks of the configured documents refreshed.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace
-- module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local done_flow = require("tasks_nvim.done_flow")
  local batch = require("tasks_nvim.batch")
  local config = require("tasks_nvim.config")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local plan_view = require("tasks_nvim.plan_view")
  local scan = require("tasks_nvim.scan")
  local cli = require("tasks_nvim.cli")
  local fsio = require("tasks_nvim.fsio")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local function new(title, extra)
    return assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {}))
    )
  end
  local function add_plan_section(task, section)
    H.write(task.path, H.read(task.path) .. "\n" .. section)
  end

  -- ── a: the task's own steps are ticked, written with the finish ──
  local stepper = new("Stepper")
  add_plan_section(
    stepper,
    table.concat({
      "## Plan",
      "",
      "- [x] 1. already done",
      "- [ ] 2. open one",
      "- [ ] 3. decided against (dropped)",
      "- [ ] 4. open two",
      "",
    }, "\n")
  )
  local flow = assert(done_flow.run(stepper.id, o))
  eq(flow.steps_ticked, 2, "two open steps ticked, the dropped one is not")
  local finished = H.read(flow.done.to)
  has(finished, "- [x] 2. open one")
  has(finished, "- [x] 4. open two")
  has(finished, "- [ ] 3. decided against (dropped)")
  eq(flow.done.steps_ticked, 2)
  local plain = new("No steps")
  eq(assert(done_flow.run(plain.id, o)).steps_ticked, 0, "no section, nothing to tick")
  -- chain = false: the very same finish without ticking
  local manual = new("Manual")
  add_plan_section(manual, "## Plan\n\n- [ ] 1. open\n")
  local no_chain = assert(done_flow.run(manual.id, vim.tbl_extend("force", o, { chain = false })))
  eq(no_chain.steps_ticked, 0)
  has(H.read(no_chain.done.to), "- [ ] 1. open")

  -- the ticks are covered by the rollback: a failing step puts everything back
  local rb = new("Rollback steps")
  add_plan_section(rb, "## Plan\n\n- [ ] 1. open\n")
  local rb_before = H.read(rb.path)
  local readme = root .. "/lib.nvim/Backlog/README.md"
  local real_write = fsio.write_atomic
  fsio.write_atomic = function(path, text)
    if path == readme then
      return false, "disk full (test)"
    end
    return real_write(path, text)
  end
  local failed, ferr = done_flow.run(rb.id, o)
  fsio.write_atomic = real_write
  eq(failed, nil)
  has(ferr, "disk full")
  eq(H.read(rb.path), rb_before, "the task file is as it was: no step ticked, nothing moved")
  ok(not H.exists(root .. "/lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_rollback-steps.md"))

  -- ── b: the plan closes with its last member ──
  local file = assert(
    plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Chain plan", phases = "a,b" })
  )
  local m1 = new("Member one", { plan = file.id, phase = "a", effort = "S" })
  local m2 = new("Member two", { plan = file.id, phase = "b", effort = "M" })
  local first = assert(done_flow.run(m1.id, o))
  eq(first.plans_closed, {}, "another member is still open: the plan stays")
  ok(H.exists(file.path))
  local last = assert(done_flow.run(m2.id, vim.tbl_extend("force", o, { date = "2026-10-03" })))
  eq(last.plans_closed, { file.id })
  ok(not H.exists(file.path), "the plan file left ROADMAP/plans")
  ok(H.exists(root .. "/lib.nvim/Backlog/FEATURES/2026-10-03_chain-plan.md"))
  has(H.read(root .. "/lib.nvim/Backlog/README.md"), "chain-plan")
  local summary = last.plan_summaries[file.id]
  eq(summary.title, "Chain plan")
  eq(summary.tasks, 2)
  eq(summary.days, 1.5, "S + M on the scale")
  eq(summary.n_without_effort, 0)
  ok(summary.days_taken ~= nil)
  local text = plan_view.plan_closed_text(file.id, summary)
  has(text, "Plan lib.nvim/chain-plan is done: 2 tasks, estimate 1.5 d")
  has(text, "finished in")
  eq(plan_view.plan_closed_text("a/b"), "Plan a/b is done")
  -- and the next-task message carries it
  local message = table.concat(plan_view.next_message(last.next, m2.id, last), "\n")
  has(message, "Done: " .. m2.id)
  has(message, "Plan lib.nvim/chain-plan is done")
  -- a task of no plan, and one of a plan that is not there: nothing to close
  eq(assert(done_flow.run(new("Free").id, o)).plans_closed, {})
  local orphan = new("Orphan", { plan = "lib.nvim/not-a-plan" })
  local orphan_flow = assert(done_flow.run(orphan.id, o))
  eq(orphan_flow.plans_closed, {})
  eq(orphan_flow.notes, {}, "a missing plan file is `check`'s business, not a note")
  -- an already finished task runs no chain
  local again = assert(done_flow.run(m2.id, o))
  ok(again.done.already)
  eq(again.plans_closed, {})
  eq(again.steps_ticked, 0)

  -- ── c: generated blocks of the configured documents ──
  local plan_b = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Doc plan" }))
  local d1 = new("Doc one", { plan = plan_b.id, effort = "S" })
  local d2 = new("Doc two", { plan = plan_b.id, effort = "S" })
  local doc = H.tmpdir() .. "/HANDOVER.md"
  local start_a, finish = plan_view.block_markers("doc-plan")
  local start_b = plan_view.block_markers("lib.nvim")
  local start_c = plan_view.block_markers("old-plan")
  local start_d = plan_view.block_markers("no-such-thing")
  H.write(
    doc,
    table.concat({
      "# Handover",
      "",
      "hand-written",
      "",
      start_a,
      "STALE A",
      finish,
      "",
      start_b,
      "STALE B",
      finish,
      "",
      start_c,
      "HISTORY",
      finish,
      "",
      start_d,
      "UNKNOWN",
      finish,
      "",
      "the end",
      "",
    }, "\n")
  )
  -- the finished plan from above is "old-plan" for this test: its block is history
  local old = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Old plan" }))
  local old_member = new("Old member", { plan = old.id })
  assert(
    done_flow.run(
      old_member.id,
      vim.tbl_extend("force", o, { pick_next = false, refresh_docs = false })
    )
  )
  ok(not H.exists(old.path), "the old plan is finished")

  -- nothing configured: the document is never touched
  local untouched = H.read(doc)
  assert(done_flow.run(new("Quiet").id, o))
  eq(H.read(doc), untouched, "no marker_docs configured: not a byte changes")

  config.merge({ chain = { marker_docs = { doc } } })
  local with_doc = assert(done_flow.run(d1.id, o))
  eq(with_doc.docs_refreshed, { doc })
  local refreshed = H.read(doc)
  lacks(refreshed, "STALE A")
  lacks(refreshed, "STALE B")
  has(refreshed, "Doc two", "the plan block shows the member that is still open")
  has(refreshed, "HISTORY", "the block of a finished plan is left as it is")
  has(refreshed, "UNKNOWN", "and so is a block that names nothing")
  has(refreshed, "# Handover\n\nhand-written\n\n", "the hand-written parts are untouched")
  has(refreshed, "\nthe end\n")
  ok(
    vim.tbl_contains(
      with_doc.notes,
      doc .. ": the block `no-such-thing` names no area, open plan or open task"
    ),
    "the unknown block is said once as a note"
  )
  eq(#with_doc.notes, 1, "the finished plan's block is silent")
  -- a second finish with nothing to change leaves the file alone
  local second = assert(done_flow.run(new("Quiet two").id, o))
  eq(second.docs_refreshed, {}, "unchanged blocks are not rewritten")
  -- the last member closes the plan; its block becomes the closing line from then on
  local closing = assert(done_flow.run(d2.id, o))
  eq(closing.plans_closed, { plan_b.id })
  has(
    H.read(doc),
    "Plan lib.nvim/doc-plan is done: 2 tasks",
    "its block is rewritten as the closing line, its last state"
  )
  -- a document that cannot be read is a note, and the finish stands
  config.merge({ chain = { marker_docs = { H.tmpdir() .. "/missing.md" } } })
  local lost = new("Lost doc")
  local lost_flow = assert(done_flow.run(lost.id, o))
  ok(H.exists(lost_flow.done.to), "the task is finished")
  eq(#lost_flow.notes, 1)
  has(lost_flow.notes[1], "cannot read")
  config.merge({ chain = { marker_docs = {} } })

  -- ── a batch does the chain per task and the documents once ──
  local plan_c =
    assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Batch plan" }))
  local b1 = new("Batch one", { plan = plan_c.id, effort = "XS" })
  local b2 = new("Batch two", { plan = plan_c.id, effort = "XS" })
  add_plan_section(b1, "## Plan\n\n- [ ] 1. x\n")
  local doc2 = H.tmpdir() .. "/BATCH.md"
  H.write(
    doc2,
    "intro\n" .. plan_view.block_markers("batch-plan") .. "\nSTALE\n" .. finish .. "\nend\n"
  )
  config.merge({ chain = { marker_docs = { doc2 } } })
  local res = batch.done_many({ b1.id, b2.id }, { root = root, today = F.TODAY })
  eq(#res.done, 2)
  eq(res.steps_ticked, 1)
  eq(res.plans_closed, { plan_c.id }, "the plan closed with the last member of the stack")
  eq(res.plan_summaries[plan_c.id].tasks, 2)
  eq(
    res.docs_refreshed,
    { doc2 },
    "the closed plan's block gets the closing line, once for the whole stack"
  )
  has(H.read(doc2), "Plan lib.nvim/batch-plan is done: 2 tasks")
  lacks(H.read(doc2), "STALE")
  config.merge({ chain = { marker_docs = {} } })

  -- ── the headless done prints what happened ──
  local cli_plan =
    assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Cli plan" }))
  local c1 = new("Cli member", { plan = cli_plan.id })
  add_plan_section(c1, "## Plan\n\n- [ ] 1. a\n- [ ] 2. b\n")
  local out = {}
  local code = cli.run({ "done", c1.id, "--vault=" .. root, "--today=" .. F.TODAY }, {
    out = function(t)
      out[#out + 1] = t
    end,
    err = function() end,
  })
  eq(code, 0)
  local printed = table.concat(out)
  has(printed, "steps\t" .. c1.id .. "\t2")
  has(printed, "plan-closed\t" .. cli_plan.id .. "\tPlan " .. cli_plan.id .. " is done: 1 task")
  ok(scan.find_done(c1.id, { root = root }) ~= nil)

  -- ── review fixes: a member is any task of the plan that is not done, and a batch checks each plan once ──
  do
    local tp = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Typo plan" }))
    local good = new("Typo good", { plan = tp.id })
    -- a status nobody wrote down: the file is invalid, but it is still a member that is not done
    F.task(
      H,
      root,
      "lib.nvim",
      "typo-member",
      F.meta("Typo member", "in progress", { { "plan", tp.id } })
    )
    local typo_flow = assert(done_flow.run(good.id, o))
    eq(typo_flow.plans_closed, {}, "a member with a mistyped status keeps the plan open")
    ok(H.exists(tp.path))

    -- a scan that could not list every folder cannot say that no member is left
    local pp =
      assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Partial plan" }))
    local real_all = scan.all
    scan.all = function(sopts)
      local tasks = real_all(sopts)
      return tasks, { "cannot list " .. root .. "/cascade.nvim/ROADMAP/tasks (test)" }
    end
    local partial = done_flow.close_plans({ pp.id }, o)
    scan.all = real_all
    eq(partial.closed, {})
    has(partial.notes[1], "scan was incomplete")
    ok(H.exists(pp.path), "the plan stays")

    -- a batch of members of one plan: one scan for the whole stack, the plan closed once
    local bp = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Scan plan" }))
    local ids = {}
    for i = 1, 3 do
      ids[#ids + 1] = new("Scan member " .. i, { plan = bp.id }).id
    end
    local scans = 0
    scan.all = function(sopts)
      scans = scans + 1
      return real_all(sopts)
    end
    local stack = batch.done_many(ids, vim.tbl_extend("force", o, { pick_next = false }))
    scan.all = real_all
    eq(#stack.done, 3)
    eq(stack.plans_closed, { bp.id }, "the plan is closed once, with its last member")
    ok(scans <= 1, "one scan for the batch, not one per task (" .. scans .. ")")
    ok(not H.exists(bp.path))
  end
end
