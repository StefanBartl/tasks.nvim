---@module 'tasks_nvim.ui.view'
---@brief Render a task list as Markdown/CSV and deliver it to a buffer, file, clipboard or quickfix.
---@description
--- The output half of `:Tasks list`: takes the (already filtered and
--- sorted) `Tasks.Task[]` from the engine and turns it into text with
--- `lib.nvim.harvest.render`, then hands it to the sink the user named with
--- `--to=` through `lib.nvim.harvest` (`buffer`, `clipboard`, `file:<path>`,
--- `echo`), `lib.nvim.ui.list` (`qf`) or `tasks_preview` (`mdview`: a temp
--- file previewed in the browser).
---
--- Key responsibilities:
---  - `parse_target`: validate a `--to=` token before anything is rendered
---  - `render`: the table (Markdown, with a heading) or the CSV (more columns)
---  - `deliver`: one entry point for every target, returning `ok, err`
---
--- Not its job: finding or filtering tasks (`tasks.*`), parsing the command
--- line (`tasks_routes`), or deciding what happens without `--to`
--- (`tasks_cmd`, which owns the dashboard hook).

local harvest = require("lib.nvim.harvest")
local render = require("lib.nvim.harvest.render")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")

local M = {}

---@alias Tasks.Format "md"|"csv"

---The targets `--to=` accepts, for completion.
---@type string[]
M.TARGETS = { "buffer", "clipboard", "qf", "file:", "echo", "mdview" }

local EN_DASH = "–"

---@class Tasks.Column
---@field header string
---@field get fun(t: Tasks.Task): any
---@field csv_only? boolean   # Left out of the Markdown table (too wide to read).

---@param value any
---@param empty string
---@return string
local function or_empty(value, empty)
  if value == nil or value == "" then
    return empty
  end
  return tostring(value)
end

---@type Tasks.Column[]
local COLUMNS = {
  {
    header = "Task",
    get = function(t)
      return t.id
    end,
  },
  {
    header = "Status",
    get = function(t)
      return t.status
    end,
  },
  {
    header = "Prio",
    get = function(t)
      return t.prio
    end,
  },
  {
    header = "Effort",
    get = function(t)
      return t.effort
    end,
  },
  {
    header = "Kind",
    get = function(t)
      return t.kind
    end,
  },
  {
    header = "Updated",
    get = function(t)
      return t.updated or t.created
    end,
  },
  {
    header = "Title",
    get = function(t)
      return t.title
    end,
  },
  {
    header = "Tags",
    csv_only = true,
    get = function(t)
      return table.concat(t.tags, ";")
    end,
  },
  {
    header = "Blocked by",
    csv_only = true,
    get = function(t)
      return table.concat(t.blocked_by, ";")
    end,
  },
  {
    header = "Summary",
    csv_only = true,
    get = function(t)
      return t.summary
    end,
  },
  {
    header = "Path",
    csv_only = true,
    get = function(t)
      return t.path
    end,
  },
  {
    -- Last, so a script that reads the CSV by position keeps working.
    header = "Severity",
    csv_only = true,
    get = function(t)
      return t.severity
    end,
  },
  {
    -- Appended after Severity, never inserted: the columns before keep their position.
    header = "Value",
    csv_only = true,
    get = function(t)
      return t.value and tostring(t.value) or ""
    end,
  },
  {
    header = "ROI",
    csv_only = true,
    get = function(t)
      local roi = model.roi(t)
      return roi and ("%.2f"):format(roi) or ""
    end,
  },
  {
    header = "Actor",
    csv_only = true,
    get = function(t)
      return model.actor(t) or ""
    end,
  },
}

---Where `:Tasks list --to=` puts the tasks: `kind` is `buffer`, `clipboard`, `qf`, `file`, `echo` or `mdview`; `path` only for `file`.
---@class Tasks.Target
---@field kind string
---@field path? string

---Split a `--to=` token into `{ kind, path }` and reject what no sink knows.
---@param to string|nil  nil means "no target given"
---@return Tasks.Target|nil target
---@return string|nil err
function M.parse_target(to)
  if to == nil then
    return nil, nil
  end
  local path = to:match("^file:(.*)$")
  if path then
    if path == "" then
      return nil, "--to=file: needs a path (--to=file:<path>)"
    end
    return { kind = "file", path = path }, nil
  end
  if to == "buffer" or to == "clipboard" or to == "qf" or to == "echo" or to == "mdview" then
    return { kind = to }, nil
  end
  return nil, ("unknown --to target '%s' (expected %s)"):format(to, table.concat(M.TARGETS, ", "))
end

---The format a file target implies when `--format` is not given: `.csv` -> csv.
---@param target Tasks.Target|nil
---@param format string|nil
---@return Tasks.Format
function M.resolve_format(target, format)
  if format == "csv" or format == "md" then
    return format
  end
  if target and target.kind == "file" and target.path and target.path:lower():match("%.csv$") then
    return "csv"
  end
  return "md"
end

---What makes a spreadsheet (Excel, LibreOffice, Sheets) read a CSV cell as a formula.
---@type table<string, true>
local FORMULA_LEAD =
  { ["="] = true, ["+"] = true, ["-"] = true, ["@"] = true, ["\t"] = true, ["\r"] = true }

---A task title is whatever a file says (a Claude session, a `git pull` from elsewhere): a cell
---that starts like a formula, `=HYPERLINK(...)` say, would run when the CSV is opened. The
---usual defence is a leading `'`, which a spreadsheet shows as text.
---@param s string
---@return string
local function csv_safe(s)
  if FORMULA_LEAD[s:sub(1, 1)] then
    return "'" .. s
  end
  return s
end

---@param tasks Tasks.Task[]
---@param format Tasks.Format
---@return string[] headers
---@return string[][] rows
local function matrix(tasks, format)
  local headers, cols = {}, {}
  for _, col in ipairs(COLUMNS) do
    if format == "csv" or not col.csv_only then
      headers[#headers + 1] = col.header
      cols[#cols + 1] = col
    end
  end
  local csv = format == "csv"
  local rows = {}
  for i, t in ipairs(tasks) do
    local row = {}
    for c, col in ipairs(cols) do
      local cell = or_empty(col.get(t), csv and "" or EN_DASH)
      -- `id` and `path` come from file names: control characters (ESC, OSC, C1) never reach an export. The
      -- other cells are already clean, and a leading tab there is what `csv_safe` defuses.
      if col.header == "Task" or col.header == "Path" then
        cell = fsio.clean(cell)
      end
      row[c] = csv and csv_safe(cell) or cell
    end
    rows[i] = row
  end
  return headers, rows
end

---@class Tasks.RenderOpts
---@field format? Tasks.Format   # Default `md`.
---@field heading? string                    # Markdown only: the `#` line above the table.
---@field note? string                       # Markdown only: a line under the heading (the active filter).

---Render tasks as text. Markdown gets a heading and a GFM table; CSV gets one
---header line and one line per task with the extra columns.
---@param tasks Tasks.Task[]
---@param opts? Tasks.RenderOpts
---@return string text
function M.render(tasks, opts)
  opts = opts or {}
  local format = opts.format or "md"
  local headers, rows = matrix(tasks, format)
  if format == "csv" then
    return render.csv(headers, rows) .. "\n"
  end
  local parts = {}
  if opts.heading and opts.heading ~= "" then
    parts[#parts + 1] = "# " .. opts.heading
    parts[#parts + 1] = ""
  end
  if opts.note and opts.note ~= "" then
    parts[#parts + 1] = opts.note
    parts[#parts + 1] = ""
  end
  parts[#parts + 1] = render.markdown_table(headers, rows)
  return table.concat(parts, "\n") .. "\n"
end

---Quickfix entries, one per task, each jumping to line 1 of the task file.
---@param tasks Tasks.Task[]
---@return table[] items
function M.qf_items(tasks)
  local items = {}
  for i, t in ipairs(tasks) do
    items[i] = {
      filename = t.path,
      lnum = 1,
      col = 1,
      text = ("%s  P%s  %s  %s"):format(t.status or "?", t.prio or "-", t.id, t.title),
    }
  end
  return items
end

---Why a delivery to `target` must not happen: a `file:<path>` target that already exists is never
---overwritten without the user saying so (a mistyped path used to replace a task file or a note with the table,
---with no question and no checkpoint). Resolves the path like the file sink does (`~`, environment variables).
---@param target Tasks.Target|nil
---@param force? boolean
---@return string|nil blocked  the sentence to show, `nil` when the delivery may go ahead
function M.overwrite_guard(target, force)
  if force or not target or target.kind ~= "file" or not target.path then
    return nil
  end
  local ok, resolved = pcall(function()
    return vim.fs.normalize(require("lib.nvim.cross.fs.expand_path")(target.path))
  end)
  if not ok then
    return nil
  end
  if (vim.uv or vim.loop).fs_stat(resolved) then
    return ("%s already exists"):format(resolved)
  end
  return nil
end

---@class Tasks.DeliverOpts : Tasks.RenderOpts
---@field force? boolean       # Overwrite an existing `file:` target.
---@field title? string        # Buffer name / quickfix title.
---@field filetype? string     # Scratch buffer filetype (default: `markdown`, `csv` for csv).

---Deliver tasks to a target. `target == nil` means the default, a scratch
---buffer. Returns `ok, err`; the caller reports.
---@param tasks Tasks.Task[]
---@param target Tasks.Target|nil
---@param opts? Tasks.DeliverOpts
---@return boolean ok
---@return string|nil err
function M.deliver(tasks, target, opts)
  opts = opts or {}
  local kind = target and target.kind or "buffer"

  local blocked = M.overwrite_guard(target, opts.force)
  if blocked then
    return false, blocked .. " (pass --force to overwrite it)"
  end

  if kind == "qf" then
    local list = require("lib.nvim.ui.list")
    list.qf(M.qf_items(tasks), opts.title or "tasks")
    return true, nil
  end

  local format = M.resolve_format(target, opts.format)
  if kind == "mdview" then
    -- A browser preview renders Markdown; CSV would show as one paragraph.
    if format == "csv" then
      return false, "--to=mdview previews Markdown; drop --format=csv"
    end
    local text = M.render(tasks, {
      format = "md",
      heading = opts.heading,
      note = opts.note,
    })
    -- The temp file is named after the last part of the title (`.../tasks/<area>`).
    local ok, err = require("tasks_nvim.ui.preview").open_text(
      text,
      opts.title and opts.title:match("([^/]+)$") or nil
    )
    return ok, err
  end
  local text = M.render(tasks, {
    format = format,
    heading = opts.heading,
    note = opts.note,
  })
  local emit_opts = {
    title = opts.title,
    filetype = opts.filetype or (format == "csv" and "csv" or "markdown"),
    split = "split",
    path = target and target.path or nil,
  }
  return harvest.emit(text, kind, emit_opts)
end

return M
