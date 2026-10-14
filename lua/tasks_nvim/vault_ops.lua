---@module 'tasks_nvim.vault_ops'
---@brief What `:TasksVault` does with the vault itself: where a part of an area is, which area a path belongs to,
---@brief a note in the Backlog, a new vault. No notifications, no windows.
---@description
--- The editor command (`tasks_nvim.ui.vault_cmd`) asks this module for paths and for the few writes it
--- makes; the same functions can serve a script.
---
--- Key responsibilities:
---  - `PARTS` / `part_dir` / `part_entry`: the folder of an area a command points at
---    (`backlog`, `features`, `tasks`, `roadmap`, `all`) and the file that opens first
---  - `area_of_path` / `area_of_buffer`: the area a file belongs to (inside the vault, or
---    the folder name of the repository the file sits in)
---  - `link_target`: a path as a Markdown link target relative to the file it is pasted into
---  - `new_note`: a dated note in `Backlog/FEATURES` or `Backlog/TASKS`, with its README row
---  - `scaffold_area` / `create_vault`: the folders of an area, and a vault folder with areas
---
--- Not its job: prompts, pickers, the clipboard (`ui/vault_cmd`).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---The parts of an area a command can point at, relative to the area folder.
---@type table<string, string>
M.PARTS = {
  backlog = "Backlog",
  features = "Backlog/FEATURES",
  tasks = "Backlog/TASKS",
  roadmap = "ROADMAP",
  all = "",
}

---The words of `M.PARTS`, in the order a completion shows them.
---@type string[]
M.PART_NAMES = { "backlog", "features", "tasks", "roadmap", "all" }

---The default part: the Backlog is what the command is named for.
M.DEFAULT_PART = "backlog"

---The part of a note kind: `feature` notes go to `FEATURES`, `task` notes to `TASKS`.
---@type table<string, Tasks.Bucket>
M.NOTE_BUCKETS = { feature = "FEATURES", task = "TASKS" }

---Whether `word` names a part.
---@param word any
---@return boolean
function M.is_part(word)
  return type(word) == "string" and M.PARTS[word] ~= nil
end

---The folder of `part` in `area`.
---@param root string
---@param area string
---@param part? string  one of `PART_NAMES`; default `backlog`
---@return string|nil dir
---@return string|nil err
function M.part_dir(root, area, part)
  part = part or M.DEFAULT_PART
  local sub = M.PARTS[part]
  if sub == nil then
    return nil, ("unknown part '%s' (expected %s)"):format(part, table.concat(M.PART_NAMES, "|"))
  end
  return root .. "/" .. area .. (sub ~= "" and ("/" .. sub) or ""), nil
end

---The file that stands for a part: the index of the Backlog (`README.md`), the roadmap of the area, else the
---generated index. The other parts (`features`, `tasks`, `all`) are folders and have no such file: the folder is
---the answer (the README lists both buckets, so it is not the index of one of them).
---@param root string
---@param area string
---@param part? string
---@return string|nil path   a file that exists
function M.part_entry(root, area, part)
  part = part or M.DEFAULT_PART
  local candidates = {}
  if part == "backlog" then
    candidates = { vault.backlog_readme(root, area) }
  elseif part == "roadmap" then
    candidates = {
      root .. "/" .. area .. "/ROADMAP/ROADMAP.md",
      vault.index_path(root, area),
    }
  end
  for _, candidate in ipairs(candidates) do
    if fsio.is_file(candidate) then
      return candidate
    end
  end
  return nil
end

---The area a file or folder belongs to: the first segment below the vault root when it is an area of
---the vault; else the name of the repository folder the path sits in (a `.git` entry on the way up) when
---the vault has an area of that name (`E:/repos/lib.nvim/lua/x.lua` -> `lib.nvim`).
---@param root string
---@param path string
---@return string|nil area
function M.area_of_path(root, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local p = fsio.norm(vim.fn.fnamemodify(path, ":p"))
  if fsio.is_inside(root, p) and p ~= root then
    local first = p:sub(#root + 2):match("^([^/]+)")
    if first and vault.has_area(root, first) then
      return first
    end
  end
  local dir = p
  if not fsio.is_dir(dir) then
    dir = fsio.norm(vim.fn.fnamemodify(p, ":h"))
  end
  local found = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  if found then
    local name = vim.fs.basename(vim.fs.dirname(found))
    -- the repository folder is the exact spelling of the area (a worktree folder fits no area and finds none)
    if vault.has_area(root, name) then
      return name
    end
  end
  return nil
end

---The area of the current buffer, or nil.
---@param root string
---@param bufnr? integer
---@return string|nil area
function M.area_of_buffer(root, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then
    name = vim.fn.getcwd()
  end
  return M.area_of_path(root, name)
end

---Resolve what the user typed as an area: the exact name, else the only area that is `<typed>.nvim` or that
---starts with it (case-insensitive). Several candidates are no answer.
---@param names string[]  the areas of the vault
---@param typed string
---@return string|nil area
---@return string[]|nil candidates  set when the word is ambiguous
function M.match_area(names, typed)
  if vim.tbl_contains(names, typed) then
    return typed, nil
  end
  local low = typed:lower()
  for _, name in ipairs(names) do
    if name:lower() == low or name:lower() == low .. ".nvim" then
      return name, nil
    end
  end
  local starts = {}
  for _, name in ipairs(names) do
    if name:lower():sub(1, #low) == low then
      starts[#starts + 1] = name
    end
  end
  if #starts == 1 then
    return starts[1], nil
  elseif #starts > 1 then
    return nil, starts
  end
  return nil, nil
end

---`path` as written from the folder of `from_file` (forward slashes, `./` not added, `..` where needed). The
---two have no common root (another drive): the absolute path.
---@param from_file string  the file the link is written into; "" or nil for no file (the working directory)
---@param path string
---@return string
function M.relative_to(from_file, path)
  local base
  if type(from_file) == "string" and from_file ~= "" then
    base = fsio.norm(vim.fn.fnamemodify(from_file, ":p:h"))
  else
    base = fsio.norm(vim.fn.getcwd())
  end
  local target = fsio.norm(path)
  local function segments(p)
    local out = {}
    for seg in p:gmatch("[^/]+") do
      out[#out + 1] = seg
    end
    return out
  end
  local a, b = segments(base), segments(target)
  local case_blind = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
  local function same(x, y)
    if case_blind then
      return x:lower() == y:lower()
    end
    return x == y
  end
  local n = 0
  while n < #a and n < #b and same(a[n + 1], b[n + 1]) do
    n = n + 1
  end
  if n == 0 then
    return target
  end
  local out = {}
  for _ = n + 1, #a do
    out[#out + 1] = ".."
  end
  for i = n + 1, #b do
    out[#out + 1] = b[i]
  end
  if #out == 0 then
    return "."
  end
  return table.concat(out, "/")
end

---A Markdown link to `path`: `[<label>](<target>)`; a target with spaces or parentheses is wrapped in `<...>`.
---@param label string
---@param target string
---@return string
function M.markdown_link(label, target)
  if target:find("[%s()]") then
    target = "<" .. target .. ">"
  end
  return ("[%s](%s)"):format(label, target)
end

---The text of a new note.
---@param kind "feature"|"task"
---@param title string
---@param date string
---@return string
local function note_text(kind, title, date)
  return ("# %s\n\n_%s, %s_\n\n"):format(title, kind, date)
end

---Create a dated note in `<area>/Backlog/FEATURES` or `Backlog/TASKS` and add its row to the README of the
---Backlog (created when missing). An existing file of that name is never overwritten.
---@param root string
---@param area string
---@param kind "feature"|"task"
---@param title string
---@param opts? { date?: string }
---@return { path: string, bucket: string, file: string, readme: "updated"|"unchanged"|"created" }|nil result
---@return string|nil err
function M.new_note(root, area, kind, title, opts)
  local bucket = M.NOTE_BUCKETS[kind]
  if not bucket then
    return nil, ("unknown note kind '%s' (expected feature|task)"):format(tostring(kind))
  end
  if not vault.has_area(root, area) then
    return nil, vault.not_an_area_message(area, vault.area_names(root))
  end
  title = vim.trim(type(title) == "string" and title or "")
  if title == "" then
    return nil, "a note needs a title"
  end
  local mutate = require("tasks_nvim.mutate")
  local date = opts and opts.date or os.date("%Y-%m-%d")
  local slug = mutate.slugify(title)
  local file = ("%s_%s.md"):format(date, slug)
  local dir = vault.backlog_dir(root, area, bucket)
  local path = dir .. "/" .. file
  if fsio.is_file(path) then
    return nil, ("%s/Backlog/%s/%s exists already"):format(area, bucket, file)
  end
  local ok, werr = fsio.write_atomic(path, note_text(kind, title, date))
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(werr)
  end

  local readme = vault.backlog_readme(root, area)
  local state = "updated"
  if not fsio.is_file(readme) then
    local head = ("# %s -- Backlog\n\nFinished work of this area.\n"):format(area)
    local wrote, rerr = fsio.write_atomic(readme, head)
    if not wrote then
      return nil, "note written, but the README could not be created: " .. tostring(rerr)
    end
    state = "created"
  end
  local row = mutate.readme_row(bucket, file, { title = title, summary = "" }, date)
  local res, err = mutate.readme_update(readme, bucket, file, row)
  if not res then
    return nil, "note written, but its README row was not: " .. tostring(err)
  end
  if state ~= "created" then
    state = res.state
  end
  return { path = path, bucket = bucket, file = file, readme = state }, nil
end

---Make the folders an area is made of: `ROADMAP/tasks`, `Backlog/FEATURES`, `Backlog/TASKS`. Existing
---folders and files are left alone.
---@param root string
---@param area string
---@return string[]|nil created  the folders that were made (relative to the vault)
---@return string|nil err
function M.scaffold_area(root, area)
  if not vault.valid_area(area) or vault.SKIP[area] then
    return nil, "invalid area name: " .. tostring(area)
  end
  local created = {}
  for _, sub in ipairs({ "ROADMAP/tasks", "Backlog/FEATURES", "Backlog/TASKS" }) do
    local dir = root .. "/" .. area .. "/" .. sub
    if not fsio.is_dir(dir) then
      local ok, err = fsio.mkdirp(dir)
      if not ok then
        return created, ("cannot create %s: %s"):format(dir, tostring(err))
      end
      created[#created + 1] = area .. "/" .. sub
    end
  end
  return created, nil
end

---The README a new vault gets.
local VAULT_README = [[
# Task vault

One folder per project (an "area"). Each area has:

- `ROADMAP/tasks/<slug>.md` -- one Markdown file per open task
- `ROADMAP/TASKS.md` -- generated overview, never edited by hand
- `Backlog/FEATURES`, `Backlog/TASKS` -- finished work, with an index in `Backlog/README.md`

Managed by tasks.nvim: `:Tasks new <area> <title>`, `:Tasks done <id>`, `:TasksVault open <area>`.
]]

---Whether `dir` may become a vault with `areas`, before anything is made. The folder is normalised to an
---absolute, forward-slash path. A drive or filesystem root, a file and an unusable area name are refused.
---@param dir string
---@param areas? string[]
---@return string|nil root
---@return string|nil err
function M.check_vault_target(dir, areas)
  if type(dir) ~= "string" or vim.trim(dir) == "" then
    return nil, "a vault needs a folder"
  end
  local root = fsio.norm(vim.fn.fnamemodify(dir, ":p"))
  if root:match("^%a:/?$") or root == "/" then
    return nil, "refusing to use a drive or filesystem root as a vault: " .. root
  end
  if fsio.is_file(root) then
    return nil, root .. " is a file"
  end
  for _, area in ipairs(areas or {}) do
    if
      not vault.valid_area(area)
      or vault.SKIP[area]
      or area:match("^[._]")
      or vault.is_reserved_name(area)
    then
      return nil, "invalid area name: " .. tostring(area)
    end
  end
  return root, nil
end

---Create a vault folder (and its parents) with the given areas. An existing folder is fine, an existing area
---too; nothing is overwritten. The folder may become a repository later, that is the user's decision.
---@param dir string  the vault folder
---@param areas? string[]
---@return { root: string, existed: boolean, created: string[] }|nil result
---@return string|nil err
function M.create_vault(dir, areas)
  local root, check_err = M.check_vault_target(dir, areas)
  if not root then
    return nil, check_err
  end
  local existed = fsio.is_dir(root)
  if not existed then
    local ok, err = fsio.mkdirp(root)
    if not ok then
      return nil, ("cannot create %s: %s"):format(root, tostring(err))
    end
  end
  local created = {}
  local readme = root .. "/README.md"
  if not fsio.is_file(readme) then
    local ok, err = fsio.write_atomic(readme, VAULT_README)
    if not ok then
      return nil, ("cannot write %s: %s"):format(readme, tostring(err))
    end
    created[#created + 1] = "README.md"
  end
  for _, area in ipairs(areas or {}) do
    -- scaffold_area hands back the folders made so far together with the error, so the error is what counts
    local made, err = M.scaffold_area(root, area)
    if err then
      return nil, err
    end
    vim.list_extend(created, made)
  end
  return { root = root, existed = existed, created = created }, nil
end

return M
