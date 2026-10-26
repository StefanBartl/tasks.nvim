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

---The one-line hint at the top of the form, from the keys in force (a key set to `false` is left out).
---@param keys table<string, string|false>
---@return string
function M.key_hint(keys)
  local ticks = {}
  for _, name in ipairs({ "tick_space", "tick_enter" }) do
    if keys[name] then
      ticks[#ticks + 1] = keys[name]
    end
  end
  local parts = {}
  if #ticks > 0 then
    parts[#parts + 1] = table.concat(ticks, "/") .. " tick"
  end
  for _, item in ipairs({ { "submit", "submit" }, { "cancel", "cancel" }, { "help", "help" } }) do
    if keys[item[1]] then
      parts[#parts + 1] = keys[item[1]] .. " " .. item[2]
    end
  end
  return "<!-- " .. table.concat(parts, ", ") .. " -->"
end

---The help text, from the keys in force (`setup({ keys = { form = ... } })`); a key set to `false` is listed as "-".
---@param keys? table<string, string|false>  # Default: the configured form keys.
---@return string[]
function M.help_lines(keys)
  keys = keys or require("tasks_nvim.config").get().keys.form
  local function key(name)
    return keys[name] or "-"
  end
  return {
    "Task form",
    "",
    ("%s / %s   tick or untick the bullet under the cursor"):format(
      key("tick_space"),
      key("tick_enter")
    ),
    "                 (one-choice lists keep a single tick, category takes several)",
    ("%s            submit (checked, then created)"):format(key("submit")),
    ("%s / %s        cancel -- nothing is created (asks first when you typed something)"):format(
      key("cancel"),
      key("cancel_ctrl")
    ),
    ("%s               this help"):format(key("help")),
    "",
    "Area and Title are required. Tags, Refs and Links are comma separated;",
    "Links takes web addresses (http:// or https://), Refs paths and commits.",
    "Area may name several areas (a, b): one task is created in each.",
    "Summary is the one line that ends up in the index.",
    "Kontext / Akzeptanz / Notizen at the end are free text (an Akzeptanz line without",
    "a checkbox becomes `- [ ] line`); a section left empty keeps the template's hint.",
    "Lines starting with ! are error reports; they vanish on the next submit.",
    "",
    "q / <Esc> closes this help; so does leaving its window.",
  }
end

---The help of the form as a float that takes the focus and stays until it is closed (`q`, `<Esc>`) or left
---(`WinLeave`): there is no timeout, the text is read at the reader's pace.
---@param lines? string[]  # Default: `M.help_lines()`.
---@return integer win
---@return integer buf
function M.show_help(lines)
  lines = lines or M.help_lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(10, vim.o.columns - 6))
  local height = math.min(#lines, math.max(3, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width + 2,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Task form help ",
    title_pos = "center",
    zindex = 250,
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      -- scheduled: a window cannot be closed from inside the event that is leaving it
      vim.schedule(close)
    end,
  })
  return win, buf
end

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
  local cascade = require("tasks_nvim.soft").require("cascade", { "toggle_checkbox" })
  if cascade then
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
---@param root? string  the vault folder, named when the vault has no areas
---@param lang? "de"|"en"  headings of the body sections
---@return Tasks.FormValues|nil
function M.read(buf, areas, root, lang)
  local lines = form.strip_errors(buf_lines(buf))
  set_lines(buf, lines)
  local values, errors = form.validate(form.parse(lines), areas, root, lang)
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
  -- `current`: the form took over a window that was there before; the buffer goes, the window stays.
  local keep_window = vim.b[buf].tasks_form_mode == "current"
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if not keep_window and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Window modes of the form: a centered float (default), a split below, a vertical split, or the current window.
---@alias Tasks.FormMode "float"|"split"|"vsplit"|"current"
M.MODES = { "float", "split", "vsplit", "current" }

---Make the window for the form and leave the new, empty buffer in it.
---@param mode Tasks.FormMode
---@return integer buf
---@return Tasks.FormMode mode  # The mode that was used (`current` becomes `split` when the window cannot be taken).
local function open_window(mode)
  if mode == "float" then
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.min(100, math.max(30, vim.o.columns - 8))
    local height = math.min(48, math.max(10, vim.o.lines - 6))
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      border = "rounded",
      title = " New task ",
      title_pos = "center",
    })
    return buf, mode
  end
  if mode == "current" then
    -- `enew` fails (E37) when the window holds a modified buffer that may not be hidden: take a split then, the
    -- person's text is not touched
    local ok = pcall(vim.cmd, "enew")
    if ok then
      return vim.api.nvim_get_current_buf(), mode
    end
    mode = "split"
  end
  vim.cmd(({ split = "botright new", vsplit = "botright vnew" })[mode])
  return vim.api.nvim_get_current_buf(), mode
end

---@class Tasks.FormOpenOpts
---@field areas? string[]
---@field root? string  # The vault folder: named in the message that says the vault has no areas.
---@field area? string
---@field title? string
---@field summary? string
---@field tags? string
---@field refs? string
---@field links? string  # Web addresses, comma separated.
---@field lang? "de"|"en"  # Headings of the body sections (default `de`).
---@field mode? Tasks.FormMode  # Default: `setup({ form = { mode } })`, `float`.
---@field ticks? table<string, string|string[]>
---@field on_submit fun(values: Tasks.FormValues, buf: integer)
---@field on_cancel? fun()

---Open the form.
---@param opts Tasks.FormOpenOpts
---@return integer buf
function M.open(opts)
  local form_keys = require("tasks_nvim.config").get().keys.form
  local mode = opts.mode or require("tasks_nvim.config").get().form.mode
  if not vim.tbl_contains(M.MODES, mode) then
    -- `:Tasks new mode=floot` must not end in an error from the window code: say so and use the configured one
    require("lib.nvim.notify")
      .create("[tasks]")
      .warn(("unknown form mode '%s' (expected %s)"):format(tostring(mode), table.concat(M.MODES, ", ")))
    mode = require("tasks_nvim.config").get().form.mode
  end
  local buf
  buf, mode = open_window(mode)
  vim.b[buf].tasks_form_mode = mode
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "markdown"
  -- A second form must still get a name: the first one may be open.
  if not pcall(vim.api.nvim_buf_set_name, buf, "tasks://task-new") then
    pcall(vim.api.nvim_buf_set_name, buf, ("tasks://task-new/%d"):format(buf))
  end
  set_lines(
    buf,
    form.template({
      area = opts.area,
      title = opts.title,
      summary = opts.summary,
      lang = opts.lang,
      areas = opts.areas,
      tags = opts.tags,
      refs = opts.refs,
      links = opts.links,
      ticks = opts.ticks,
      hint = M.key_hint(form_keys),
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
  -- Keys from `setup({ keys = { form = ... } })`; `false` leaves an action unbound.
  local keys = require("tasks_nvim.config").get().keys.form
  ---@param modes string|string[]
  ---@param name string
  ---@param fn function
  ---@param desc string
  local function bind(modes, name, fn, desc)
    local lhs = keys[name]
    if lhs then
      map(modes, lhs, fn, desc)
    end
  end
  if keys.tick_space then
    map("n", keys.tick_space, toggle_or(keys.tick_space), "Task form: tick/untick")
  end
  if keys.tick_enter then
    map("n", keys.tick_enter, toggle_or(keys.tick_enter), "Task form: tick/untick")
  end
  local function submit()
    vim.cmd("stopinsert")
    local values = M.read(buf, opts.areas, opts.root, opts.lang)
    if values then
      opts.on_submit(values, buf)
    end
  end
  bind({ "n", "i" }, "submit", submit, "Task form: submit")
  local function leave()
    M.close(buf)
    if opts.on_cancel then
      opts.on_cancel()
    end
  end
  -- A form with typed text is not thrown away by one `q`: it asks first (the buffer is marked unmodified
  -- when the template is set, so `modified` means the user changed something).
  local function cancel()
    if not (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified) then
      leave()
      return
    end
    require("tasks_nvim.ui.confirm").yesno(
      "Discard what you typed in the task form?",
      "discard",
      function(yes)
        if yes then
          leave()
        end
      end
    )
  end
  bind("n", "cancel", cancel, "Task form: cancel")
  bind({ "n", "i" }, "cancel_ctrl", cancel, "Task form: cancel")
  bind("n", "help", function()
    M.show_help()
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

return M
