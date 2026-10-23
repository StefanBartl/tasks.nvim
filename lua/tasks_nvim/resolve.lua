---@module 'tasks_nvim.resolve'
---@brief A task id in any text, resolved to where the task is: for other plugins (gopath.nvim, hover.nvim).
---@description
--- A task id (`<area>/<slug>`) is written in more places than the vault: a to-do list, a commit message, a handover,
--- a code comment. This module answers two questions about such text, and nothing else:
---
---  - `token_at(line, col)`: is there an id at this column, and which?
---  - `resolve(token)`: where is that task? A list of targets (file, line, kind, title), empty when it names nothing.
---
--- `resolve_at(buf, row, col)` is the two together, for a caller holding a cursor.
---
--- **An id is only an id when the vault says so.** `lua/gopath` in `lua/gopath/init.lua` has the shape of
--- `<area>/<slug>` and is a path. So the text is read as the whole run of path characters around the cursor (a run
--- with a second `/` is a path, not an id), and a candidate only becomes a target when its area exists in a vault and
--- the task is there. Everything else is an empty list, never an error: a caller asks on every keypress it is given,
--- and "not a task" is the common answer.
---
--- **Every target, not the first.** The same id can name a task in two vaults (`opts.roots`), and an open task and a
--- finished one of the same slug can both exist after a reopen; the caller decides what to do with several.
---
--- Group symbols (a group named in text, resolved to where the group is explained) are planned and not here yet:
--- their written form is still to be decided.
---
--- Not its job: opening anything, prompts, pickers, notifications. UI-free like the rest of the engine.

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---One place a token resolves to.
---@class Tasks.ResolveTarget
---@field kind "task"|"done"  # an open task in `ROADMAP/tasks`, or a finished one in `Backlog/`
---@field id string           # `<area>/<slug>`
---@field path string         # the task file, forward slashes; absolute when the vault was given absolute
---@field line integer        # 1-based line to land on (the first line of the file)
---@field title string        # the frontmatter title, or the slug
---@field root string         # the vault the target is in

---Options of `resolve` and `resolve_at`.
---@class Tasks.ResolveOpts
---@field roots? string[]  # Vaults to look in, in order (the same vault named twice is asked once). Absent, empty, or no list at all (a single string): the configured vault (`setup`, `$TASKS_VAULT`). A list: only these -- an entry that is no directory is skipped, and a list of only such entries answers nothing (no fallback).

---Characters a run of path-like text is made of: what an area, a slug and the `/` between them can hold.
local RUN = "[%w_.%-/]"

---@param line string
---@param col integer 1-based
---@return integer|nil s
---@return integer|nil e
---The longest run that can still be an id, in bytes. An area and a slug are names, not paragraphs; a
---minified script or a base64 blob under the cursor is a run of megabytes, and walking it byte by byte
---under a hover's every pause would be felt.
local MAX_RUN = 256

local function run_around(line, col)
  if col < 1 or col > #line or not line:sub(col, col):match(RUN) then
    return nil, nil
  end
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match(RUN) do
    s = s - 1
    if e - s >= MAX_RUN then
      return nil, nil
    end
  end
  while e < #line and line:sub(e + 1, e + 1):match(RUN) do
    e = e + 1
    if e - s >= MAX_RUN then
      return nil, nil
    end
  end
  return s, e
end

---The task id at byte column `col` of `line`, as text: the id, and where it starts and ends (1-based, inclusive).
---
--- The id is the whole run of path characters around `col`, with trailing `.` and `_` taken off (the end of a
--- sentence, Markdown emphasis) and leading `_` too (`_lib.nvim/x_`), and only when it has the shape of
--- `<area>/<slug>` (`vault.parse_id`): one `/`, a valid area, a
--- kebab-case slug. A wikilink (`[[id]]`, `[[id|Text]]`) and backticks need nothing of their own: neither `[`, `|` nor
--- `` ` `` is part of the run. Whether the task exists is `resolve`'s question.
---@param line string
---@param col integer 1-based byte column
---@return string|nil id
---@return integer|nil s
---@return integer|nil e
function M.token_at(line, col)
  -- `col % 1 ~= 0`: a fraction is no column (`string.sub` would cut it and answer for one), and NaN
  -- and the infinities fail it too.
  if type(line) ~= "string" or type(col) ~= "number" or col % 1 ~= 0 then
    return nil
  end
  local s, e = run_around(line, col)
  if not s or not e then
    return nil
  end
  -- Trailing dots (the end of a sentence) and `_` on either side (`_lib.nvim/x_`, Markdown emphasis) are not part of
  -- an id: an area never starts with `.` or `_` that `is_area_dir` accepts, a slug never ends in either.
  while e > s and line:sub(e, e):match("[._]") do
    e = e - 1
  end
  while s < e and line:sub(s, s) == "_" do
    s = s + 1
  end
  if col > e or col < s then
    return nil
  end
  -- `parse_id` is the whole shape test: a second `/` (`lua/gopath/init.lua`) and a leading one (`/lib.nvim/x`, an
  -- absolute path) are both malformed ids there.
  local token = line:sub(s, e)
  local area, slug = vault.parse_id(token)
  if not area or not slug then
    return nil
  end
  return token, s, e
end

---@param opts? Tasks.ResolveOpts
---@return string[]
local function roots_of(opts)
  if type(opts) == "table" and type(opts.roots) == "table" and #opts.roots > 0 then
    local out = {}
    for _, r in ipairs(opts.roots) do
      if type(r) == "string" and r ~= "" then
        local root = vault.root({ root = r })
        -- The same vault named twice (or once as `C:/x` and once as `c:\x`) would answer every id twice.
        local seen = false
        for _, have in ipairs(out) do
          seen = seen or (root ~= nil and fsio.same_path(have, root))
        end
        if root and not seen then
          out[#out + 1] = root
        end
      end
    end
    return out
  end
  local root = vault.root()
  return root and { root } or {}
end

---Where the task `token` names is, in every vault asked: open tasks first, then finished ones, vault by vault.
---
--- `token` is an id (`<area>/<slug>`), also as a wikilink (`[[<area>/<slug>]]`, an alias or heading after it is
--- ignored). Anything else, and an id no vault knows, gives an empty list.
---
--- A slug finished more than once (finished, reopened, finished again) gives every finished file, the newest first. A
--- task that exists as a file and as a folder (a duplicate `check` reports) gives both, the file first: which one is
--- meant is for the person to see. Each call lists the area's two Backlog folders, a few milliseconds on a vault of
--- hundreds of tasks; a caller asking on every cursor pause may wrap it in `fsio.read_scope`.
---@param token string
---@param opts? Tasks.ResolveOpts
---@return Tasks.ResolveTarget[]
function M.resolve(token, opts)
  if type(token) ~= "string" then
    return {}
  end
  local id = token:match("^%[%[([^%]|#]+)[^%]]*%]%]$") or token
  local area, slug = vault.parse_id(id)
  if not area or not slug then
    return {}
  end
  local scan = require("tasks_nvim.scan")
  local out = {}
  for _, root in ipairs(roots_of(opts)) do
    -- Links between tasks are not this answer's business: a task whose frontmatter holds a bare `[[slug]]` would
    -- otherwise have the whole vault indexed to settle it, on every lookup outside a read scope (37-80 ms measured).
    local scan_opts = {
      root = root,
      link_resolver = {
        root = root,
        candidates = function()
          return {}
        end,
        path = function()
          return nil
        end,
      },
    }
    -- The area must be one of the vault's, spelled exactly (`has_area`): `find` checks that itself, `find_done`
    -- only that a folder of the name is listed, which a `_Archive/Backlog/` or a `TEMPLATES/Backlog/` would pass.
    if vault.has_area(root, area) then
      local open = scan.find(id, scan_opts)
      local opened = { open }
      if not open then
        -- A file and a folder of the same slug: `find` refuses to choose (`vault.resolve_task`), both are targets.
        local file, folder =
          vault.task_path(root, area, slug), vault.folder_task_path(root, area, slug)
        if fsio.is_file(file) and fsio.is_file(folder) then
          local model = require("tasks_nvim.model")
          opened = {
            model.from_file(
              file,
              { area = area, location = "roadmap", slug = slug, folder = false }
            ),
            model.from_file(
              folder,
              { area = area, location = "roadmap", slug = slug, folder = true }
            ),
          }
        end
      end
      for _, task in ipairs(opened) do
        out[#out + 1] = {
          kind = "task",
          id = task.id,
          path = task.path,
          line = 1,
          title = task.title,
          root = root,
        }
      end
      for _, done in ipairs(scan.find_done_all(id, scan_opts)) do
        out[#out + 1] = {
          kind = "done",
          id = done.id,
          path = done.path,
          line = 1,
          title = done.title,
          root = root,
        }
      end
    end
  end
  return out
end

---The task id at a buffer position, resolved: the targets, and the token they came from.
---@param buf? integer  0 or nil for the current buffer
---@param row integer   1-based line
---@param col integer   0-based byte column (as `nvim_win_get_cursor` gives it)
---@param opts? Tasks.ResolveOpts
---@return Tasks.ResolveTarget[] targets
---@return string|nil token
function M.resolve_at(buf, row, col, opts)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  -- A row below 1 would be a negative index to `nvim_buf_get_lines`, which counts from the end: `-1` is the LAST line.
  if
    type(buf) ~= "number"
    or type(row) ~= "number"
    or type(col) ~= "number"
    or row < 1
    or row % 1 ~= 0
    or not vim.api.nvim_buf_is_valid(buf)
  then
    return {}, nil
  end
  -- Past the last line: `nvim_buf_get_lines` would refuse a row too large for an integer (`1e300`).
  if row > vim.api.nvim_buf_line_count(buf) then
    return {}, nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line then
    return {}, nil
  end
  local token = M.token_at(line, col + 1)
  if not token then
    return {}, nil
  end
  return M.resolve(token, opts), token
end

return M
