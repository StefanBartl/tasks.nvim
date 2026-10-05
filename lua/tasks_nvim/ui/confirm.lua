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

---@param msg string
---@param yes_label string|nil e.g. "delete" — shown as "Yes, delete"
---@param cb fun(accepted: boolean)
function M.yesno(msg, yes_label, cb)
  local yes = yes_label and ("Yes, " .. yes_label) or "Yes"
  local ok_kit, kit = pcall(require, "ui.kit")
  if ok_kit and type(kit.confirm) == "function" then
    kit.confirm({
      question = msg,
      choices = { yes, "No" },
      on_answer = function(choice)
        cb(choice == yes)
      end,
    })
    return
  end
  vim.ui.select({ yes, "No" }, { prompt = msg }, function(choice)
    cb(choice == yes)
  end)
end

return M
