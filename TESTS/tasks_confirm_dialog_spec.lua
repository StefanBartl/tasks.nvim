-- TESTS/tasks_confirm_dialog_spec.lua -- `tasks_nvim.ui.confirm` asks through `lib.nvim.ui.dialog`: the harmless
-- answer starts focused, the callback runs once, a dismissed dialog is `false` / `nil`, a dialog that raises or is not
-- there falls back to `vim.ui.select`, and an unprompted question goes through `ask`.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces `lib.nvim.ui.dialog`, `require` and `vim.ui.select` with test doubles on purpose.

return function(H)
  local eq, ok = H.eq, H.ok
  local confirm = require("tasks_nvim.ui.confirm")
  local dialog = require("lib.nvim.ui.dialog")

  local real_require = require
  local orig = {
    confirm = dialog.confirm,
    choose = dialog.choose,
    ask = dialog.ask,
    select = vim.ui.select,
    backend = dialog.backend,
    load_errors = dialog.load_errors,
  }
  local function restore()
    dialog.confirm, dialog.choose, dialog.ask, vim.ui.select =
      orig.confirm, orig.choose, orig.ask, orig.select
    dialog.backend, dialog.load_errors = orig.backend, orig.load_errors
    package.loaded["lib.nvim.ui.dialog"] = dialog
    _G.require = real_require
  end

  --- Run `f` with `require("lib.nvim.ui.dialog")` failing as it does on a lib.nvim that predates it.
  local function without_dialog(f)
    package.loaded["lib.nvim.ui.dialog"] = nil
    _G.require = function(name)
      if name == "lib.nvim.ui.dialog" then
        error("module '" .. name .. "' not found")
      end
      return real_require(name)
    end
    local called, err = pcall(f)
    _G.require = real_require
    package.loaded["lib.nvim.ui.dialog"] = dialog
    assert(called, err)
  end

  local good, failure = pcall(function()
    -- yesno: "No" is the first button and the default, only "Yes, <label>" accepts; N and Y are keys
    local seen
    dialog.confirm = function(opts)
      seen = opts
    end
    local answers = {}
    local function push(yes)
      answers[#answers + 1] = yes
    end
    confirm.yesno("Delete it?", "delete", push)
    eq(seen.question, "Delete it?", "the question is passed on unshortened")
    eq(seen.choices, "&No\n&Yes, delete", "the harmless one first, with letter keys")
    eq(seen.default, 1, "No starts focused: <CR> is never the destructive answer")
    seen.on_answer("Yes, delete", 2)
    eq(answers, { true }, "the yes label accepts")
    confirm.yesno("Delete it?", nil, push)
    seen.on_answer("No", 1)
    eq(answers, { true, false }, "No refuses")
    confirm.yesno("Delete it?", "delete", push)
    seen.on_answer(nil)
    eq(answers[3], false, "a dismissed dialog refuses")
    confirm.yesno("Save A & B?", "save & go", push)
    eq(seen.choices, "&No\n&Yes, save && go", "an ampersand in the label is a literal one")
    seen.on_answer("Yes, save & go", 2)
    eq(answers[4], true, "and the label comes back without the marks")

    -- an unprompted question (a file watcher) goes through ask, a prompted one through confirm
    local via
    dialog.confirm = function()
      via = "confirm"
    end
    dialog.ask = function(opts)
      via = "ask"
      seen = opts
    end
    confirm.yesno("All ticked?", "finish", push, { unprompted = true })
    eq(
      via,
      "ask",
      "unprompted -> dialog.ask (waits behind an open dialog, ignores typed-ahead keys)"
    )
    confirm.yesno("Delete?", "delete", push)
    eq(via, "confirm", "prompted -> dialog.confirm")

    -- choose: 1-based index, nil when dismissed (index 0 of the dialog or nothing at all)
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
    got.cb(1)
    eq(idx, { 2 }, "the callback runs once")
    confirm.choose("Which?", { "Not now", "Open" }, function(i)
      idx[#idx + 1] = i == nil and "nil" or i
    end)
    got.cb(0)
    confirm.choose("Which?", { "Not now", "Open" }, function(i)
      idx[#idx + 1] = i == nil and "nil" or i
    end)
    got.cb(nil)
    eq(idx, { 2, "nil", "nil" }, "0 and nil (dismissed) become nil")

    -- a dialog that raises: the question is asked natively, once
    dialog.confirm = function()
      error("kit broke")
    end
    local prompts, res = {}, {}
    vim.ui.select = function(items, o, on_choice)
      prompts[#prompts + 1] = { items = items, prompt = o.prompt }
      on_choice(items[#items], #items)
    end
    confirm.yesno("Really?", "go", function(yes)
      res[#res + 1] = yes
    end)
    eq(res, { true }, "a dialog that raises does not cost the question: asked natively")
    eq(prompts[1].items, { "No", "Yes, go" }, "the harmless answer is listed first")
    -- ... but not twice when it raised after answering
    dialog.confirm = function(o)
      o.on_answer("Yes, go", 2)
      error("late")
    end
    prompts, res = {}, {}
    confirm.yesno("Really?", "go", function(yes)
      res[#res + 1] = yes
    end)
    eq(res, { true }, "answered once")
    eq(#prompts, 0, "and not asked again natively")

    -- an older lib.nvim without the dialog module: vim.ui.select, cut to the screen, the index of the provider
    prompts, res = {}, {}
    without_dialog(function()
      local many = {}
      for i = 1, 40 do
        many[i] = "line " .. i
      end
      confirm.yesno(string.rep("x", 300) .. "\n" .. table.concat(many, "\n"), "go", function(yes)
        res[#res + 1] = yes
      end)
      -- two equal labels: the provider's index decides
      vim.ui.select = function(items, _, on_choice)
        on_choice(items[1], 2)
      end
      confirm.choose("Pick", { "same", "same" }, function(i)
        res[#res + 1] = i
      end)
    end)
    local first_line = prompts[1].prompt:match("^[^\n]*")
    ok(
      vim.fn.strdisplaywidth(first_line) <= math.max(40, vim.o.columns - 12),
      "the native prompt is cut to the screen"
    )
    ok(#vim.split(prompts[1].prompt, "\n") <= 13, "and to a dozen lines")
    eq(res, { true, 2 }, "fallback answers; the provider's index wins over the label")

    -- shorten: display columns, and a NUL byte does not raise
    eq(confirm.shorten("short", 10), "short", "short stays")
    eq(vim.fn.strdisplaywidth(confirm.shorten(string.rep("x", 400), 70)), 70, "cut to the columns")
    ok(pcall(confirm.shorten, "a\0b", 10), "a NUL byte does not raise")

    -- health names the dialog backend and what failed to load
    local lines = {}
    local function note(kind)
      return function(msg)
        lines[#lines + 1] = kind .. ": " .. msg
      end
    end
    local real_health = vim.health
    vim.health = {
      start = note("start"),
      ok = note("ok"),
      warn = note("warn"),
      error = note("error"),
      info = note("info"),
    }
    local checked, check_err = pcall(function()
      dialog.backend = function()
        return "lib.nvim.ui.kit"
      end
      dialog.load_errors = function()
        return { ["ui.kit"] = "syntax error" }
      end
      require("tasks_nvim.health").check()
    end)
    dialog.backend, dialog.load_errors = orig.backend, orig.load_errors
    vim.health = real_health
    assert(checked, check_err)
    local joined = table.concat(lines, "\n")
    ok(joined:find("dialog of lib.nvim.ui.kit", 1, true), "health names the backend")
    ok(
      joined:find("ui.kit is installed but failed to load: syntax error", 1, true),
      "and a broken kit"
    )
  end)
  restore()
  assert(good, failure)
end
