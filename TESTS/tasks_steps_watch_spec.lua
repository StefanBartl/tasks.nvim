-- TESTS/tasks_steps_watch_spec.lua -- the opt-in question "all steps ticked -- finish the task?" in a task buffer.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace
-- module functions with test doubles on purpose.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")
  local confirm = require("tasks_nvim.ui.confirm")
  local watch = require("tasks_nvim.ui.steps_watch")
  local config = require("tasks_nvim.config")

  local root = F.vault(H)
  vault.set_root(root)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local orig_yesno, orig_notify = confirm.yesno, vim.notify
  local asked = {}
  local answer = true
  confirm.yesno = function(msg, _, cb)
    asked[#asked + 1] = msg
    cb(answer)
  end
  vim.notify = function() end
  local function cleanup()
    confirm.yesno = orig_yesno
    vim.notify = orig_notify
    watch.disable()
    config.merge({ steps = { ask_finish = false } })
    vault.set_root(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  local good, failure = pcall(function()
    local task = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Watched" })))
    H.write(
      task.path,
      H.read(task.path) .. "\n## Plan\n\n- [ ] 1. one\n- [ ] 2. two\n- [ ] 3. gone (dropped)\n"
    )

    vim.cmd("edit " .. vim.fn.fnameescape(task.path))
    local buf = vim.api.nvim_get_current_buf()
    eq(watch.task_id(buf), task.id, "a task file of the vault is recognised")
    eq(watch.task_id(vim.api.nvim_create_buf(false, true)), nil, "a scratch buffer is not")
    watch.prime(buf)

    ---@param n integer
    ---@param text string
    local function set_step(n, text)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local seen = 0
      for i, line in ipairs(lines) do
        if line:match("^%- %[.%] %d%.") then
          seen = seen + 1
          if seen == n then
            lines[i] = (line:gsub("^%- %[.%]", "- [" .. text .. "]"))
          end
        end
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    -- one of two ticked: nothing to ask
    set_step(1, "x")
    eq(watch.check_buffer(buf), false)
    eq(#asked, 0)
    -- the last one ticked (the dropped step does not count): the question
    set_step(2, "x")
    answer = false
    eq(watch.check_buffer(buf), true)
    eq(#asked, 1)
    has(asked[1], "All steps of " .. task.id .. " are ticked")
    ok(scan.find(task.id, { root = root }) ~= nil, "no is no: the task stays open")
    -- looked at again while still complete: no second question
    eq(watch.check_buffer(buf), false)
    eq(#asked, 1)
    -- un-tick and tick again: asks again
    set_step(2, " ")
    eq(watch.check_buffer(buf), false)
    set_step(2, "x")
    answer = true
    eq(watch.check_buffer(buf), true)
    eq(#asked, 2)
    ok(
      scan.find(task.id, { root = root }) == nil,
      "yes finished the task (the buffer was saved first)"
    )
    local finished = assert(scan.find_done(task.id, { root = root }))
    has(H.read(finished.path), "- [x] 2. two", "the unsaved tick is in the finished copy")
    has(H.read(finished.path), "- [ ] 3. gone (dropped)", "a dropped step stays open")

    -- a plan that was complete when the buffer was opened: no question until something changes
    local done_already =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Already" })))
    H.write(done_already.path, H.read(done_already.path) .. "\n## Plan\n\n- [x] 1. done\n")
    vim.cmd("edit " .. vim.fn.fnameescape(done_already.path))
    local buf2 = vim.api.nvim_get_current_buf()
    eq(watch.check_buffer(buf2), false, "first look at a complete plan: not a transition")
    eq(#asked, 2)

    -- a task without steps never asks
    local plain =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain one" })))
    vim.cmd("edit " .. vim.fn.fnameescape(plain.path))
    eq(watch.check_buffer(vim.api.nvim_get_current_buf()), false)

    -- enable / disable: the autocommands exist only while enabled
    local function groups()
      local ok_get, found = pcall(vim.api.nvim_get_autocmds, { group = "TasksStepsWatch" })
      return ok_get and #found or 0
    end
    eq(groups(), 0, "off by default: no autocommand at all")
    watch.enable()
    watch.enable()
    ok(groups() >= 3, "enable registers them (twice is the same set)")
    local before = groups()
    watch.enable()
    eq(groups(), before)
    watch.disable()
    eq(groups(), 0)
    eq(config.get().steps.ask_finish, false, "the option is off by default")
    require("tasks_nvim").setup({ steps = { ask_finish = true } })
    vim.wait(50, function()
      return groups() > 0
    end)
    ok(groups() > 0, "setup({ steps = { ask_finish = true } }) turns it on")
  end)
  cleanup()
  if not good then
    error(failure, 0)
  end
end
