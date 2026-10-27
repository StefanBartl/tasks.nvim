---@module 'tasks_nvim.ui.confirm'
---@brief Confirm dialog for `:Tasks`' destructive confirmations.
---@description
--- Thin adapter over `lib.nvim.ui.dialog`, the one wrapper every plugin shares: the themed ui.kit dialog
--- (keyboard and mouse buttons, wrapped question) when ui.nvim or the kit copy of lib.nvim is there, a native
--- `vim.ui.select` otherwise. An older lib.nvim without that module takes the `vim.ui.select` path below, so
--- this never hard-depends on it.
---
--- Async by nature: `cb(accepted)` is called exactly once, never synchronously before this function returns.
--- Callers that used to write `if not confirm.yesno(msg) then return end` need the rest of their logic moved
--- into `cb`.

local M = {}

---`s` cut to `max` characters with an ellipsis, for a line of a list or a button label. A question needs no
---cutting: the dialog wraps it.
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
---@param yes_label string|nil e.g. "delete" -- shown as "Yes, delete"
---@param cb fun(accepted: boolean)
function M.yesno(msg, yes_label, cb)
  local yes = yes_label and ("Yes, " .. yes_label) or "Yes"
  local dialog = require("tasks_nvim.soft").require("lib.nvim.ui.dialog", { "confirm" })
  if dialog then
    dialog.confirm({
      question = msg,
      choices = { yes, "No" },
      -- "No" starts focused: `<CR>` must not be the destructive answer.
      default = 2,
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
  local dialog = require("tasks_nvim.soft").require("lib.nvim.ui.dialog", { "choose" })
  if dialog then
    dialog.choose(msg, choices, 1, function(index)
      cb(index > 0 and index or nil)
    end)
    return
  end
  vim.ui.select(choices, { prompt = msg }, function(choice)
    for i, c in ipairs(choices) do
      if c == choice then
        return cb(i)
      end
    end
    cb(nil)
  end)
end

return M
