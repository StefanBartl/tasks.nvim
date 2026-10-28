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

local nul_safe = require("lib.lua.strings.core").nul_safe
local truncate = require("lib.lua.strings.width").truncate

local M = {}

---`s` cut to `max` display columns with an ellipsis, for a line of a list or a button label. A question needs no
---cutting: the dialog wraps it. A NUL byte (a title read from a file) is made safe first.
---@param s string
---@param max integer
---@return string
function M.shorten(s, max)
  return (truncate(nul_safe(s), max, { ellipsis = "…" }))
end

---Every line of `s` cut to the screen and at most a dozen lines: for the `vim.ui.select` fallback of a lib.nvim
---without `ui.dialog`, which neither wraps nor scrolls (lib.nvim's own native path does this itself).
---@param s string
---@return string
local function native_text(s)
  local out = {}
  for i, line in ipairs(vim.split(nul_safe(s), "\n", { plain = true })) do
    if i > 12 then
      out[#out + 1] = "…"
      break
    end
    out[#out + 1] = M.shorten(line, math.max(40, vim.o.columns - 12))
  end
  return table.concat(out, "\n")
end

---@param msg string
---@param yes_label string|nil e.g. "delete" -- shown as "Yes, delete"
---@param cb fun(accepted: boolean)
---@param opts? { unprompted?: boolean }  # `unprompted`: the question was not asked for (a file watcher): see `ask`
function M.yesno(msg, yes_label, cb, opts)
  local yes = yes_label and ("Yes, " .. yes_label) or "Yes"
  local answered = false
  local function answer(accepted)
    if answered then
      return
    end
    answered = true
    cb(accepted)
  end
  -- the shared recipe: "No" first and focused, N and Y as keys, `ask` for a question nobody asked for
  local dialog = require("tasks_nvim.soft").require("lib.nvim.ui.dialog", { "yesno" })
  if dialog then
    local shown = pcall(dialog.yesno, msg, yes_label, answer, opts)
    if shown or answered then
      return
    end
  end
  vim.ui.select(
    { "No", yes },
    { prompt = native_text(msg) },
    function(choice) -- native-prompt: lib.nvim without ui.dialog (soft dependency)
      answer(choice == yes)
    end
  )
end

---A question with several answers. The FIRST choice is the one the dialog starts on, so it must be the harmless one.
---`cb` gets the chosen index (1-based) or `nil` when the dialog was dismissed; it is called once, never before this
---function returns. A choice that is a single digit is the key of its own button.
---@param msg string
---@param choices string[]
---@param cb fun(index: integer|nil)
function M.choose(msg, choices, cb)
  local answered = false
  local function answer(index)
    if answered then
      return
    end
    answered = true
    cb(index)
  end
  local dialog = require("tasks_nvim.soft").require("lib.nvim.ui.dialog", { "choose" })
  if dialog then
    local ok = pcall(dialog.choose, msg, choices, 1, function(index)
      answer(type(index) == "number" and index > 0 and index or nil)
    end)
    if ok or answered then
      return
    end
  end
  vim.ui.select(choices, { prompt = native_text(msg) }, function(choice, index)
    if index == nil then
      for i, c in ipairs(choices) do
        if c == choice then
          index = i
          break
        end
      end
    end
    answer(index)
  end)
end

return M
