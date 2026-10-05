---@module 'tasks_nvim.ui.confirm'
---@brief Confirm dialog for `:Tasks`' destructive confirmations.
---@description
--- ui.kit.confirm (ui.nvim) -- the same themed dialog every other
--- interactive prompt in this ecosystem uses (gopath.nvim, fileops.nvim,
--- filetree.nvim, ...) -- instead of a hand-rolled `getcharstr()`-driven
--- y/n reader printed via `print()`, which read on screen like a plain text
--- notification rather than an actual prompt. Falls back to `vim.ui.select`
--- when `ui.nvim` isn't installed, so this never hard-depends on it.
---
--- Async by nature (`ui.kit.confirm` is callback-based, not blocking):
--- `cb(accepted)` is called exactly once, never synchronously before this
--- function returns. Callers that used to write
--- `if not confirm.yesno(msg) then return end` need the rest of their logic
--- moved into `cb`.

local M = {}

---`s` cut to `max` characters with an ellipsis. A dialog line wider than the editor pushes the buttons out of
---the window (the kit centres them on the widest line), so a task title goes through this first.
---@param s string
---@param max integer
---@return string
function M.shorten(s, max)
  if vim.fn.strchars(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max - 1) .. "…"
end

---@param msg string
---@param yes_label string|nil e.g. "delete" — shown as "Yes, delete"
---@param cb fun(accepted: boolean)
function M.yesno(msg, yes_label, cb)
  local yes = yes_label and ("Yes, " .. yes_label) or "Yes"
  local kit = require("tasks_nvim.soft").require("ui.kit", { "confirm" })
  if kit then
    kit.confirm({
      question = msg,
      -- "No" first: the dialog starts on the first choice, and `<CR>` must not be the destructive one.
      choices = { "No", yes },
      on_answer = function(choice)
        cb(choice == yes)
      end,
    })
    return
  end
  vim.ui.select({ "No", yes }, { prompt = msg }, function(choice)
    cb(choice == yes)
  end)
end

---A question with several answers. The FIRST choice is the one the dialog starts on, so it must be the harmless one.
---`cb` gets the chosen index (1-based) or `nil` when the dialog was dismissed; it is called once, never before this
---function returns.
---@param msg string
---@param choices string[]
---@param cb fun(index: integer|nil)
function M.choose(msg, choices, cb)
  local function index_of(choice)
    for i, c in ipairs(choices) do
      if c == choice then
        return i
      end
    end
    return nil
  end
  local kit = require("tasks_nvim.soft").require("ui.kit", { "confirm" })
  if kit then
    kit.confirm({
      question = msg,
      choices = choices,
      on_answer = function(choice)
        cb(index_of(choice))
      end,
    })
    return
  end
  vim.ui.select(choices, { prompt = msg }, function(choice)
    cb(index_of(choice))
  end)
end

return M
