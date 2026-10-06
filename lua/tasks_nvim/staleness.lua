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
---@field file string     # The file that changed (inside a directory ref: the file in it), forward slashes; empty when unverified.
---@field date string     # `YYYY-MM-DD` of the change.
---@field source "git"|"mtime"|"unverified"  # `unverified`: the check itself failed (see `model.filter`).

---@class Tasks.StalenessReport
---@field stale table<string, Tasks.RefChange[]>  # Task id -> what changed.
---@field tasks integer       # Tasks that carry at least one checkable ref.
---@field files integer       # Distinct files dated.
---@field unresolved integer  # Path refs found in no base.
---@field skipped integer     # Refs that are no paths (commits, URLs, anchors) or tasks without a date.
---@field capped integer      # Distinct files beyond `MAX_REFS`, not looked at.
---@field notes string[]      # Human remarks (a base that is no git repo, the cap, a failed git call).

---@alias Tasks.GitDater fun(base: string, rels: string[], gopts?: Tasks.GitDatesOpts): table<string, { date: string, file: string }>|nil, string|nil

---@class Tasks.StalenessOpts
---@field root? string                # Vault root (default: `vault.root()`).
---@field repo_bases? string[]        # Folders that hold the repos by name (`<base>/<area>`); default: derived from the vault and `$REPOS_DIR`.
---@field config_dir? string          # The nvim config checkout (default: `$NVIM_CONFIG_DIR`, else `stdpath("config")`).
---@field extra_bases? string[]       # More bases tried after the standard ones.
---@field max_refs? integer
---@field budget_ms? integer          # Time all git calls may take together (default `staleness.budget_ms` of `setup()`).
---@field git_dates? Tasks.GitDater   # Replaces the git lookup (specs).

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
  -- The colon of a drive letter is no separator; the rest of the ref is read on its own.
  local drive, body = s:match("^(%a:)([/\\].*)$")
  local rest = body or s
  if rest:find(":", 1, true) then
    -- `file.lua:42`, `file.lua:42:7`, `file.lua:10-20`: a path with a position.
    local stripped = rest:match("^(.-):%d+:%d+$")
      or rest:match("^(.-):%d+%-%d+$")
      or rest:match("^(.-):%d+$")
    if stripped and not stripped:find(":", 1, true) then
      s = (drive or "") .. stripped
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
  return (
    os.date("%Y-%m-%d", ts) --[[@as string|nil]]
  ) or "0000-00-00"
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

---The environment of every git call: the messages are English, so that "not a git repository" is recognised whatever
---the user's locale is.
local GIT_ENV = { LC_ALL = "C" }

---Whether git can answer about `base` AT ALL: one call without a pathspec, decided by its exit code (never by the text
---of a message, which is localised). When this fails, every path lookup would fail too: bisecting a failing chunk
---down to single paths would cost 2n-1 spawns for nothing.
---@param base string
---@param timeout_ms integer
---@return boolean
local function repo_answers(base, timeout_ms)
  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", base, "log", "-1", "--format=%ct" }, { text = true, env = GIT_ENV })
      :wait(timeout_ms)
  end)
  return ok and res.code == 0
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
    return vim.system(cmd, { text = true, env = GIT_ENV }):wait(timeout_ms)
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
    elseif not repo_answers(base, timeout) then
      -- not one path git refuses: git cannot be used on this repo at all (broken config, no commit, dubious owner)
      stopped, failed = true, failed + #paths
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

---@type fun(opts: Tasks.StalenessOpts, root: string): { repo_bases: string[], config_dir: string|nil, root: string, extra: string[] }
local make_ctx

---The date a task without `updated` and `created` is compared from: before every real day.
local UNDATED = "0000-00-00"

---What pass 1 found: the files to date, grouped by the folder they are looked up in, and the refs that point at them.
---@class Tasks.RefHits
---@field by_base table<string, { rels: string[], seen: table<string, boolean> }>
---@field base_order string[]
---@field hits { task: Tasks.Task, ref: string, base: string, rel: string, full: string }[]
---@field tasks integer       # Tasks with at least one checkable ref.
---@field files integer       # Distinct files.

---Where `rel` lives for a task of `area`: the base it was found in, the full path and the path relative to that base.
---`..` segments are resolved against the folder the file really lives in (git refuses a pathspec outside its work tree,
---for the whole call).
---@param rel string
---@param bases string[]
---@return string|nil base
---@return string|nil full
---@return string|nil rel
local function locate(rel, bases)
  if is_absolute(rel) then
    if uv.fs_stat(rel) then
      return fsio.dirname(rel), rel, rel:match("([^/]+)$") or rel
    end
    return nil, nil, nil
  end
  for _, base in ipairs(bases) do
    local full = base .. "/" .. rel
    if uv.fs_stat(full) then
      if not has_dotdot(rel) then
        return base, full, rel
      end
      -- `../lib.nvim/lua/x.lua` leaves the repo it was found in: date the file from the folder it really lives in.
      full = collapse_dots(full)
      if full:sub(1, #base + 1) == base .. "/" then
        return base, full, full:sub(#base + 2)
      end
      return fsio.dirname(full), full, full:match("([^/]+)$") or full
    end
  end
  return nil, nil, nil
end

---Pass 1: resolve every checkable ref to (base, rel); group the distinct files by base. Counts into `report`
---(`skipped`, `unresolved`, `capped`, `tasks`, `files`).
---@param tasks Tasks.Task[]
---@param ctx { repo_bases: string[], config_dir: string|nil, root: string, extra: string[] }
---@param cap integer
---@param report Tasks.StalenessReport
---@return Tasks.RefHits
local function resolve_refs(tasks, ctx, cap, report)
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

  ---@type Tasks.RefHits
  local found = { by_base = {}, base_order = {}, hits = {}, tasks = 0, files = 0 }
  local distinct, over_cap, with_refs = {}, {}, {}
  for _, t in ipairs(tasks) do
    for _, ref in ipairs(t.refs or {}) do
      local kind, rel = M.classify(ref)
      if kind ~= "path" or not rel then
        report.skipped = report.skipped + 1
      else
        local base, full, base_rel = locate(rel, bases_of(t.area))
        if not base or not full or not base_rel then
          report.unresolved = report.unresolved + 1
        else
          local key = base .. "\0" .. base_rel
          local counted_here = true
          if not distinct[key] then
            if found.files >= cap then
              if not over_cap[key] then
                over_cap[key] = true
                report.capped = report.capped + 1
              end
              counted_here = false
            else
              distinct[key] = true
              found.files = found.files + 1
              local group = found.by_base[base]
              if not group then
                group = { rels = {}, seen = {} }
                found.by_base[base] = group
                found.base_order[#found.base_order + 1] = base
              end
              group.rels[#group.rels + 1] = base_rel
              group.seen[base_rel] = true
            end
          end
          if counted_here then
            found.hits[#found.hits + 1] =
              { task = t, ref = ref, base = base, rel = base_rel, full = full }
            if not with_refs[t.id] then
              with_refs[t.id] = true
              found.tasks = found.tasks + 1
            end
          end
        end
      end
    end
  end
  return found
end

---@alias Tasks.FileDate { date: string, file: string, source: "git"|"mtime" }

---Pass 2: date the files, one git lookup per base. Every git call blocks the editor, so the whole run has a time
---budget: a slow disk or a hung repo costs file times for the rest, not minutes of freeze.
---@param found Tasks.RefHits
---@param dater Tasks.GitDater
---@param budget_ms integer
---@param note fun(text: string)
---@return table<string, table<string, Tasks.FileDate|false>> dated  # base -> rel -> date (`false`: not even an mtime)
local function date_files(found, dater, budget_ms, note)
  ---@type table<string, table<string, Tasks.FileDate|false>>
  local dated = {}
  local deadline = uv.hrtime() + budget_ms * 1e6
  local out_of_time = false
  for _, base in ipairs(found.base_order) do
    local group = found.by_base[base]
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
  return dated
end

---Pass 3: compare each ref's file date with its task's own date; the changes go to `report.stale`.
---@param hits { task: Tasks.Task, ref: string, base: string, rel: string }[]  # `Tasks.RefHits.hits`
---@param dated table<string, table<string, Tasks.FileDate|false>>
---@param report Tasks.StalenessReport
local function compare(hits, dated, report)
  for _, h in ipairs(hits) do
    local d = dated[h.base] and dated[h.base][h.rel]
    -- A task with neither `updated` nor `created` has no date to compare with: every dated change counts, the same
    -- way `--stale=<days>` counts a task without a date as stale (an unknowable answer is not "fresh").
    -- An invalid date ("2026-9-3") is no date: it is compared as UNDATED, as `--stale=<days>` counts it as unknowable
    -- (text comparison would put "2026-9-3" after "2026-10-01").
    local last = h.task.updated or h.task.created
    local since = require("tasks_nvim.model").is_date(last) and last or UNDATED
    if d and d.date > since then
      local list = report.stale[h.task.id]
      if not list then
        list = {}
        report.stale[h.task.id] = list
      end
      list[#list + 1] = { ref = h.ref, file = d.file, date = d.date, source = d.source }
    end
  end
end

---@param opts Tasks.StalenessOpts
---@param root string
---@return { repo_bases: string[], config_dir: string|nil, root: string, extra: string[] }
function make_ctx(opts, root)
  return {
    root = root,
    repo_bases = opts.repo_bases
      or (#settings().repo_bases > 0 and settings().repo_bases or default_repo_bases(root)),
    config_dir = default_config_dir(opts),
    extra = opts.extra_bases or {},
  }
end

---Which FILE a ref of a task means, as a key two refs share exactly when they name one file. A relative ref is
---looked for where `compute` looks (`<repo base>/<area>`, the config checkout, the vault, ...), so `README.md` of two
---repos are two files and `docs/ROADMAP/00_ROADMAP.md` found through the config checkout is one. A ref that resolves to
---nothing is keyed by its area and path (a file of that repo that is not there). Remembered per (area, ref).
---@param opts? Tasks.StalenessOpts
---@return (fun(task: Tasks.Task, rel: string): string)|nil resolver  # nil when there is no vault
function M.file_key(opts)
  opts = opts or {}
  local root = opts.root and fsio.norm(opts.root) or vault.root()
  if not root then
    return nil
  end
  local ctx = make_ctx(opts, root)
  local bases_of_area, memo = {}, {}
  return function(task, rel)
    local memo_key = task.area .. "\0" .. rel
    local hit = memo[memo_key]
    if hit then
      return hit
    end
    local bases = bases_of_area[task.area]
    if not bases then
      bases = bases_for(task.area, ctx)
      bases_of_area[task.area] = bases
    end
    local _, full = locate(rel, bases)
    local key = full and collapse_dots(full)
      or (is_absolute(rel) and rel)
      or (task.area .. "/" .. rel)
    if require("lib.nvim.cross.platform.is_windows")() then
      key = key:lower()
    end
    memo[memo_key] = key
    return key
  end
end

---Check the refs of `tasks` against the file system and git: resolve (pass 1), date (pass 2), compare (pass 3).
---@param tasks Tasks.Task[]
---@param opts? Tasks.StalenessOpts
---@return Tasks.StalenessReport report
function M.compute(tasks, opts)
  opts = opts or {}
  ---@type Tasks.StalenessReport
  local report =
    { stale = {}, tasks = 0, files = 0, unresolved = 0, skipped = 0, capped = 0, notes = {} }

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
  local ctx = make_ctx(opts, root)
  local cap = opts.max_refs or M.MAX_REFS
  ---@param text string
  local function note(text)
    report.notes[#report.notes + 1] = text
  end

  local found = resolve_refs(tasks, ctx, cap, report)
  report.tasks = found.tasks
  report.files = found.files
  local dated =
    date_files(found, opts.git_dates or M.git_dates, opts.budget_ms or settings().budget_ms, note)
  compare(found.hits, dated, report)

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
