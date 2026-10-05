---@module 'tasks_nvim.scan'
---@brief Collect task files for one area or the whole vault.
---@description
--- Walks `<area>/ROADMAP/tasks/` (open tasks) and `<area>/Backlog/` (finished
--- ones) with `lib.nvim.fs.collect_recursive`, optionally through the TTL cache
--- `lib.nvim.fs.scan_cached` for callers that filter repeatedly (a dashboard).
---
--- Key responsibilities:
---  - one `Tasks.Task` per `*.md` file, in path order; a file that cannot be
---    read or parsed comes back as an invalid task, it never aborts the scan
---  - a folder task (`tasks/<slug>/<slug>.md`) is a task like a plain file; the
---    other files in its folder are assets and never read as tasks
---  - other nested files under `tasks/` are returned too (flagged), so `check`
---    can report them instead of them silently not existing
---  - `Backlog/` files count as tasks only when they carry frontmatter with a
---    `status`: the old free-form documents there are not tasks
---
--- Not its job: ranking or filtering (`model`), rendering (`index`).

local collect = require("lib.nvim.fs.collect_recursive")
local scan_cached = require("lib.nvim.fs.scan_cached")

local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.ScanOpts
---@field root? string                 # Vault root (default: `vault.root()`).
---@field ttl_seconds? integer         # Use the in-memory TTL cache for the directory walk.
---@field refresh? boolean             # With `ttl_seconds`: force a fresh walk.

---Markdown files below `dir`, sorted. A missing directory is an empty result,
---not an error: an area without tasks has no `tasks/` folder.
---@param dir string
---@param opts Tasks.ScanOpts
---@return string[] paths
---@return string[] errors
local function markdown_files(dir, opts)
  if not fsio.is_dir(dir) then
    return {}, {}
  end
  local paths, errors
  if opts.ttl_seconds then
    paths, errors = scan_cached.scan(dir, {
      kind = "files",
      ttl_seconds = opts.ttl_seconds,
      refresh = opts.refresh,
    })
  else
    paths, errors = collect.files(dir)
  end
  local out = {}
  for _, p in ipairs(paths) do
    if p:match("%.md$") then
      out[#out + 1] = fsio.norm(p)
    end
  end
  table.sort(out)
  return out, errors or {}
end

---Sort the markdown files below `dir` into task files and the rest.
---
---A task file is `<name>.md` directly in `dir`, or `<name>/<name>.md` (a folder
---task). Any other file inside a folder that holds its own `<name>.md` is an
---asset and is dropped. What is left (a file in a folder without a matching
---task file, or deeper) is `nested`: kept so `check` can report it.
---@param dir string
---@param files string[]  normalised absolute paths below `dir`
---@return { path: string, folder: boolean, nested: boolean }[] entries
local function classify(dir, files)
  local has_task_file = {}
  for _, path in ipairs(files) do
    local name, base = path:sub(#dir + 2):match("^([^/]+)/([^/]+)%.md$")
    if name and name == base then
      has_task_file[name] = true
    end
  end
  local out = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#dir + 2)
    local top = rel:match("^([^/]+)/")
    if not top then
      out[#out + 1] = { path = path, folder = false, nested = false }
    elseif has_task_file[top] then
      local name, base = rel:match("^([^/]+)/([^/]+)%.md$")
      if name and name == base then
        out[#out + 1] = { path = path, folder = true, nested = false }
      end
    else
      out[#out + 1] = { path = path, folder = false, nested = true }
    end
  end
  return out
end

---The task files among the markdown files of a `Backlog/<bucket>` folder: a
---file directly in it, a folder task's `<name>/<name>.md`, and (as before) any
---other nested file. The other files inside a folder task are assets.
---@param dir string
---@param files string[]
---@return { path: string, folder: boolean }[] entries
local function backlog_files(dir, files)
  local has_task_file = {}
  for _, path in ipairs(files) do
    local name, base = path:sub(#dir + 2):match("^([^/]+)/([^/]+)%.md$")
    if name and name == base then
      has_task_file[name] = true
    end
  end
  local out = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#dir + 2)
    local top = rel:match("^([^/]+)/")
    if not top then
      out[#out + 1] = { path = path, folder = false }
    elseif has_task_file[top] then
      local name, base = rel:match("^([^/]+)/([^/]+)%.md$")
      if name and name == base then
        out[#out + 1] = { path = path, folder = true }
      end
    else
      out[#out + 1] = { path = path, folder = false }
    end
  end
  return out
end

---Names of the folders directly inside a `Backlog/<bucket>` folder.
---@param dir string
---@return table<string, boolean>
local function backlog_folder_names(dir)
  local names = {}
  local handle = (vim.uv or vim.loop).fs_scandir(dir)
  if not handle then
    return names
  end
  while true do
    local name, kind = (vim.uv or vim.loop).fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" then
      names[name] = true
    end
  end
  return names
end

---@param opts? Tasks.ScanOpts
---@return string|nil root
---@return string|nil err
local function resolve_root(opts)
  return vault.root(opts)
end

---The task files of one area's `ROADMAP/tasks/` (any status), in path order.
---@param area string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]|nil tasks
---@return string[]|string errors  walk errors, or the failure message when `tasks` is nil
function M.area(area, opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local dir = vault.tasks_dir(root, area)
  local files, errors = markdown_files(dir, opts)
  local tasks = {}
  for _, entry in ipairs(classify(dir, files)) do
    tasks[#tasks + 1] = model.from_file(entry.path, {
      area = area,
      location = "roadmap",
      nested = entry.nested,
      folder = entry.folder,
    })
  end
  return tasks, errors
end

---Every area's `ROADMAP/tasks/`, areas in name order.
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]|nil tasks
---@return string[]|string errors
function M.all(opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err
  end
  local all, all_errors = {}, {}
  for _, area in ipairs(vault.areas(root)) do
    local tasks, errors = M.area(area.name, vim.tbl_extend("force", opts, { root = root }))
    for _, t in ipairs(tasks or {}) do
      all[#all + 1] = t
    end
    for _, e in ipairs(type(errors) == "table" and errors or { errors }) do
      all_errors[#all_errors + 1] = e
    end
  end
  return all, all_errors
end

---Backlog files of one area that are task files (frontmatter with `status`).
---@param area string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]|nil tasks
---@return string[]|string errors
function M.backlog(area, opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local tasks, all_errors = {}, {}
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    local files, errors = markdown_files(dir, opts)
    for _, e in ipairs(errors) do
      all_errors[#all_errors + 1] = e
    end
    for _, entry in ipairs(backlog_files(dir, files)) do
      local path = entry.path
      local text = fsio.read(path)
      -- Cheap pre-test: most old Backlog documents have no frontmatter at all.
      if text and text:match("^\239?\187?\191?%-%-%-") then
        local task = model.parse_text(
          text,
          { path = path, area = area, location = "backlog", folder = entry.folder }
        )
        if task.meta.status ~= nil then
          tasks[#tasks + 1] = task
        end
      end
    end
  end
  return tasks, all_errors
end

---Every slug already used by a file below `<area>/Backlog/` (date prefix
---stripped), whether or not that file is a task. A new task must not reuse one:
---ids are global and `done` would otherwise produce two files with one id.
---@param area string
---@param opts? Tasks.ScanOpts
---@return table<string, string>|nil slugs  slug -> path
---@return string|nil err
function M.backlog_slugs(area, opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local slugs = {}
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    local files, walk_errors = markdown_files(dir, opts)
    if #walk_errors > 0 then
      -- A listing that failed is not an empty one: a new task would be given a slug a finished task has.
      return nil, ("cannot list %s: %s"):format(dir, tostring(walk_errors[1]))
    end
    for _, entry in ipairs(backlog_files(dir, files)) do
      slugs[model.slug_of(entry.path, "backlog")] = entry.path
    end
    -- A folder in Backlog/ that is not a task folder still takes its name.
    for name in pairs(backlog_folder_names(dir)) do
      local slug = name:gsub("^%d%d%d%d%-%d%d%-%d%d_", "")
      slugs[slug] = slugs[slug] or (dir .. "/" .. name)
    end
  end
  return slugs, nil
end

---The open task `<area>/<slug>`.
---@param id string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task|nil task
---@return string|nil err
function M.find(id, opts)
  local root, err = resolve_root(opts)
  if not root then
    return nil, err
  end
  local area, slug, id_err = vault.parse_id(id)
  if not area or not slug then
    return nil, id_err or ("expected <area>/<slug>, got " .. tostring(id))
  end
  -- Not an area, or one spelled in another case (`LIB.NVIM/x` would find `lib.nvim/x` on a
  -- case-insensitive disk, under a second id).
  if not vault.has_area(root, area) then
    return nil, "no such open task: " .. area .. "/" .. slug
  end
  local path, folder = vault.resolve_task(root, area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return model.from_file(
    path,
    { area = area, location = "roadmap", slug = slug, folder = folder == true }
  ),
    nil
end

---The finished task `<area>/<slug>` from `Backlog/`, whatever its date prefix.
---@param id string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task|nil task
function M.find_done(id, opts)
  local root = resolve_root(opts)
  if not root then
    return nil
  end
  local area, slug = vault.parse_id(id)
  if not area or not slug or not vault.dir_listed(root, area) then
    return nil
  end
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    for _, entry in ipairs(backlog_files(dir, markdown_files(dir, opts or {}))) do
      if model.slug_of(entry.path, "backlog") == slug then
        return model.from_file(entry.path, {
          area = area,
          location = "backlog",
          folder = entry.folder,
        })
      end
    end
  end
  return nil
end

return M
