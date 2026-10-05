---@module 'tasks_nvim.vault'
---@brief Where the task vault is, which areas it has, and every path the task system uses.
---@description
--- The vault is a folder you name (`setup({ vault = ... })`, `$TASKS_VAULT` or `--vault`): one
--- folder per project ("area"), each with `ROADMAP/` (open) and `Backlog/` (done).
--- This module is the only place that knows that layout.
---
--- Key responsibilities:
---  - resolve the vault root (explicit option, `set_root`, `configure`, `$TASKS_VAULT`),
---    so a spec can point everything at a fixture; there is no built-in default path
---  - list the areas: every folder holding `ROADMAP/` or `Backlog/`, plus the
---    named extras; `_`-prefixed folders, `TEMPLATES` and `TOOLS` are skipped
---  - build the paths (`ROADMAP/tasks`, `ROADMAP/TASKS.md`, `Backlog/<bucket>`)
---  - validate area names, slugs and ids before they become part of a path
---
--- Not its job: reading task files (`scan`/`model`) or writing anything.

local fsio = require("tasks_nvim.fsio")

local uv = vim.uv or vim.loop

local M = {}

---Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`
---(set with `configure({ extra_areas = ... })`; empty by default).
---@type string[]
M.EXTRA_AREAS = {}

---Folders that are never areas.
---@type table<string, boolean>
M.SKIP = { TEMPLATES = true, TOOLS = true }

---`kind` -> where `done` moves the file (rule R6).
---@type table<string, Tasks.Bucket>
M.BUCKET_OF_KIND = {
  feature = "FEATURES",
  idea = "FEATURES",
  research = "FEATURES",
  task = "TASKS",
  bug = "TASKS",
}

---@type string|nil
local override_root

---@type string|nil
local configured_root

---Apply the user's options (called by `tasks_nvim.setup`). Only the keys that are present change anything.
---@param opts? { vault?: string, extra_areas?: string[] }
---@return nil
function M.configure(opts)
  opts = opts or {}
  if opts.vault ~= nil then
    configured_root = (type(opts.vault) == "string" and opts.vault ~= "") and fsio.norm(opts.vault)
      or nil
  end
  if type(opts.extra_areas) == "table" then
    M.EXTRA_AREAS = vim.deepcopy(opts.extra_areas)
  end
end

---The named extras: `configure({ extra_areas })` plus `$TASKS_EXTRA_AREAS` (comma separated; the
---headless CLI has no `setup`, so this is how it learns them).
---@return string[]
function M.extra_areas()
  local env = vim.env.TASKS_EXTRA_AREAS
  if not env or env == "" then
    return vim.list_extend({}, M.EXTRA_AREAS)
  end
  local out = vim.list_extend({}, M.EXTRA_AREAS)
  for name in env:gmatch("[^,]+") do
    out[#out + 1] = vim.trim(name)
  end
  return out
end

---Pin the vault root for this process (nil clears it). Used by specs.
---@param path string|nil
---@return nil
function M.set_root(path)
  override_root = path and fsio.norm(path) or nil
end

---Resolve the vault root. Order: `opts.root`, `set_root`, `configure`, `$TASKS_VAULT`.
---@param opts? { root?: string }
---@return string|nil root  forward slashes, no trailing slash
---@return string|nil err
function M.root(opts)
  local candidate = opts and opts.root
  if not candidate or candidate == "" then
    candidate = override_root
  end
  if not candidate or candidate == "" then
    candidate = configured_root
  end
  if not candidate or candidate == "" then
    local env_root = vim.env.TASKS_VAULT
    if env_root and env_root ~= "" then
      candidate = env_root
    end
  end
  if not candidate or candidate == "" then
    return nil, "vault not found: call setup({ vault = <dir> }), set $TASKS_VAULT, or pass --vault"
  end
  candidate = fsio.norm(candidate)
  if not fsio.is_dir(candidate) then
    return nil, "vault is not a directory: " .. candidate
  end
  return candidate, nil
end

---Names Windows treats as devices, in any case and with or without an
---extension (`NUL`, `con.txt`). A file called like one is no file there: writing
---it succeeds and stores nothing (`nul`), or fails with a confusing error, and
---older Windows versions and some tools refuse the extended form too.
---@type table<string, true>
local DEVICE_NAMES = { con = true, prn = true, aux = true, nul = true }
for i = 1, 9 do
  DEVICE_NAMES["com" .. i] = true
  DEVICE_NAMES["lpt" .. i] = true
end

---Whether `name` is (or starts, before its first dot, like) a Windows device name.
---@param name any
---@return boolean
function M.is_reserved_name(name)
  if type(name) ~= "string" then
    return false
  end
  -- Windows also drops trailing spaces before the extension (`nul .txt`).
  local stem = name:match("^([^.]*)"):gsub("%s+$", "")
  return DEVICE_NAMES[stem:lower()] == true
end

---An area name becomes a path segment, so it is whitelisted (SEC-42): word
---characters, dots and hyphens, not starting with a dot or hyphen. A trailing
---dot is refused as well: Windows drops it, so `lib.nvim.` would silently be
---the folder `lib.nvim` under another id.
---@param name any
---@return boolean
function M.valid_area(name)
  return type(name) == "string"
    and name:match("^[%w_][%w_.-]*$") ~= nil
    and name ~= ".."
    and not name:find("..", 1, true)
    and name:sub(-1) ~= "."
end

---A slug is kebab-case ASCII: `a-z0-9` words joined by single hyphens.
---@param slug any
---@return boolean
function M.valid_slug(slug)
  return type(slug) == "string"
    and slug:match("^[a-z0-9][a-z0-9-]*$") ~= nil
    and not slug:find("--", 1, true)
    and slug:sub(-1) ~= "-"
end

---Split `<area>/<slug>`. A bare `<area>` gives `slug = nil`.
---@param id any
---@return string|nil area
---@return string|nil slug
---@return string|nil err
function M.parse_id(id)
  if type(id) ~= "string" or id == "" then
    return nil, nil, "empty task id"
  end
  local area, slug = id:match("^([^/]+)/([^/]+)$")
  if not area then
    if id:find("/", 1, true) then
      return nil, nil, "malformed task id (expected <area>/<slug>): " .. id
    end
    area = id
  end
  if not M.valid_area(area) then
    return nil, nil, "invalid area name: " .. area
  end
  if slug and not M.valid_slug(slug) then
    return nil, nil, "invalid slug: " .. slug
  end
  return area, slug, nil
end

---`<area>/ROADMAP/tasks`
---@param root string
---@param area string
---@return string
function M.tasks_dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/tasks"
end

---`<area>/ROADMAP/plans`: the plan files of the area (optional).
---@param root string
---@param area string
---@return string
function M.plans_dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/plans"
end

---`<area>/ROADMAP/plans/<slug>.md`
---@param root string
---@param area string
---@param slug string
---@return string
function M.plan_path(root, area, slug)
  return M.plans_dir(root, area) .. "/" .. slug .. ".md"
end

---`<area>/ROADMAP/TASKS.md`, the generated index.
---@param root string
---@param area string
---@return string
function M.index_path(root, area)
  return root .. "/" .. area .. "/ROADMAP/TASKS.md"
end

---`<area>/Backlog/<bucket>`
---@param root string
---@param area string
---@param bucket Tasks.Bucket
---@return string
function M.backlog_dir(root, area, bucket)
  return root .. "/" .. area .. "/Backlog/" .. bucket
end

---`<area>/Backlog/README.md`
---@param root string
---@param area string
---@return string
function M.backlog_readme(root, area)
  return root .. "/" .. area .. "/Backlog/README.md"
end

---`<area>/ROADMAP/tasks/<slug>.md`
---@param root string
---@param area string
---@param slug string
---@return string
function M.task_path(root, area, slug)
  return M.tasks_dir(root, area) .. "/" .. slug .. ".md"
end

---`<area>/ROADMAP/tasks/<slug>`, the folder of a folder task.
---@param root string
---@param area string
---@param slug string
---@return string
function M.task_dir(root, area, slug)
  return M.tasks_dir(root, area) .. "/" .. slug
end

---`<area>/ROADMAP/tasks/<slug>/<slug>.md`, the task file of a folder task.
---@param root string
---@param area string
---@param slug string
---@return string
function M.folder_task_path(root, area, slug)
  return M.task_dir(root, area, slug) .. "/" .. slug .. ".md"
end

---Find an open task on disk, whichever form it has.
---@param root string
---@param area string
---@param slug string
---@return string|nil path   the task file
---@return boolean|string folder  true for a folder task; the error text when `path` is nil
function M.resolve_task(root, area, slug)
  local file, folder = M.task_path(root, area, slug), M.folder_task_path(root, area, slug)
  local has_file, has_folder = fsio.is_file(file), fsio.is_file(folder)
  if has_file and has_folder then
    return nil, ("task exists as file and as folder: %s/%s"):format(area, slug)
  elseif has_file then
    return file, false
  elseif has_folder then
    return folder, true
  end
  return nil, "no such open task: " .. area .. "/" .. slug
end

---Whether the folder `<root>/<name>` is an area: it holds `ROADMAP/` or
---`Backlog/`, or is one of `EXTRA_AREAS`; hidden and `_`-prefixed folders and
---`SKIP` entries never are.
---@param root string
---@param name string
---@return boolean
local function is_area_dir(root, name)
  if not M.valid_area(name) or name:match("^[._]") or M.SKIP[name] then
    return false
  end
  local dir = root .. "/" .. name
  if not fsio.is_dir(dir) then
    return false
  end
  for _, extra in ipairs(M.extra_areas()) do
    if extra == name then
      return true
    end
  end
  return fsio.is_dir(dir .. "/ROADMAP") or fsio.is_dir(dir .. "/Backlog")
end

---Every area, sorted by name (see `is_area_dir` for what counts).
---@param root string
---@return Tasks.Area[]
function M.areas(root)
  local out = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return out
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if is_area_dir(root, name) then
      out[#out + 1] = { name = name, path = root .. "/" .. name }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---Whether `root` holds an entry named exactly `name`. A path lookup is not
---that strict: on Windows (and macOS) `stat` finds `LIB.NVIM` and `lib.nvim.`
---for the folder `lib.nvim`, so an id typed in the wrong case would write into
---the right folder under a different id.
---@param root string
---@param name string
---@return boolean
function M.dir_listed(root, name)
  local handle = uv.fs_scandir(root)
  if not handle then
    return false
  end
  while true do
    local entry = uv.fs_scandir_next(handle)
    if not entry then
      return false
    end
    if entry == name then
      return true
    end
  end
end

---Whether `area` is one of the vault's areas. The name must match the folder's spelling
---exactly: an area in another case would reach the same folder on Windows, yet become a second
---id for the same tasks, and its generated index would read as stale (`index-stale`).
---@param root string
---@param area string
---@return boolean
function M.has_area(root, area)
  return type(area) == "string" and is_area_dir(root, area) and M.dir_listed(root, area)
end

return M
