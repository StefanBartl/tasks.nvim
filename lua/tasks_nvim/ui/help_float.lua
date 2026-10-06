---@module 'tasks_nvim.ui.help_float'
---@brief A key-help float for the pickers of `:Tasks` (tasks dashboard, sync triage list).
---@description
--- The float is opened WITHOUT taking the focus: the picker keeps it, so the list stays alive
--- behind the help. Any key closes it again, and that key is discarded -- otherwise it would also
--- run in the picker (`s` would skip a row, `x` fails with E21 in the read-only list). `vim.on_key`
--- sees keys after mapping expansion: of a mapping whose right-hand side is plain keys only the
--- first one is discarded (Lua-function and `<Cmd>` mappings are discarded as a unit).

local M = {}

---Open the help float over the editor; the next key closes it and is swallowed.
---@param lines string[]
---@param ns_name string  Name of the `vim.on_key` namespace (one per caller, so two helps do not share a hook).
---@return integer win
---@return integer buf
function M.open(lines, ns_name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  -- Never larger than the editor: a help wider or taller than the screen was cut off and could not scroll.
  width = math.min(width, math.max(10, vim.o.columns - 6))
  -- Rows, not lines: a line wider than the window wraps, and the float cannot scroll (the picker keeps the focus).
  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.min(rows, math.max(3, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width + 2,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 250,
  })
  local ns = vim.api.nvim_create_namespace(ns_name)
  vim.on_key(function()
    vim.on_key(nil, ns)
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)
    -- an empty string discards the key (see the module description for its limit)
    return ""
  end, ns)
  return win, buf
end

return M
