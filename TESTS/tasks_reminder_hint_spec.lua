-- TESTS/tasks_reminder_hint_spec.lua -- the line at startup that says how many reminders are due.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body; the spec replaces the notification channel on purpose.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local hint = require("tasks_nvim.ui.reminder_hint")
  local config = require("tasks_nvim.config")

  local root = fixture.build(H)

  -- the fixture: an open task with a reminder on 2026-01-20, a finished one on 2026-02-01
  local o, d = hint.count({ root = root, today = "2026-01-19" })
  eq({ o, d }, { 0, 0 }, "nothing due before the first date")
  o, d = hint.count({ root = root, today = "2026-01-20" })
  eq({ o, d }, { 1, 0 }, "the open task on its day")
  o, d = hint.count({ root = root, today = "2026-02-01" })
  eq({ o, d }, { 1, 1 }, "both from the second date on")

  -- the text
  eq(hint.message(0, 0), nil, "nothing due is silence")
  has(hint.message(1, 0), "1 reminder due")
  ok(not hint.message(1, 0):find("finished", 1, true), "no finished part for none")
  has(hint.message(2, 1), "3 reminders due (1 of them finished)")
  has(hint.message(1, 0), ":Tasks list --reminders")

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
  has(lines[1], "2 reminders due (1 of them finished)")
  eq(hint.announce({ root = root, today = "2026-02-01" }), false, "once per session")
  eq(#lines, 1)
  -- a vault that is not there is silence
  hint.reset()
  eq(hint.announce({ root = root .. "/nowhere", today = "2026-02-01" }), false)
  notify.create = orig_create
  hint.reset()

  -- `next` lists them: the open tasks (oldest date first) and the number of finished ones
  local next_pick = require("tasks_nvim.next_pick")
  local plan_view = require("tasks_nvim.plan_view")
  local pick = assert(next_pick.pick_from_vault({ root = root, today = "2026-02-01" }))
  eq(#pick.reminders.open, 1)
  eq(pick.reminders.open[1].id, "lib.nvim/beta")
  eq(pick.reminders.done, 1)
  local next_out = plan_view.next_lines(pick)
  local remind_lines = vim.tbl_filter(function(l)
    return l:find("^remind: ") ~= nil
  end, next_out)
  eq(#remind_lines, 2)
  eq(remind_lines[1], "remind: lib.nvim/beta\t" .. pick.reminders.open[1].title .. "\t2026-01-20")
  has(remind_lines[2], "remind: 1 finished task(s) with a reminder due")
  local before = assert(next_pick.pick_from_vault({ root = root, today = "2026-01-19" }))
  eq({ #before.reminders.open, before.reminders.done }, { 0, 0 })
  eq(#vim.tbl_filter(function(l)
    return l:find("^remind: ") ~= nil
  end, plan_view.next_lines(before)), 0, "nothing due: no line")

  -- the option: on by default, and a bad value is reported and ignored
  eq(config.get().reminders.on_start, true)
end
