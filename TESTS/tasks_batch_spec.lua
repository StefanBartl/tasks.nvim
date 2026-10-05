-- TESTS/tasks_batch_spec.lua -- tasks_nvim.batch (several set / done in one go) and scan.open_tasks.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local batch = require("tasks_nvim.batch")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local a = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Batch a" })))
  local b = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Batch b" })))
  local c = assert(mutate.new("cascade.nvim", vim.tbl_extend("force", o, { title = "Batch c" })))

  -- ── open_tasks: one area, all areas, with the count of what was left out ──
  local open, skipped, errors = scan.open_tasks({ root = root, area = "lib.nvim" })
  eq(#open, 2, "the open tasks of one area")
  eq(skipped, 0)
  eq(errors, {})
  eq(#scan.open_tasks({ root = root }), 3, "and of every area")
  local none, why = scan.open_tasks({ root = root, area = "bad/area" })
  eq(none, nil, "an invalid area name is an error, not an empty list")
  ok(type(why) == "string")

  -- ── set_many: changed, unchanged, failed, one index write per touched area ──
  local res = batch.set_many({
    { id = a.id, patch = { prio = "1" } },
    { id = b.id, patch = { prio = "2" } },
    { id = c.id, patch = { prio = "3" } },
    { id = "lib.nvim/ghost", patch = { prio = "1" } },
  }, { root = root, today = F.TODAY })
  eq(#res.changed, 3)
  eq(#res.failed, 1)
  has(res.failed[1].err, "no such")
  eq(res.areas, { "cascade.nvim", "lib.nvim" }, "each touched area once, sorted")
  eq(res.index_errors, {})

  -- ── expect: a step planned from an old value is refused ─────────────────
  assert(mutate.set(a.id, { status = "blocked" }, o))
  local stale = batch.set_many({
    { id = a.id, patch = { status = "parked" }, expect = { key = "status", value = "open" } },
  }, { root = root, today = F.TODAY })
  eq(#stale.failed, 1, "the task is no longer open: refused")
  has(stale.failed[1].err, "changed since the list was read")
  eq(scan.find(a.id, { root = root }).status, "blocked", "and untouched")
  local fresh = batch.set_many({
    { id = a.id, patch = { status = "parked" }, expect = { key = "status", value = "blocked" } },
  }, { root = root, today = F.TODAY })
  eq(#fresh.changed, 1, "with the right expectation it writes")

  -- ── done_many ───────────────────────────────────────────────────────────
  local done = batch.done_many({ a.id, b.id, "lib.nvim/ghost" }, { root = root, today = F.TODAY })
  eq(#done.done, 2)
  eq(#done.failed, 1)
  eq(done.areas, { "lib.nvim" })
  local again = batch.done_many({ a.id }, { root = root, today = F.TODAY })
  eq(again.already, { a.id }, "a finished task answers already")
  eq(#again.areas, 0, "and regenerates nothing")
end
