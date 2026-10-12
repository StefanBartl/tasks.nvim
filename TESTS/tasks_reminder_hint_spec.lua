-- TESTS/tasks_reminder_hint_spec.lua -- the line at startup that says how many reminders are due, and `next`, which
-- lists them.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body; the spec replaces the notification channel and the timer
-- on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local hint = require("tasks_nvim.ui.reminder_hint")
  local config = require("tasks_nvim.config")
  local vault = require("tasks_nvim.vault")
  local scan = require("tasks_nvim.scan")
  local cli = require("tasks_nvim.cli")

  local root = fixture.build(H)
  local before = vim.deepcopy(config.get())

  -- the fixture: an open task with a reminder on 2026-01-20, a finished one on 2026-02-01
  local o, d, ids = hint.count({ root = root, today = "2026-01-19" })
  eq({ o, d, ids }, { 0, 0, {} }, "nothing due before the first date")
  o, d, ids = hint.count({ root = root, today = "2026-01-20" })
  eq({ o, d, ids }, { 1, 0, {} }, "the open task on its day")
  o, d, ids = hint.count({ root = root, today = "2026-02-01" })
  eq(
    { o, d, ids },
    { 1, 1, { "lib.nvim/old-done" } },
    "both from the second date on; the finished one by name"
  )

  -- the same numbers in steps, one area per turn of the loop
  local real_schedule, ticks = vim.schedule, 0
  vim.schedule = function(fn)
    ticks = ticks + 1
    return real_schedule(fn)
  end
  local stepped
  hint.count_in_steps({ root = root, today = "2026-02-01" }, function(...)
    stepped = { ... }
  end)
  eq(stepped, nil, "nothing is scanned before the loop turns")
  ok(
    vim.wait(2000, function()
      return stepped ~= nil
    end, 10),
    "the steps finish"
  )
  vim.schedule = real_schedule
  eq(stepped, { 1, 1, { "lib.nvim/old-done" } }, "the same answer")
  ok(ticks >= 3, "an area per turn (two areas, then the end), not one go: " .. ticks)

  -- the scan of one area, and the finished ones in a linked bucket
  eq(#assert(scan.open_reminders({ root = root, area = "lib.nvim" })), 1)
  eq(#assert(scan.open_reminders({ root = root, area = "cascade.nvim" })), 0)
  eq(#assert(scan.backlog_reminders({ root = root, area = "lib.nvim" })), 1)
  eq(#assert(scan.backlog_reminders({ root = root, area = "cascade.nvim" })), 0)

  -- the text
  eq(hint.message(0, 0), nil, "nothing due is silence")
  eq(hint.message(1, 0, { command = true }), "1 reminder due: `:Tasks list --reminders`")
  eq(
    hint.message(2, 1, { ids = { "lib.nvim/old-done" }, command = true }),
    "3 reminders due (1 of them finished: lib.nvim/old-done; `:Tasks open <id>`): `:Tasks list --reminders` for the open ones"
  )
  eq(
    hint.message(0, 1, { ids = { "lib.nvim/old-done" }, command = true }),
    "1 reminder due (1 of them finished: lib.nvim/old-done; `:Tasks open <id>`)",
    "only finished ones: `list --reminders` would show nothing, so it is not pointed at"
  )
  local hostile = hint.message(0, 1, { ids = { "lib.nvim/x\27]0;title\7y\n" }, command = true })
  lacks(hostile, "\27", "a file name with an escape sequence does not reach the line as one")
  lacks(hostile, "\7")
  lacks(hostile, "\n")
  has(hostile, "lib.nvim/x ]0;title y")
  has(
    hint.message(0, 5, { ids = { "a/1", "a/2", "a/3", "a/4", "a/5" }, command = true }),
    "5 reminders due (5 of them finished: a/1, a/2, a/3 +2 more;"
  )
  -- no `:Tasks` (a host that mounts the routes under its own verb): no command in the line
  local no_command = assert(hint.message(1, 1, { ids = { "a/b" }, command = false }))
  eq(
    no_command,
    "2 reminders due (1 of them finished: a/b); the reminders filter lists the open ones"
  )
  lacks(no_command, ":Tasks")
  local asked = assert(hint.message(1, 0))
  eq(
    asked:find(":Tasks", 1, true) ~= nil,
    vim.fn.exists(":Tasks") == 2,
    "without an answer from the caller the command is named when it exists"
  )

  -- the announcement: once, and only when something is due
  local lines = {}
  local notify = require("lib.nvim.notify")
  local orig_create = notify.create
  notify.create = function()
    return {
      info = function(msg)
        lines[#lines + 1] = msg
      end,
    }
  end
  hint.reset()
  eq(hint.announce({ root = root, today = "2026-01-19" }), false, "nothing due: no line")
  eq(#lines, 0)
  hint.reset()
  eq(hint.announce({ root = root, today = "2026-02-01" }), true)
  eq(#lines, 1)
  has(lines[1], "2 reminders due (1 of them finished: lib.nvim/old-done")
  eq(hint.announce({ root = root, today = "2026-02-01" }), false, "once per session")
  eq(#lines, 1)
  -- a vault that is not there is silence
  hint.reset()
  eq(hint.announce({ root = root .. "/nowhere", today = "2026-02-01" }), false)

  -- the same in steps
  ---@param opts table
  ---@return boolean|nil given
  local function announce_in_steps(opts)
    local given
    hint.announce_in_steps(opts, function(g)
      given = g
    end)
    ok(
      vim.wait(2000, function()
        return given ~= nil
      end, 10),
      "the steps finish"
    )
    return given
  end
  lines = {}
  hint.reset()
  eq(announce_in_steps({ root = root, today = "2026-01-19" }), false, "nothing due: no line")
  hint.reset()
  eq(announce_in_steps({ root = root, today = "2026-02-01" }), true)
  eq(#lines, 1)
  has(lines[1], "2 reminders due (1 of them finished: lib.nvim/old-done")
  eq(announce_in_steps({ root = root, today = "2026-02-01" }), false, "once per session")
  eq(#lines, 1)
  hint.reset()
  eq(
    announce_in_steps({ root = root .. "/nowhere", today = "2026-02-01" }),
    false,
    "no vault: silence"
  )

  -- a scan that fails is silence, not an error
  local real_open = scan.open_reminders
  scan.open_reminders = function()
    error("boom")
  end
  hint.reset()
  eq(hint.announce({ root = root, today = "2026-02-01" }), false, "a failing scan is silence")
  hint.reset()
  eq(announce_in_steps({ root = root, today = "2026-02-01" }), false, "... in steps too")
  scan.open_reminders = real_open
  hint.reset()

  -- schedule(): only with a UI, one timer, and the option is read when the timer fires
  local real_defer, real_uis = vim.defer_fn, vim.api.nvim_list_uis
  local timers = {}
  vim.defer_fn = function(fn, ms)
    timers[#timers + 1] = { fn = fn, ms = ms }
  end
  local uis = {}
  vim.api.nvim_list_uis = function()
    return uis
  end
  vault.set_root(root)
  lines = {}
  hint.schedule()
  eq(#timers, 1, "the timer is set before any UI is there (an embedded UI attaches later)")
  eq(timers[1].ms, 3000)
  timers[1].fn()
  vim.wait(100, function()
    return false
  end)
  eq(#lines, 0, "no UI when the timer fires (headless): no line")
  uis = { {} }
  timers = {}
  hint.schedule()
  eq(#timers, 1, "a UI: one timer")
  eq(timers[1].ms, 3000)
  lines = {}
  config.merge({ reminders = { on_start = false } })
  timers[1].fn()
  vim.wait(100, function()
    return false
  end)
  eq(#lines, 0, "turned off after the timer was set: no line")
  config.merge({ reminders = { on_start = true } })
  hint.schedule()
  eq(#timers, 2, "... and the hint was not used up by that")
  timers[2].fn()
  ok(
    vim.wait(2000, function()
      return #lines > 0
    end, 10),
    "turned on: the line comes"
  )
  has(lines[1], "reminders due")
  hint.schedule()
  eq(#timers, 2, "nothing more once it was given")
  vault.set_root(nil)
  vim.defer_fn, vim.api.nvim_list_uis = real_defer, real_uis
  notify.create = orig_create
  hint.reset()

  -- the option: on by default; a bad value is reported and ignored, the default stays
  eq(config.get().reminders.on_start, true)
  config.take_unannounced()
  eq(config.validate({ reminders = { on_start = "no" } }), { reminders = {} })
  has(table.concat(config.take_unannounced(), "\n"), "`reminders.on_start` must be true or false")
  eq(config.validate({ reminders = false }), {})
  has(table.concat(config.take_unannounced(), "\n"), "`reminders` must be a table")
  eq(config.get().reminders.on_start, true, "the default stays")

  -- setup() registers the hint only when the option is on
  local calls = 0
  local real_schedule_hint = hint.schedule
  hint.schedule = function()
    calls = calls + 1
  end
  local tasks_nvim = require("tasks_nvim")
  tasks_nvim.setup({ reminders = { on_start = true } })
  vim.wait(100, function()
    return calls > 0
  end, 10)
  eq(calls, 1, "on: setup() registers the hint")
  tasks_nvim.setup({ reminders = { on_start = false } })
  vim.wait(100, function()
    return false
  end)
  eq(calls, 1, "off: it does not")
  hint.schedule = real_schedule_hint
  config.merge(before)
  config.take_unannounced()

  -- `next` lists them: the open tasks (oldest date first) and the number of finished ones; only when asked
  local next_pick = require("tasks_nvim.next_pick")
  local plan_view = require("tasks_nvim.plan_view")
  local pick =
    assert(next_pick.pick_from_vault({ root = root, today = "2026-02-01", reminders = true }))
  eq(#pick.reminders.open, 1)
  eq(pick.reminders.open[1].id, "lib.nvim/beta")
  eq(pick.reminders.done, 1)
  local next_out = plan_view.next_lines(pick)
  local remind_lines = vim.tbl_filter(function(l)
    return l:find("^remind: ") ~= nil
  end, next_out)
  eq(#remind_lines, 2)
  eq(remind_lines[1], "remind: lib.nvim/beta\t" .. pick.reminders.open[1].title .. "\t2026-01-20")
  has(remind_lines[2], "remind: 1 finished task(s) with a reminder due (`list --done --reminders`)")
  local before_date =
    assert(next_pick.pick_from_vault({ root = root, today = "2026-01-19", reminders = true }))
  eq({ #before_date.reminders.open, before_date.reminders.done }, { 0, 0 })
  eq(#vim.tbl_filter(function(l)
    return l:find("^remind: ") ~= nil
  end, plan_view.next_lines(before_date)), 0, "nothing due: no line")
  -- not asked for: not computed (the sweep of every finished file is for the front end that prints it)
  local plain = assert(next_pick.pick_from_vault({ root = root, today = "2026-02-01" }))
  eq(plain.reminders, nil, "a plain pick has no reminders")

  -- the headless commands, end to end
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, errs = {}, {}
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end
  local function remind_of(r)
    return vim.tbl_filter(function(l)
      return l:find("^remind: ") ~= nil
    end, vim.split(r.out, "\n", { plain = true }))
  end
  local vault_arg = "--vault=" .. root
  local r = run({ "next", vault_arg, "--today=2026-01-19" })
  eq(r.code, 0, r.err)
  eq(#remind_of(r), 0, "`next` judges the reminders by --today: none yet")
  r = run({ "next", vault_arg, "--today=2026-02-01" })
  eq(r.code, 0, r.err)
  local printed = remind_of(r)
  eq(#printed, 2)
  has(printed[1], "remind: lib.nvim/beta\t")
  has(printed[2], "1 finished task(s) with a reminder due (`list --done --reminders`)")
  -- ... and the pointer is right: that command lists the finished one
  r = run({ "list", "--done", "--reminders", vault_arg, "--today=2026-02-01" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/old-done")
  -- the JSON form has no reminders; it is the contract
  r = run({ "next", "--format=json", vault_arg, "--today=2026-02-01" })
  eq(r.code, 0, r.err)
  eq(vim.json.decode(r.out).reminders, nil)
  -- a --today that is no date is a usage error, not a quiet "everything is due"
  for _, bad in ipairs({ "zzz", "2099", "2026-2-1" }) do
    r = run({ "next", vault_arg, "--today=" .. bad })
    eq(r.code, 2, "--today=" .. bad)
    has(r.err, "--today must be YYYY-MM-DD")
  end
  r = run({ "next", "--format=json", vault_arg, "--today=zzz" })
  eq(r.code, 2, "the JSON form refuses it too")
  -- `done` does not print them (only `next` lists reminders)
  local root2 = fixture.build(H)
  r = run({ "done", "lib.nvim/alpha", "--vault=" .. root2, "--today=2026-02-01" })
  eq(r.code, 0, r.err)
  lacks(r.out, "remind: ", "`done` prints no reminder lines")
end
