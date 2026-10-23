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
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@class Tasks.ScanOpts
---@field root? string                 # Vault root (default: `vault.root()`).
---@field ttl_seconds? integer         # Use the in-memory TTL cache for the directory walk.
---@field refresh? boolean             # With `ttl_seconds`: force a fresh walk.
---@field link_resolver? Tasks.LinkResolver  # Settles bare `[[slug]]` wikilinks; one is made per call when absent (pass one to share its index over several calls).

---Settle the bare-slug wikilinks of `tasks` (`tasks_nvim.wikilinks.resolve`) against the vault `root`. The vault's
---folders are listed only when one of the tasks has such a link.
---@param tasks Tasks.Task[]
---@param root string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]
local function linked(tasks, root, opts)
  for _, t in ipairs(tasks) do
    if t.wikilinks then
      return wikilinks.resolve(tasks, (opts and opts.link_resolver) or wikilinks.resolver(root))
    end
  end
  return tasks
end

---Markdown files below `dir`, sorted. A missing directory is an empty result,
---not an error: an area without tasks has no `tasks/` folder.
---@param dir string
---@param opts Tasks.ScanOpts
---@param root? string  # the vault; with it a folder that leads out of the vault is refused
---@return string[] paths
---@return string[] errors
local function markdown_files(dir, opts, root)
  if not fsio.is_dir(dir) then
    return {}, {}
  end
  local escape = root and vault.leaves(root, dir)
  if escape then
    return {}, { escape }
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

---Sort the markdown files below `dir` (a `tasks` or a `Backlog/<bucket>` folder) into task files and the rest.
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
    return nil, err or "vault not found"
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local dir = vault.tasks_dir(root, area)
  local files, errors = markdown_files(dir, opts, root)
  local tasks = {}
  for _, entry in ipairs(classify(dir, files)) do
    tasks[#tasks + 1] = model.from_file(entry.path, {
      area = area,
      location = "roadmap",
      nested = entry.nested,
      folder = entry.folder,
    })
  end
  return linked(tasks, root, opts), errors
end

---Every area's `ROADMAP/tasks/`, areas in name order.
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]|nil tasks
---@return string[]|string errors
function M.all(opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err or "vault not found"
  end
  local all, all_errors = {}, {}
  local area_opts = vim.tbl_extend(
    "force",
    opts,
    { root = root, link_resolver = opts.link_resolver or wikilinks.resolver(root) }
  )
  for _, area in ipairs(vault.areas(root)) do
    local tasks, errors = M.area(area.name, area_opts)
    for _, t in ipairs(tasks or {}) do
      all[#all + 1] = t
    end
    for _, e in ipairs(type(errors) == "table" and errors or { errors }) do
      all_errors[#all_errors + 1] = e
    end
  end
  return all, all_errors
end

---@class Tasks.OpenTasksOpts : Tasks.ScanOpts
---@field area? string   # One area (default: all of them).

---The open tasks, the one list every front end starts from: one area (`opts.area`) or all of them, with
---the tasks whose status is not an open one (a `done` file that is still in `ROADMAP/`) counted, not listed.
---@param opts? Tasks.OpenTasksOpts
---@return Tasks.Task[]|nil open
---@return integer|string skipped_or_err  the number of tasks left out, or the error when `open` is nil
---@return string[]|nil errors  directories that could not be listed (the result is then incomplete)
function M.open_tasks(opts)
  opts = opts or {}
  local tasks, errors
  if opts.area then
    tasks, errors = M.area(opts.area, opts)
  else
    tasks, errors = M.all(opts)
  end
  if not tasks then
    return nil, tostring(errors), nil
  end
  local open, skipped = {}, 0
  for _, t in ipairs(tasks) do
    if model.is_open_status(t.status) then
      open[#open + 1] = t
    else
      skipped = skipped + 1
    end
  end
  return open, skipped, type(errors) == "table" and errors or {}
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
    return nil, err or "vault not found"
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local tasks, all_errors = {}, {}
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    local files, errors = markdown_files(dir, opts, root)
    for _, e in ipairs(errors) do
      all_errors[#all_errors + 1] = e
    end
    for _, entry in ipairs(classify(dir, files)) do
      -- Through the parse cache (mtime and size): a finished task does not change, so a second look is a stat.
      -- A document without frontmatter parses to an empty `meta` and is no task.
      local task =
        model.from_file(entry.path, { area = area, location = "backlog", folder = entry.folder })
      if task.meta.status ~= nil then
        tasks[#tasks + 1] = task
      end
    end
  end
  return linked(tasks, root, opts), all_errors
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
    return nil, err or "vault not found"
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local slugs = {}
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    local files, walk_errors = markdown_files(dir, opts, root)
    if #walk_errors > 0 then
      -- A listing that failed is not an empty one: a new task would be given a slug a finished task has.
      return nil, ("cannot list %s: %s"):format(dir, tostring(walk_errors[1]))
    end
    for _, entry in ipairs(classify(dir, files)) do
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

---A finished-id lookup (`function(id): boolean`, the same answer as `find_done(id) ~= nil`) that lists each area's
---Backlog ONCE. `find_done` walks, sorts and classifies both buckets of the area for every single id; a pass that asks
---for hundreds of blockers (`check`, `plan`, `next`, `list --ready`) paid that for each of them.
---@param opts? Tasks.ScanOpts
---@return fun(id: string): boolean
function M.finished_lookup(opts)
  opts = opts or {}
  local root = resolve_root(opts)
  ---@type table<string, table<string, boolean>|false>
  local per_area = {}
  return function(id)
    if not root then
      return false
    end
    local area, slug = vault.parse_id(id)
    if not area or not slug then
      return false
    end
    local set = per_area[area]
    if set == nil then
      -- `dir_listed` (a scan of the vault root) once per area spelling, not once per id
      local found
      if vault.dir_listed(root, area) then
        found = {}
        for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
          local dir = vault.backlog_dir(root, area, bucket)
          for _, entry in ipairs(classify(dir, markdown_files(dir, opts, root))) do
            found[model.slug_of(entry.path, "backlog")] = true
          end
        end
      end
      set = found or false
      per_area[area] = set
    end
    if not set then
      return false
    end
    return set[slug] == true
  end
end

---The open task `<area>/<slug>`.
---@param id string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task|nil task
---@return string|nil err
function M.find(id, opts)
  local root, err = resolve_root(opts)
  if not root then
    return nil, err or "vault not found"
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
  local task = model.from_file(
    path,
    { area = area, location = "roadmap", slug = slug, folder = folder == true }
  )
  return linked({ task }, root, opts)[1], nil
end

-- What the last look at a finished file found: `path -> { sec, nsec, size, marked }`. A finished file hardly ever
-- changes, so a second look is a stat.
local reminder_stamp = {}

---A file this young may still change within the resolution of its timestamp without its stat moving (the racy-file
---rule `model` keeps for the parse cache): it is not trusted from the stamp.
local STAMP_RACY_SECONDS = 2

---The paths of the finished tasks of one `Backlog/<bucket>` folder: `<file>.md` and `<dir>/<dir>.md` (a folder task).
---Cheaper than a recursive walk: nothing is read here.
---@param dir string
---@return { path: string, folder: boolean }[]
local function bucket_files(dir)
  local out = {}
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:match("%.md$") and name ~= "README.md" then
      out[#out + 1] = { path = dir .. "/" .. name, folder = false }
    elseif kind == "directory" and not name:match("^%.") then
      out[#out + 1] = { path = dir .. "/" .. name .. "/" .. name .. ".md", folder = true }
    end
  end
  return out
end

---Whether the file `path` has a `remind:` line. A file that has not changed since the last look costs a stat; a new or
---changed one is read and searched, not parsed.
---@param path string
---@param st table  # its `fs_stat`
---@param now integer
---@return boolean
local function has_remind_line(path, st, now)
  local stamp = reminder_stamp[path]
  if
    stamp
    and stamp.sec == st.mtime.sec
    and stamp.nsec == st.mtime.nsec
    and stamp.size == st.size
  then
    return stamp.marked
  end
  -- A link is no way out of the vault: it is not read (`a and nil or b` would read it anyway, so it is spelled out).
  local text
  if not fsio.is_link(path) then
    text = fsio.read(path)
  end
  -- the frontmatter's own line: never the first line of the file (that is the fence)
  local marked = text ~= nil and text:find("\nremind:", 1, true) ~= nil
  if now - st.mtime.sec >= STAMP_RACY_SECONDS then
    reminder_stamp[path] =
      { sec = st.mtime.sec, nsec = st.mtime.nsec, size = st.size, marked = marked }
  else
    reminder_stamp[path] = nil
  end
  return marked
end

---@class Tasks.RemindersOpts : Tasks.ScanOpts
---@field area? string   # One area (default: all of them).

---The open tasks that carry a `remind:` line, one area (`opts.area`) or all of them. The files are not parsed to find
---them: only a file that has the line is.
---@param opts? Tasks.RemindersOpts
---@return Tasks.Task[]|nil tasks
---@return string|nil err
---@return string[]|nil errors  folders that were not read (a link that leaves the vault); the result is then incomplete
function M.open_reminders(opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err or "vault not found"
  end
  local uv = vim.uv or vim.loop
  local now = os.time()
  local out, errors = {}, {}
  for _, area in ipairs(vault.areas(root)) do
    if not opts.area or area.name == opts.area then
      local dir = vault.tasks_dir(root, area.name)
      local files, walk_errors = markdown_files(dir, opts, root)
      for _, e in ipairs(walk_errors) do
        errors[#errors + 1] = e
      end
      for _, entry in ipairs(classify(dir, files)) do
        local st = uv.fs_stat(entry.path)
        if st and st.type == "file" and has_remind_line(entry.path, st, now) then
          local task = model.from_file(entry.path, {
            area = area.name,
            location = "roadmap",
            nested = entry.nested,
            folder = entry.folder,
          })
          if model.is_open_status(task.status) and model.is_date(task.remind) then
            out[#out + 1] = task
          end
        end
      end
    end
  end
  return linked(out, root, opts), nil, errors
end

---The finished tasks that carry a `remind:` line, one area (`opts.area`) or all of them. The files are not parsed to
---find them: one that has not changed since the last look costs a stat, a new or changed one is searched for the line
---first, and only a file that has it is parsed. A `Backlog/<bucket>` folder that leads out of the vault (a link, a
---junction) is not read, like everywhere else.
---@param opts? Tasks.RemindersOpts
---@return Tasks.Task[]|nil tasks
---@return string|nil err
---@return string[]|nil errors  folders that were not read; the result is then incomplete
function M.backlog_reminders(opts)
  opts = opts or {}
  local root, err = resolve_root(opts)
  if not root then
    return nil, err or "vault not found"
  end
  local uv = vim.uv or vim.loop
  local now = os.time()
  local out, errors = {}, {}
  for _, area in ipairs(vault.areas(root)) do
    if not opts.area or area.name == opts.area then
      for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
        local dir = vault.backlog_dir(root, area.name, bucket)
        local escape = vault.leaves(root, dir)
        if escape then
          errors[#errors + 1] = escape
        else
          for _, entry in ipairs(bucket_files(dir)) do
            local st = uv.fs_stat(entry.path)
            if st and st.type == "file" and has_remind_line(entry.path, st, now) then
              local task = model.from_file(
                entry.path,
                { area = area.name, location = "backlog", folder = entry.folder }
              )
              if task.meta.status ~= nil and model.is_date(task.remind) then
                out[#out + 1] = task
              end
            end
          end
        end
      end
    end
  end
  return linked(out, root, opts), nil, errors
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
    for _, entry in ipairs(classify(dir, markdown_files(dir, opts or {}, root))) do
      if model.slug_of(entry.path, "backlog") == slug then
        local task = model.from_file(entry.path, {
          area = area,
          location = "backlog",
          folder = entry.folder,
        })
        return linked({ task }, root, opts)[1]
      end
    end
  end
  return nil
end

---Every finished file of `id` in its area's Backlog, newest first: a slug finished, reopened and finished again has a
---file for each time. `find_done` is the first of them in the order of the folders (FEATURES, then TASKS, by date).
---@param id string
---@param opts? Tasks.ScanOpts
---@return Tasks.Task[]
function M.find_done_all(id, opts)
  local root = resolve_root(opts)
  if not root then
    return {}
  end
  local area, slug = vault.parse_id(id)
  if not area or not slug or not vault.dir_listed(root, area) then
    return {}
  end
  local found = {}
  for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
    local dir = vault.backlog_dir(root, area, bucket)
    for _, entry in ipairs(classify(dir, markdown_files(dir, opts or {}, root))) do
      if model.slug_of(entry.path, "backlog") == slug then
        found[#found + 1] = model.from_file(entry.path, {
          area = area,
          location = "backlog",
          folder = entry.folder,
        })
      end
    end
  end
  -- The day it was finished: the date the name of the file starts with, or that of its folder (a folder task whose
  -- file was not renamed). An undated one (made by hand) comes last; the whole path breaks a tie.
  local function day_of(t)
    return model.done_date(t.path) or model.done_date(vim.fs.dirname(t.path)) or ""
  end
  table.sort(found, function(a, b)
    local da, db = day_of(a), day_of(b)
    if da ~= db then
      return da > db
    end
    return a.path > b.path
  end)
  return linked(found, root, opts)
end

return M
