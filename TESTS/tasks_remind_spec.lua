-- TESTS/tasks_remind_spec.lua -- the reminder (`remind`): a date on a task that says "look at it again then".
-- Model (dates, relative input), `set`, finishing with a reminder, the contract entry, the filter.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local api = require("tasks_nvim.api")
  local filter_opts = require("tasks_nvim.filter_opts")
  local scan = require("tasks_nvim.scan")

  -- ── dates ──────────────────────────────────────────────────────────────
  eq(model.add_days("2026-01-30", 3), "2026-02-02")
  eq(model.add_days("2026-12-31", 1), "2027-01-01")
  eq(model.add_days("2028-02-28", 1), "2028-02-29", "a leap year")
  eq(model.add_days("2027-02-28", 1), "2027-03-01")
  eq(model.add_days("2026-03-01", -1), "2026-02-28")
  eq(model.add_days("2026-01-01", 0), "2026-01-01")
  eq(model.add_days("not a date", 1), nil)

  eq(model.resolve_remind("2026-05-05", "2026-01-30"), "2026-05-05", "a date stays")
  eq(model.resolve_remind("+3d", "2026-01-30"), "2026-02-02")
  eq(model.resolve_remind("+2w", "2026-01-30"), "2026-02-13")
  eq(model.resolve_remind("+0d", "2026-01-30"), "2026-01-30")
  for _, bad in ipairs({ "+400d", "soon", "3d", "+d", "2026-13-01", "" }) do
    local date, err = model.resolve_remind(bad, "2026-01-30")
    eq(date, nil, bad)
    ok(type(err) == "string" and err ~= "", "says why: " .. bad)
  end
  local nothing, err = model.resolve_remind(7, "2026-01-30")
  eq(nothing, nil)
  has(err, "date")

  -- ── a task file with a reminder ───────────────────────────────────────
  local parsed = model.parse_text(
    "---\ntitle: A\nstatus: open\nremind: 2026-02-03\ncreated: 2026-01-01\n---\n\nBody.\n",
    { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
  )
  eq(parsed.remind, "2026-02-03")
  local broken = model.parse_text(
    "---\ntitle: A\nstatus: open\nremind: soon\n---\n\nBody.\n",
    { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
  )
  ok(
    vim.tbl_contains(broken.error_codes, "bad-date"),
    "a reminder that is no date is a finding: " .. table.concat(broken.error_codes, ",")
  )
  eq(broken.valid, false)

  -- ── set: a date, days, weeks, and taking it away ──────────────────────
  local root = fixture.build(H)
  local r, serr = mutate.set(
    "lib.nvim/alpha",
    { remind = "+7d" },
    { root = root, today = "2026-03-01", index = false }
  )
  ok(r, tostring(serr))
  has(H.read(root .. "/lib.nvim/ROADMAP/tasks/alpha.md"), "remind: 2026-03-08")
  r = mutate.set(
    "lib.nvim/alpha",
    { remind = "2026-04-01" },
    { root = root, today = "2026-03-01", index = false }
  )
  has(H.read(root .. "/lib.nvim/ROADMAP/tasks/alpha.md"), "remind: 2026-04-01")
  local _, bad_err = mutate.set(
    "lib.nvim/alpha",
    { remind = "whenever" },
    { root = root, index = false }
  )
  has(bad_err, "remind")
  r = mutate.set(
    "lib.nvim/alpha",
    { remind = mutate.REMOVE },
    { root = root, today = "2026-03-01", index = false }
  )
  ok(not H.read(root .. "/lib.nvim/ROADMAP/tasks/alpha.md"):find("remind:", 1, true), "taken away")

  -- ── the contract: the date is in the entry, due-ness is not ──────────
  local text = api.call("task", '{"params":{"id":"lib.nvim/beta"}}', { root = root })
  local doc = vim.json.decode(text)
  eq(doc.task.remind, "2026-01-20")
  local snap = vim.json.decode((api.call("snapshot", nil, { root = root })))
  local found
  for _, t in ipairs(snap.tasks) do
    if t.id == "lib.nvim/beta" then
      found = t
    end
  end
  eq(found.remind, "2026-01-20")
  ok(found.reminder_due == nil, "a derived 'due' would change the digest with the day")
  local hello = vim.json.decode((api.call("hello", nil, { root = root })))
  ok(vim.tbl_contains(hello.capabilities, "reminders"), "the capability is told")

  -- ── the filter: due on the day and after, not before ─────────────────
  local tasks = scan.collect and scan.collect({ root = root }) or nil
  local function due_on(today)
    local f = assert(filter_opts.parse({ reminders = true, today = today }))
    local list = scan.all and scan.all({ root = root }) or {}
    local kept = model.filter(list.tasks or list, f)
    local ids = {}
    for _, t in ipairs(kept) do
      ids[#ids + 1] = t.id
    end
    return ids
  end
  if tasks ~= nil or scan.all ~= nil then
    eq(due_on("2026-01-19"), {})
    eq(due_on("2026-01-20"), { "lib.nvim/beta" })
    eq(due_on("2026-02-01"), { "lib.nvim/beta" })
  end

  -- ── a finished task: the reminder is seen and can be taken away, nothing else of it can change ──
  local reminders = snap.reminders
  eq(#reminders, 1, "the finished task with a reminder is in the snapshot")
  eq(reminders[1].id, "lib.nvim/old-done")
  eq(reminders[1].remind, "2026-02-01")
  ok(reminders[1].etag ~= nil, "with the version of its file")
  local done_path = root .. "/lib.nvim/Backlog/TASKS/2026-01-02_old-done.md"
  local before = H.read(done_path)
  local _, refused_err = mutate.set(
    "lib.nvim/old-done",
    { prio = 1 },
    { root = root, index = false }
  )
  has(refused_err, "no such open task")
  eq(H.read(done_path), before, "a finished task is not changed by anything but its reminder")
  local moved = mutate.set(
    "lib.nvim/old-done",
    { remind = "+10d" },
    { root = root, today = "2026-03-01", index = false }
  )
  ok(moved ~= nil and moved.changed, "a reminder is set on a finished task")
  local after = H.read(done_path)
  has(after, "remind: 2026-03-11")
  ok(
    after:find("updated: " .. (before:match("updated: (%d%d%d%d%-%d%d%-%d%d)") or "?"), 1, true),
    "`updated` stays"
  )
  local via_ops = vim.json.decode(
    (
      api.call(
        "ops",
        vim.json.encode({
          ops = { { op = "set", id = "lib.nvim/old-done", patch = { remind = vim.NIL } } },
        }),
        { root = root }
      )
    )
  )
  eq(via_ops.ok, true, vim.inspect(via_ops))
  ok(not H.read(done_path):find("remind:", 1, true), "taken away through ops")
  eq(#vim.json.decode((api.call("snapshot", nil, { root = root }))).reminders, 0)

  -- ── finishing with a reminder ─────────────────────────────────────────
  local pv = vim.json.decode(
    (api.call("done_preview", '{"params":{"id":"lib.nvim/gamma"}}', { root = root }))
  )
  ok(pv.confirm, "a preview gives a token")
  -- a reminder that is no date is refused before anything moves
  local refused = vim.json.decode((api.call(
    "ops",
    vim.json.encode({
      ops = { { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm, remind = "someday" } },
    }),
    { root = root, today = "2026-03-01" }
  )))
  eq(refused.ok, false)
  eq(refused.results[1].error.code, "invalid_argument")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/gamma.md"), "nothing moved")

  local done = vim.json.decode((api.call(
    "ops",
    vim.json.encode({
      ops = { { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm, remind = "+14d" } },
    }),
    { root = root, today = "2026-03-01" }
  )))
  eq(done.ok, true, vim.inspect(done))
  local moved = H.read(root .. "/" .. done.results[1].to)
  has(moved, "remind: 2026-03-15")
  has(moved, "status: done")
end
