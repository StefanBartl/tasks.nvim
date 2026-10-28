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
--- **Group symbols** are written as a wikilink, `[[group/<name>]]` (decision `tasks.nvim/gruppensymbole-format-entscheiden`),
--- and resolve to the file that explains the group, `ALL/groups/<name>.md` in a vault. Only the wikilink counts:
--- `group/perf` without the brackets is read as a task id like any other. A group is made by creating its file;
--- `groups()` lists them for other plugins (completion, pickers).
---
--- Not its job: opening anything, prompts, pickers, notifications. UI-free like the rest of the engine.

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---One place a token resolves to.
---@class Tasks.ResolveTarget
---@field kind "task"|"done"|"group"  # an open task in `ROADMAP/tasks`, a finished one in `Backlog/`, or a group's explanation
---@field id string           # `<area>/<slug>`, or `group/<name>`
---@field path string         # the task file, forward slashes; absolute when the vault was given absolute
---@field line integer        # 1-based line to land on (the first line of the file)
---@field title string        # the frontmatter title, or the slug
---@field root string         # the vault the target is in
---@field date? string        # `done`: the day it was finished (`YYYY-MM-DD`), when its name says so

---Options of `resolve` and `resolve_at`.
---@class Tasks.ResolveOpts
---@field roots? string[]  # Vaults to look in, in order (the same vault named twice is asked once). Absent, empty, or no list at all (a single string): the configured vault (`setup`, `$TASKS_VAULT`). A list: only these -- an entry that is no directory is skipped, and a list of only such entries answers nothing (no fallback).

---Characters a run of path-like text is made of: what an area, a slug and the `/` between them can hold.
local RUN = "[%w_.%-/]"

---Where a vault explains its groups, relative to the vault root.
M.GROUPS_DIR = "ALL/groups"

---What a group name may be: starts with a letter or digit, then letters, digits, `_`, `.`, `-`.
local GROUP_NAME = "^[%w][%w_.%-]*$"

---@param name any
---@return boolean
local function is_group_name(name)
  return type(name) == "string" and #name <= 128 and name:match(GROUP_NAME) ~= nil
end

---A group symbol around the run `s..e` of `line`: `[[group/<name>]]`, also with a heading (`#h`) or an alias
---(`|Text`) as any wikilink may have, as the token with its brackets and where it starts and ends; nil when the run
---is not exactly that. The cursor counts on the name only, as for a task wikilink: the run never holds `[`, `#`, `|`.
---@param line string
---@param s integer
---@param e integer
---@return string|nil token
---@return integer|nil s
---@return integer|nil e
local function group_token(line, s, e)
  if s < 3 or line:sub(s - 2, s - 1) ~= "[[" then
    return nil
  end
  if not is_group_name(line:sub(s, e):match("^group/(.+)$")) then
    return nil
  end
  local rest = line:sub(e + 1)
  local skip = rest:match("^#[^%]|]*()")
  local offset = skip and (skip - 1) or 0
  local tail = rest:sub(offset + 1)
  local after = tail:match("^%]%]()") or tail:match("^|[^%]]*%]%]()")
  if not after then
    return nil
  end
  local stop = e + offset + after - 1
  return line:sub(s - 2, stop), s - 2, stop
end

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
  local group, gs, ge = group_token(line, s, e)
  if group then
    return group, gs, ge
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

---Title and line of a group file: the frontmatter `title`, else the first `# ` heading (and its line), else the name.
---@param path string
---@param name string
---@return string title
---@return integer line
local function group_head(path, name)
  local text = fsio.read(path)
  local parsed = text and require("lib.nvim.markdown.frontmatter").parse(text)
  if not parsed then
    return name, 1
  end
  local title = parsed.has_block and parsed.meta.title or nil
  if type(title) ~= "string" or not title:match("%S") then
    title = nil
  end
  -- The body is the tail of the text: the lines before it are the frontmatter block (and nothing without one).
  local before = select(2, text:sub(1, #text - #parsed.body):gsub("\n", ""))
  local n = 0
  for raw in (fsio.lf(parsed.body) .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if raw:match("^#%s+%S") then
      return title or fsio.trim((raw:gsub("^#%s+", ""))), before + n
    end
  end
  return title or name, 1
end

---The group files of `root`, by name: `<name>.md` in `GROUPS_DIR`, a valid name, a file (a dead link or a folder
---named so is none), the folder not leaving the vault (as `plans` reads its folder).
---@param root string
---@return string[] names
local function group_names(root)
  local dir = root .. "/" .. M.GROUPS_DIR
  local names = {}
  if not fsio.is_dir(dir) or vault.leaves(root, dir) then
    return names
  end
  for entry, kind in vim.fs.dir(dir) do
    local name = entry:match("^(.+)%.md$")
    if
      (kind == "file" or kind == "link")
      and is_group_name(name)
      and fsio.is_file(dir .. "/" .. entry)
    then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---The groups of every vault asked, by name within each vault.
---@param opts? Tasks.ResolveOpts
---@return { name: string, path: string, title: string, line: integer, root: string }[]
function M.groups(opts)
  local out = {}
  for _, root in ipairs(roots_of(opts)) do
    for _, name in ipairs(group_names(root)) do
      local path = root .. "/" .. M.GROUPS_DIR .. "/" .. name .. ".md"
      local title, line = group_head(path, name)
      out[#out + 1] = { name = name, path = path, title = title, line = line, root = root }
    end
  end
  return out
end

---@param name string
---@param opts? Tasks.ResolveOpts
---@return Tasks.ResolveTarget[]
local function resolve_group(name, opts)
  local out = {}
  if not is_group_name(name) then
    return out
  end
  for _, root in ipairs(roots_of(opts)) do
    -- Spelled exactly, like an area (`has_area`): `PERF` must not find `perf.md` on Windows only.
    if vim.list_contains(group_names(root), name) then
      local path = root .. "/" .. M.GROUPS_DIR .. "/" .. name .. ".md"
      local title, line = group_head(path, name)
      out[#out + 1] = {
        kind = "group",
        id = "group/" .. name,
        path = path,
        line = line,
        title = title,
        root = root,
      }
    end
  end
  return out
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
  local group = token:match("^%[%[group/([^%]|#]+)[^%]]*%]%]$")
  if group then
    return resolve_group(group, opts)
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
      local model = require("tasks_nvim.model")
      for _, done in ipairs(scan.find_done_all(id, scan_opts)) do
        out[#out + 1] = {
          kind = "done",
          id = done.id,
          path = done.path,
          line = 1,
          title = done.title,
          root = root,
          date = model.done_date(done.path) or model.done_date(vim.fs.dirname(done.path)),
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
