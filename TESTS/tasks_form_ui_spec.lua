-- TESTS/tasks_form_ui_spec.lua -- the window of the `:Tasks new` form (float / split / vsplit / current), the
-- help that stays until it is closed, and the `form.mode` option.

return function(H)
  local eq, ok = H.eq, H.ok
  local config = require("tasks_nvim.config")
  local ui = require("tasks_nvim.ui.form")

  local function is_float(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end

  -- ── the option ─────────────────────────────────────────────────────────────
  eq(config.get().form.mode, "float", "the form is a float by default")
  eq(config.validate({ form = { mode = "vsplit" } }).form, { mode = "vsplit" })
  eq(config.validate({ form = { mode = "tab" } }).form, {}, "an unknown mode is dropped")

  -- ── each mode opens in its own kind of window and closes cleanly ───────────
  local function open(mode)
    return ui.open({ areas = { "a" }, mode = mode, on_submit = function() end })
  end

  local before = #vim.api.nvim_list_wins()
  local fb = open(nil)
  ok(is_float(vim.api.nvim_get_current_win()), "default: float")
  eq(vim.b[fb].tasks_form_mode, "float")
  ui.close(fb)
  eq(#vim.api.nvim_list_wins(), before, "closing the float leaves the windows as they were")

  local sb = open("split")
  local swin = vim.api.nvim_get_current_win()
  ok(not is_float(swin) and #vim.api.nvim_list_wins() == before + 1, "split: one more window")
  ui.close(sb)
  eq(#vim.api.nvim_list_wins(), before)

  local vb = open("vsplit")
  local vwin = vim.api.nvim_get_current_win()
  ok(not is_float(vwin) and #vim.api.nvim_list_wins() == before + 1, "vsplit: one more window")
  ok(vim.api.nvim_win_get_position(vwin)[2] > 0, "vsplit: beside, not below")
  ui.close(vb)
  eq(#vim.api.nvim_list_wins(), before)

  local origin = vim.api.nvim_get_current_win()
  local cb = open("current")
  eq(vim.api.nvim_get_current_win(), origin, "current: no new window")
  eq(vim.api.nvim_win_get_buf(origin), cb, "current: the form is in it")
  ui.close(cb)
  ok(vim.api.nvim_win_is_valid(origin), "current: the window stays when the form closes")
  eq(#vim.api.nvim_list_wins(), before)

  -- the configured mode is the default
  config.merge({ form = { mode = "split" } })
  local cfgb = ui.open({ areas = { "a" }, on_submit = function() end })
  eq(vim.b[cfgb].tasks_form_mode, "split")
  ui.close(cfgb)
  config.merge({})

  -- ── help: no timeout; q, <Esc> and leaving close it ────────────────────────
  local fbuf = open(nil)
  local formwin = vim.api.nvim_get_current_win()
  local hwin = ui.show_help({ "a help line", "another" })
  eq(vim.api.nvim_get_current_win(), hwin, "the help takes the focus")
  vim.wait(1200, function()
    return false
  end)
  ok(vim.api.nvim_win_is_valid(hwin), "the help is still there after a wait (no timeout)")
  vim.api.nvim_feedkeys(vim.keycode("q"), "x", false)
  ok(not vim.api.nvim_win_is_valid(hwin), "q closes it")

  local h2 = ui.show_help({ "x" })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  ok(not vim.api.nvim_win_is_valid(h2), "<Esc> closes it")

  local h3 = ui.show_help({ "x" })
  vim.api.nvim_set_current_win(formwin)
  vim.wait(500, function()
    return not vim.api.nvim_win_is_valid(h3)
  end)
  ok(not vim.api.nvim_win_is_valid(h3), "leaving the window closes it")
  ok(vim.api.nvim_win_is_valid(formwin), "the form itself stays")
  ui.close(fbuf)
end
