-- TESTS/tasks_confirm_dialog_spec.lua -- `tasks_nvim.ui.confirm` asks through `lib.nvim.ui.dialog`: the harmless
-- answer starts focused, the callback runs once, a dismissed dialog is `false` / `nil`, and an older lib.nvim
-- without the dialog module falls back to `vim.ui.select`.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces `lib.nvim.ui.dialog` and `vim.ui.select` with test doubles on purpose.

return function(H)
  local eq, ok = H.eq, H.ok
  local confirm = require("tasks_nvim.ui.confirm")
  local dialog = require("lib.nvim.ui.dialog")

  local real_require = require
  local orig_confirm, orig_choose, orig_select = dialog.confirm, dialog.choose, vim.ui.select
  local function restore()
    dialog.confirm, dialog.choose, vim.ui.select = orig_confirm, orig_choose, orig_select
    package.loaded["lib.nvim.ui.dialog"] = dialog
    _G.require = real_require
  end

  local good, failure = pcall(function()
    -- yesno: "No" is the default button, only "Yes, <label>" accepts
    local seen
    dialog.confirm = function(opts)
      seen = opts
    end
    local answers = {}
    confirm.yesno("Delete it?", "delete", function(yes)
      answers[#answers + 1] = yes
    end)
    eq(seen.question, "Delete it?", "the question is passed on unshortened")
    eq(seen.choices, { "No", "Yes, delete" }, "the labels, the harmless one first")
    eq(seen.default, 1, "No starts focused: <CR> is never the destructive answer")
    seen.on_answer("Yes, delete", 2)
    eq(answers, { true }, "the yes label accepts")
    confirm.yesno("Delete it?", nil, function(yes)
      answers[#answers + 1] = yes
    end)
    seen.on_answer("No", 1)
    eq(answers, { true, false }, "No refuses")
    confirm.yesno("Delete it?", "delete", function(yes)
      answers[#answers + 1] = yes
    end)
    seen.on_answer(false)
    eq(answers[3], false, "a dismissed dialog refuses")

    -- choose: 1-based index, nil when dismissed (index 0 of the dialog)
    local got
    dialog.choose = function(msg, choices, default, cb)
      got = { msg = msg, choices = choices, default = default, cb = cb }
    end
    local idx = {}
    confirm.choose("Which?", { "Not now", "Open" }, function(i)
      idx[#idx + 1] = i == nil and "nil" or i
    end)
    eq(got.default, 1, "the first (harmless) choice starts focused")
    got.cb(2)
    got.cb(0)
    got.cb(nil)
    eq(idx, { 2, "nil", "nil" }, "the callback is the dialog's: 0 and nil become nil")

    -- an older lib.nvim without the dialog module: vim.ui.select
    package.loaded["lib.nvim.ui.dialog"] = nil
    local hide = true
    _G.require = function(name)
      if hide and name == "lib.nvim.ui.dialog" then
        error("module '" .. name .. "' not found")
      end
      return real_require(name)
    end
    local prompts = {}
    vim.ui.select = function(items, o, on_choice)
      prompts[#prompts + 1] = { items = items, prompt = o.prompt }
      on_choice(items[#items])
    end
    local res = {}
    local long = string.rep("x", 300)
    local ok_call, err = pcall(function()
      confirm.yesno(long, "go", function(yes)
        res[#res + 1] = yes
      end)
      confirm.choose("Pick", { "a", "b" }, function(i)
        res[#res + 1] = i
      end)
    end)
    hide = false
    _G.require = real_require
    assert(ok_call, err)
    eq(prompts[1].items, { "No", "Yes, go" }, "fallback lists the harmless answer first")
    eq(res, { true, 2 }, "fallback answers")
    ok(vim.fn.strchars(prompts[1].prompt) <= 100, "the native prompt does not wrap: it is cut")
  end)
  restore()
  assert(good, failure)
end
