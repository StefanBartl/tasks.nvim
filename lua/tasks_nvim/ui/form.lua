---@module 'tasks_nvim.ui.form'
---@brief The buffer, keymaps and help of the `:Tasks new` form -- a thin UI over `tasks.form`.
---@description
--- Opens the form text (`tasks.form.template`) in a scratch Markdown buffer
--- and wires the keys. All rules (parsing, validation, the one-tick rule of a
--- single-choice list) are in `tasks.form`; creating the task is the caller's
--- job (`on_submit`), so a failure there leaves the form open with everything
--- typed.
---
--- Keys (buffer-local, listed by `g?`):
---  - `<Space>` / `<CR>` on a choice bullet: tick / untick it (cascade.nvim's
---    checkbox toggle when installed, an own flip otherwise)
---  - `<C-s>` (normal and insert): submit
---  - `q` (normal) / `<C-q>`: cancel, nothing is created
---  - `g?`: help
---
--- Not its job: the form rules (`tasks.form`), the engine call and the
--- follow-up questions (`tasks_cmd`).

local form = require("tasks_nvim.form")

local M = {}

local HELP = {
  "Task form",
  "",
  "<Space> / <CR>   tick or untick the bullet under the cursor",
  "                 (one-choice lists keep a single tick, category takes several)",
  "<C-s>            submit (checked, then created)",
  "q / <C-q>        cancel -- nothing is created",
  "g?               this help",
  "",
  "Area and Title are required. Tags and Refs are comma separated.",
  "Lines starting with ! are error reports; they vanish on the next submit.",
}

---Form text of a buffer.
---@param buf integer
---@return string[]
local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---Tick or untick the bullet under the cursor. cascade.nvim's checkbox toggle
---does the flip when it is installed (soft dependency); the result is then
---brought back to the form's rules, so the choice lists stay consistent either
---way. Without cascade, `form.toggle` does the same on its own.
---@param buf integer
---@return boolean handled  `false` when the cursor is not on a choice bullet
function M.toggle_here(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = buf_lines(buf)
  local wanted = form.toggle(lines, lnum)
  if not wanted then
    return false
  end
  local before = lines[lnum]
  local was_ticked = before:match("%[[xX]%]") ~= nil
  local done = false
  local ok, cascade = pcall(require, "cascade")
  if ok and type(cascade.toggle_checkbox) == "function" then
    -- Cascade may cycle through more states than ticked/unticked; only the
    -- unticked -> ticked flip is taken from it, the way back is ours.
    if not was_ticked then
      local worked = pcall(cascade.toggle_checkbox)
      local after = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
      if worked and after ~= before and after:match("^%s*[-*]%s+%[.%]") then
        local fixed = buf_lines(buf)
        fixed[lnum] = fixed[lnum]:gsub("^(%s*[-*]%s+)%[.%]", "%1[x]")
        set_lines(buf, form.normalize(fixed, lnum))
        done = true
      else
        -- cascade did nothing useful: undo whatever it did, use ours
        vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { before })
      end
    end
  end
  if not done then
    set_lines(buf, wanted)
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
end

---Show the error report at the top of the form, replacing an earlier one.
---@param buf integer
---@param errors string[]
function M.show_errors(buf, errors)
  local lines = form.strip_errors(buf_lines(buf))
  local report = form.error_lines(errors)
  vim.list_extend(report, lines)
  set_lines(buf, report)
  -- The window of the form, not "the current one": a failure of the engine is reported after the
  -- "attach assets?" question, when focus need not be back on the form.
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
end

---Parse and check the form of `buf`; errors are written into the buffer.
---@param buf integer
---@param areas string[]|nil
---@return Tasks.FormValues|nil
function M.read(buf, areas)
  local lines = form.strip_errors(buf_lines(buf))
  set_lines(buf, lines)
  local values, errors = form.validate(form.parse(lines), areas)
  if not values then
    M.show_errors(buf, errors)
    return nil
  end
  return values
end

---Close the form buffer (and its window when it is not the last one).
---@param buf integer
function M.close(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Open the form.
---@param opts { areas?: string[], area?: string, title?: string, tags?: string, ticks?: table<string, string|string[]>, on_submit: fun(values: Tasks.FormValues, buf: integer), on_cancel?: fun() }
---@return integer buf
function M.open(opts)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "myplugins://task-new")
  set_lines(
    buf,
    form.template({
      area = opts.area,
      title = opts.title,
      areas = opts.areas,
      tags = opts.tags,
      ticks = opts.ticks,
    })
  )
  vim.bo[buf].modified = false

  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  local function toggle_or(key)
    return function()
      if not M.toggle_here(buf) then
        vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
      end
    end
  end
  map("n", "<Space>", toggle_or("<Space>"), "Task form: tick/untick")
  map("n", "<CR>", toggle_or("<CR>"), "Task form: tick/untick")
  local function submit()
    vim.cmd("stopinsert")
    local values = M.read(buf, opts.areas)
    if values then
      opts.on_submit(values, buf)
    end
  end
  map({ "n", "i" }, "<C-s>", submit, "Task form: submit")
  local function cancel()
    M.close(buf)
    if opts.on_cancel then
      opts.on_cancel()
    end
  end
  map("n", "q", cancel, "Task form: cancel")
  map({ "n", "i" }, "<C-q>", cancel, "Task form: cancel")
  map("n", "g?", function()
    vim.notify(table.concat(HELP, "\n"), vim.log.levels.INFO, { title = "Task form" })
  end, "Task form: help")

  -- Start on the first free text line.
  local lines = buf_lines(buf)
  for i, l in ipairs(lines) do
    if l:match("^Area:%s*$") or l:match("^Title:%s*$") then
      vim.api.nvim_win_set_cursor(0, { i, #l })
      break
    end
  end
  return buf
end

M.HELP = HELP

return M
