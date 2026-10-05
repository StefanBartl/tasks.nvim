---@module 'tasks_nvim.staleness'
---@brief `--stale-refs`: which open tasks point at files that changed after the task was last updated.
---@description
--- A task may carry `refs: [lua/ai/config/init.lua, docs/attachments.md, lib.nvim@803de65]`.
--- The idea (concept section 15, borrowed from documentation.nvim's
--- `@ref`/`@verified` checklists): when a referenced file changed after the
--- task's `updated` date, the task needs a fresh read -- it is "stale by refs".
---
--- Key responsibilities:
---  - classify a ref: a path is checked; `repo@sha` commits, URLs and
---    `name:thing` anchors are skipped; `file:42` and `file#anchor` lose the suffix
---  - resolve a path against an ordered list of bases (the repo named like the
---    task's area, the nvim config, the vault, the vault's parent); the first
---    base where it exists wins; a ref found nowhere is only counted
---  - date the file: the commit date of the last commit touching it (one
---    batched `git log` per base and 100 paths), the mtime when git does not know it
---  - compare day-wise: a change is a day later than `updated` (or `created`)
---
--- Cost control: refs are de-duplicated per (base, path), at most `MAX_REFS`
--- distinct files are looked at per run (the rest is reported in `notes`), all
--- git calls of a run share the time budget (`staleness.budget_ms` of `setup()`), and every failure
--- (no git, not a repo, a missing repo, one path git refuses) degrades to mtime
--- or to a skipped ref -- it never raises, and one bad ref costs only its own date.
---
--- Not its job: parsing or filtering tasks (`model.filter` calls `compute`
--- when `Tasks.Filter.stale_refs` is set), printing, git history beyond "last
--- touched". Uncommitted edits are not seen (commit first, as the workflow does).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---Distinct files looked at per run.
M.MAX_REFS = 1000

---Paths per `git log` call.
M.GIT_CHUNK = 100

---Commits one `git log` may walk (only commits touching the paths count).
M.MAX_COMMITS = 3000

---The `staleness` section of `setup()`: `git_timeout_ms` (one git call is given up after it),
---`budget_ms` (all git calls of one `compute` together; after that the remaining files are dated by their
---mtime) and `repo_bases`.
---@return Tasks.StalenessConfig
local function settings()
  return require("tasks_nvim.config").get().staleness
end

---@class Tasks.RefChange
---@field ref string      # The ref as written in the task.
---@field file string     # The file that changed (inside a directory ref: the file in it), forward slashes.
---@field date string     # `YYYY-MM-DD` of the change.
---@field source "git"|"mtime"

---@class Tasks.StalenessReport
---@field stale table<string, Tasks.RefChange[]>  # Task id -> what changed.
---@field tasks integer       # Tasks that carry at least one checkable ref.
---@field files integer       # Distinct files dated.
---@field unresolved integer  # Path refs found in no base.
---@field skipped integer     # Refs that are no paths (commits, URLs, anchors) or tasks without a date.
---@field capped integer      # Distinct files beyond `MAX_REFS`, not looked at.
---@field notes string[]      # Human remarks (a base that is no git repo, the cap, a failed git call).

---@class Tasks.StalenessOpts
---@field root? string                # Vault root (default: `vault.root()`).
---@field repo_bases? string[]        # Folders that hold the repos by name (`<base>/<area>`); default: derived from the vault and `$REPOS_DIR`.
---@field config_dir? string          # The nvim config checkout (default: `$NVIM_CONFIG_DIR`, else `stdpath("config")`).
---@field extra_bases? string[]       # More bases tried after the standard ones.
---@field max_refs? integer
---@field budget_ms? integer          # Time all git calls may take together (default `staleness.budget_ms` of `setup()`).
---@field git_dates? fun(base: string, rels: string[], gopts?: Tasks.GitDatesOpts): table<string, { date: string, file: string }>|nil, string|nil  # Replaces the git lookup (specs).

---The last report `compute` produced, so a front end that only sees the
---filtered task list can still print which file changed.
---@type Tasks.StalenessReport|nil
M.last = nil

---How a ref is read.
---@param ref any
---@return "path"|"skip" kind
---@return string|nil rel  # The normalized path for `path`.
function M.classify(ref)
  if type(ref) ~= "string" then
    return "skip", nil
  end
  local s = vim.trim(ref)
  if s == "" then
    return "skip", nil
  end
  -- `lib.nvim@803de65`: a commit of a repo, nothing on disk to date.
  if s:match("^[%w_.-]+@%x+$") then
    return "skip", nil
  end
  -- URLs and `name:anchor` refs (`filetree.nvim:cheatsheet-paged`); a drive letter is a path.
  if s:match("^%a[%w+.-]*://") or s:match("^mailto:") then
    return "skip", nil
  end
  if s:find(":", 1, true) and not s:match("^%a:[/\\]") then
    -- `file.lua:42` is a path with a line number.
    local stripped = s:match("^(.-):%d+$")
    if stripped and not stripped:find(":", 1, true) then
      s = stripped
    else
      return "skip", nil
    end
  end
  s = s:gsub("#.*$", "")
  s = fsio.norm(s):gsub("^%./", "")
  if s == "" then
    return "skip", nil
  end
  return "path", s
end

---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil
end

---Whether a forward-slash path has a `..` segment.
---@param path string
---@return boolean
local function has_dotdot(path)
  return ("/" .. path .. "/"):find("/../", 1, true) ~= nil
end

---Resolve `.` and `..` segments of an absolute forward-slash path without
---touching the disk. A drive (`C:`) or UNC share (`//server/share`) is the root:
---`..` never climbs above it.
---@param path string
---@return string
local function collapse_dots(path)
  local root, rest = path:match("^(//[^/]+/[^/]+)(.*)$")
  if not root then
    root, rest = path:match("^(%a:)(.*)$")
  end
  if not root then
    root, rest = "", path
  end
  local parts = {}
  for seg in rest:gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return root .. "/" .. table.concat(parts, "/")
end

---The folders to look for the files of `$REPOS_DIR`-style layouts: next to the
---vault's checkout and below `$REPOS_DIR`.
---@param root string
---@return string[]
local function default_repo_bases(root)
  local out, seen = {}, {}
  ---@param dir string|nil
  local function add(dir)
    if dir and dir ~= "" then
      dir = fsio.norm(dir)
      if not seen[dir] and fsio.is_dir(dir) then
        seen[dir] = true
        out[#out + 1] = dir
      end
    end
  end
  -- the vault usually sits three levels below the folder that holds the repos (<repos>/a/b/<vault> -> <repos>)
  local repos = fsio.dirname(fsio.dirname(fsio.dirname(root)))
  add(repos)
  add(repos .. "/repos")
  -- The repos folder the host publishes (`$REPOS_DIR` and friends), read through lib.nvim like every
  -- environment-based default (LUA-04), not straight from `vim.env`.
  local ok_env, env = pcall(function()
    return require("lib.nvim.system.env").get()
  end)
  local env_dir = ok_env and env.repo_base or nil
  if env_dir and env_dir ~= "" then
    add(env_dir)
    add(env_dir .. "/repos")
  end
  return out
end

---@param opts Tasks.StalenessOpts
---@return string|nil
local function default_config_dir(opts)
  if opts.config_dir and opts.config_dir ~= "" then
    return fsio.norm(opts.config_dir)
  end
  local env_dir = vim.env.NVIM_CONFIG_DIR
  if env_dir and env_dir ~= "" then
    return fsio.norm(env_dir)
  end
  local ok, dir = pcall(vim.fn.stdpath, "config")
  return ok and fsio.norm(dir) or nil
end

---`YYYY-MM-DD` (local time) of a unix timestamp.
---@param ts integer
---@return string
local function day_of(ts)
  -- `os.date` answers nil (it does not raise) for a timestamp outside its range, e.g. a `%ct` of
  -- 99999999999999999999 from a forged commit; "0000-00-00" sorts before every real day, so such a file
  -- is never reported as changed after a task's `updated`.
  return os.date("%Y-%m-%d", ts) or "0000-00-00"
end

---Folders `git log` answered "not a git repository" for, with the time of the answer. Only that answer is
---remembered, and only for `NO_REPO_TTL` seconds: a folder that is `git init`ed meanwhile must not stay
---"no repository" until the editor restarts.
---@type table<string, integer>
local no_repo = {}

local NO_REPO_TTL = 30

---@param base string
---@return boolean
local function is_no_repo(base)
  local at = no_repo[base]
  if at == nil then
    return false
  end
  if os.time() - at >= NO_REPO_TTL then
    no_repo[base] = nil
    return false
  end
  return true
end

---Forget which folders were no git repos (specs build and remove temp repos).
function M.reset_cache()
  no_repo = {}
end

---One `git log` over `paths` (relative to `base`). `kind` is set when asking
---again cannot help: `"no_repo"`, `"stop"` (git does not run, or timed out).
---@param base string
---@param paths string[]
---@param timeout_ms integer
---@return table<string, { date: string, file: string }>|nil found
---@return string|nil err
---@return "no_repo"|"stop"|nil kind
local function log_paths(base, paths, timeout_ms)
  local cmd = {
    "git",
    "-C",
    base,
    "-c",
    "core.quotepath=false",
    "log",
    "--relative",
    "--name-only",
    "--no-renames",
    "--format=%x01%ct",
    "--max-count=" .. M.MAX_COMMITS,
    "--",
  }
  vim.list_extend(cmd, paths)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout_ms)
  end)
  if not ok then
    return nil, "git could not run: " .. tostring(res), "stop"
  end
  if res.code ~= 0 then
    local first = (res.stderr or ""):match("^[^\r\n]*") or ""
    if first:find("not a git repository", 1, true) then
      return nil, "not a git repository", "no_repo"
    end
    if res.code == 124 then
      return nil, ("git log timed out after %d ms"):format(timeout_ms), "stop"
    end
    return nil, "git log failed: " .. first
  end
  local wanted = {}
  for _, rel in ipairs(paths) do
    wanted[rel] = true
  end
  local found = {}
  local date
  for line in (res.stdout or ""):gmatch("[^\r\n]+") do
    if line:sub(1, 1) == "\1" then
      date = day_of(tonumber(line:sub(2)) or 0)
    elseif date then
      -- A line names a path when it is that file or a folder above it: look the
      -- line and its parents up, instead of testing every path against every line.
      local path = line
      while path ~= "" do
        if wanted[path] then
          wanted[path] = nil
          found[path] = { date = date, file = line }
        end
        path = path:match("^(.*)/[^/]*$") or ""
      end
    end
  end
  return found, nil
end

---@class Tasks.GitDatesOpts
---@field deadline? integer  # `uv.hrtime()` value after which no further git call is started.

---The date of the last commit touching each path, one `git log` per chunk of
---`GIT_CHUNK` paths. A path in `rels` that is a directory is matched by the files
---below it.
---
---One path git refuses (outside the repository, behind a symlink, ...) makes the
---whole call fail; the chunk is halved until that path stands alone, so it costs
---only its own date, not the other ninety-nine. The dates found are returned even
---then, with `err` naming how many paths git did not date.
---@param base string
---@param rels string[]
---@param gopts? Tasks.GitDatesOpts
---@return table<string, { date: string, file: string }>|nil dates  # nil when `base` is no repo or git cannot be used
---@return string|nil err
function M.git_dates(base, rels, gopts)
  if is_no_repo(base) then
    return nil, "not a git repository"
  end
  local deadline = gopts and gopts.deadline
  local result = {}
  local failed, first_err, stopped = 0, nil, false

  ---@param paths string[]
  local function lookup(paths)
    if stopped then
      failed = failed + #paths
      return
    end
    local timeout = settings().git_timeout_ms
    if deadline then
      local left = math.floor((deadline - uv.hrtime()) / 1e6)
      if left <= 0 then
        stopped, failed = true, failed + #paths
        first_err = first_err or "time budget used up"
        return
      end
      timeout = math.min(timeout, left)
    end
    local found, err, kind = log_paths(base, paths, timeout)
    if found then
      for rel, hit in pairs(found) do
        result[rel] = hit
      end
      return
    end
    first_err = first_err or err
    if kind then
      stopped, failed = true, failed + #paths
      if kind == "no_repo" then
        no_repo[base] = os.time()
      end
    elseif #paths == 1 then
      failed = failed + 1
    else
      local mid = math.ceil(#paths / 2)
      lookup(vim.list_slice(paths, 1, mid))
      lookup(vim.list_slice(paths, mid + 1, #paths))
    end
  end

  for i = 1, #rels, M.GIT_CHUNK do
    lookup(vim.list_slice(rels, i, math.min(i + M.GIT_CHUNK - 1, #rels)))
  end
  if is_no_repo(base) then
    return nil, "not a git repository"
  end
  if failed > 0 then
    return result, ("%d path(s) not dated by git (%s)"):format(failed, tostring(first_err))
  end
  return result, nil
end

---@param full string
---@return string|nil date
local function mtime_day(full)
  local st = uv.fs_stat(full)
  if not st or st.type ~= "file" or not st.mtime then
    return nil
  end
  return day_of(st.mtime.sec)
end

---Where to look for `rel` of a task of `area`, in order.
---@param area string
---@param ctx { repo_bases: string[], config_dir: string|nil, root: string, extra: string[] }
---@return string[]
local function bases_for(area, ctx)
  local out, seen = {}, {}
  ---@param dir string|nil
  local function add(dir)
    if dir and dir ~= "" and not seen[dir] and fsio.is_dir(dir) then
      seen[dir] = true
      out[#out + 1] = dir
    end
  end
  if vault.valid_area(area) then
    for _, rb in ipairs(ctx.repo_bases) do
      add(rb .. "/" .. area)
    end
  end
  add(ctx.config_dir)
  add(ctx.root)
  add(fsio.dirname(ctx.root))
  for _, extra in ipairs(ctx.extra) do
    add(extra)
  end
  return out
end

---Check the refs of `tasks` against the file system and git.
---@param tasks Tasks.Task[]
---@param opts? Tasks.StalenessOpts
---@return Tasks.StalenessReport report
function M.compute(tasks, opts)
  opts = opts or {}
  ---@type Tasks.StalenessReport
  local report =
    { stale = {}, tasks = 0, files = 0, unresolved = 0, skipped = 0, capped = 0, notes = {} }
  M.last = report

  local root = opts.root
  if not root then
    root = vault.root()
  else
    root = fsio.norm(root)
  end
  if not root then
    report.notes[#report.notes + 1] = "vault not found; refs not checked"
    return report
  end
  local ctx = {
    root = root,
    repo_bases = opts.repo_bases
      or (#settings().repo_bases > 0 and settings().repo_bases or default_repo_bases(root)),
    config_dir = default_config_dir(opts),
    extra = opts.extra_bases or {},
  }
  local cap = opts.max_refs or M.MAX_REFS
  local dater = opts.git_dates or M.git_dates
  local budget_ms = opts.budget_ms or settings().budget_ms
  ---@param text string
  local function note(text)
    report.notes[#report.notes + 1] = text
  end

  -- The places to look in depend only on the area; every ref of its tasks reuses them.
  ---@type table<string, string[]>
  local bases_of_area = {}
  ---@param area string
  ---@return string[]
  local function bases_of(area)
    local list = bases_of_area[area]
    if not list then
      list = bases_for(area, ctx)
      bases_of_area[area] = list
    end
    return list
  end

  -- Pass 1: resolve every checkable ref to (base, rel); group by base.
  ---@type table<string, { rels: string[], seen: table<string, boolean> }>
  local by_base = {}
  local base_order = {}
  ---@type { task: Tasks.Task, ref: string, base: string, rel: string, full: string }[]
  local hits = {}
  local counted = {}
  local distinct = {}
  local distinct_n = 0
  local over_cap = {}
  local with_refs = {}
  for _, t in ipairs(tasks) do
    local since = t.updated or t.created
    for _, ref in ipairs(t.refs or {}) do
      local kind, rel = M.classify(ref)
      if kind ~= "path" or not rel then
        report.skipped = report.skipped + 1
      elseif not since then
        report.skipped = report.skipped + 1
      else
        local found_base, found_full
        if is_absolute(rel) then
          if uv.fs_stat(rel) then
            found_base, found_full = fsio.dirname(rel), rel
            rel = rel:match("([^/]+)$") or rel
          end
        else
          for _, base in ipairs(bases_of(t.area)) do
            local full = base .. "/" .. rel
            if uv.fs_stat(full) then
              found_base, found_full = base, full
              break
            end
          end
          if found_base and has_dotdot(rel) then
            -- `../lib.nvim/lua/x.lua` leaves the repo it was found in, and
            -- git refuses a pathspec outside its work tree (for the whole call).
            -- Date the file from the folder it really lives in.
            found_full = collapse_dots(found_full)
            if found_full:sub(1, #found_base + 1) == found_base .. "/" then
              rel = found_full:sub(#found_base + 2)
            else
              found_base, rel = fsio.dirname(found_full), found_full:match("([^/]+)$") or found_full
            end
          end
        end
        if not found_base then
          report.unresolved = report.unresolved + 1
        else
          local key = found_base .. "\0" .. rel
          if not distinct[key] then
            if distinct_n >= cap then
              if not over_cap[key] then
                over_cap[key] = true
                report.capped = report.capped + 1
              end
              key = nil
            else
              distinct[key] = true
              distinct_n = distinct_n + 1
              local group = by_base[found_base]
              if not group then
                group = { rels = {}, seen = {} }
                by_base[found_base] = group
                base_order[#base_order + 1] = found_base
              end
              group.rels[#group.rels + 1] = rel
              group.seen[rel] = true
            end
          end
          if key then
            hits[#hits + 1] =
              { task = t, ref = ref, base = found_base, rel = rel, full = found_full }
            if not with_refs[t.id] then
              with_refs[t.id] = true
              counted[#counted + 1] = t.id
            end
          end
        end
      end
    end
  end
  report.tasks = #counted
  report.files = distinct_n

  -- Pass 2: date the files, one git lookup per base.
  ---@type table<string, table<string, { date: string, file: string, source: "git"|"mtime" }|false>>
  local dated = {}
  -- Every git call blocks the editor, so the whole run has a time budget: a
  -- slow disk or a hung repo costs file times for the rest, not minutes of freeze.
  local deadline = uv.hrtime() + budget_ms * 1e6
  local out_of_time = false
  for _, base in ipairs(base_order) do
    local group = by_base[base]
    local git, err
    if uv.hrtime() > deadline then
      if not out_of_time then
        out_of_time = true
        note(("git time budget of %d ms used up; file times used for the rest"):format(budget_ms))
      end
    else
      git, err = dater(base, group.rels, { deadline = deadline })
      if err then
        note(("%s: %s%s"):format(base, err, git and "" or " (file times used)"))
      end
    end
    local map = {}
    for _, rel in ipairs(group.rels) do
      local g = git and git[rel]
      if g then
        map[rel] = { date = g.date, file = base .. "/" .. g.file, source = "git" }
      else
        local d = mtime_day(base .. "/" .. rel)
        map[rel] = d and { date = d, file = base .. "/" .. rel, source = "mtime" } or false
      end
    end
    dated[base] = map
  end

  -- Pass 3: compare with each task's own date.
  for _, h in ipairs(hits) do
    local d = dated[h.base] and dated[h.base][h.rel]
    local since = h.task.updated or h.task.created
    if d and since and d.date > since then
      local list = report.stale[h.task.id]
      if not list then
        list = {}
        report.stale[h.task.id] = list
      end
      list[#list + 1] = { ref = h.ref, file = d.file, date = d.date, source = d.source }
    end
  end

  if report.capped > 0 then
    report.notes[#report.notes + 1] = ("%d distinct file(s) beyond the limit of %d were not checked"):format(
      report.capped,
      cap
    )
  end
  return report
end

---One line naming what changed: `lua/ai/config/init.lua (2026-10-02, git)`.
---@param changes Tasks.RefChange[]
---@param max? integer  files named before `+N more` (default 3)
---@return string
function M.describe(changes, max)
  max = max or 3
  local parts = {}
  for i, c in ipairs(changes) do
    if i > max then
      parts[#parts + 1] = ("+%d more"):format(#changes - max)
      break
    end
    parts[#parts + 1] = ("%s (%s, %s)"):format(c.ref, c.date, c.source)
  end
  return table.concat(parts, "; ")
end

return M
