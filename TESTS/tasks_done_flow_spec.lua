-- TESTS/tasks_done_flow_spec.lua -- tasks_nvim.done_flow: the one entry for finishing a task.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local done_flow = require("tasks_nvim.done_flow")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local a = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow a" })))
  local b = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow b" })))

  -- ── a finish: what mutate.done returns, and an empty chain report ──
  local flow = assert(done_flow.run(a.id, o))
  eq(flow.done.id, a.id)
  eq(flow.done.bucket, "TASKS")
  ok(H.exists(flow.done.to), "the finished file is in the Backlog")
  eq(scan.find(a.id, { root = root }), nil, "and no longer open")
  eq(flow.steps_ticked, 0)
  eq(flow.freed, {})
  eq(flow.plans_closed, {})
  eq(flow.docs_refreshed, {})
  eq(flow.notes, {})
  eq(flow.next.task.id, b.id, "the next task: the one other open task")
  eq(flow.next.reason, "area")

  -- ── done_in and date pass through to mutate.done ──
  local with = assert(
    done_flow.run(
      b.id,
      vim.tbl_extend("force", o, { done_in = "repo@abc1234", date = "2026-09-09" })
    )
  )
  has(with.done.to, "2026-09-09_flow-b.md")
  has(H.read(with.done.to), "done_in: repo@abc1234")

  -- ── an already finished task changes nothing and runs no chain ──
  local again = assert(done_flow.run(a.id, o))
  ok(again.done.already, "the second call says already")
  eq(again.notes, {})
  eq(again.steps_ticked, 0)

  -- ── a failure is nil, err -- nothing else ──
  local no, err = done_flow.run("lib.nvim/ghost", o)
  eq(no, nil)
  has(err, "no such")
  local bad, bad_err = done_flow.run("not-an-id", o)
  eq(bad, nil)
  ok(type(bad_err) == "string")

  -- ── a finish that frees a task names it, and the next task is that one ──
  local base = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow base" })))
  local after =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow after", prio = 3 })))
  assert(mutate.set(after.id, { blocked_by = "[" .. base.id .. "]" }, o))
  local freeing = assert(done_flow.run(base.id, o))
  eq(freeing.freed, { after.id }, "the last open blocker of `after`")
  eq(freeing.next.task.id, after.id)
  eq(freeing.next.reason, "freed")

  -- ── pick_next = false: the finish alone (a batch picks once at its end) ──
  local solo = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow solo" })))
  local quiet = assert(done_flow.run(solo.id, vim.tbl_extend("force", o, { pick_next = false })))
  eq(quiet.next, nil)
  eq(quiet.freed, {})

  -- ── nothing left: an honest empty answer, not a cheer ──
  for _, t in ipairs(assert(scan.open_tasks({ root = root }))) do
    if t.id ~= "lib.nvim/flow-after" then
      assert(done_flow.run(t.id, vim.tbl_extend("force", o, { pick_next = false })))
    end
  end
  local last = assert(done_flow.run(after.id, o))
  eq(last.next.task, nil)
  eq(last.next.empty.kind, "all_done")

  -- ── chain = false is the same finish without the follow-ups ──
  local c = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Flow c" })))
  local plain = assert(done_flow.run(c.id, vim.tbl_extend("force", o, { chain = false })))
  eq(plain.done.id, c.id)
  eq(plain.notes, {})
  eq(plain.next, nil, "no chain, no next task")
end
