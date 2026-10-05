---@module 'tasks_nvim.check'
---@brief The rule checker for the task files (concept section 9).
---@description
--- Reads the open tasks, the finished ones in `Backlog/` and the generated
--- indexes of one area or the whole vault and reports what breaks the rules.
--- Same idea as `md_lint.lua`: a finding is `<path>  <code>  <message>`, and any
--- `error` finding makes the run fail.
---
--- Findings (`code`):
---  - `frontmatter-missing`, `frontmatter-invalid`, `title-missing`,
---    `status-missing`, `field-type`: the file cannot be read as a task
---  - `unknown-status`, `unknown-kind`, `unknown-category`, `unknown-severity`,
---    `bad-prio`, `bad-effort`, `bad-date`
---  - `severity-without-bug-or-security` (warning): `severity` on a task that is
---    neither `kind: bug` nor in the bug/security category
---  - `slug`: the filename is not a kebab-case slug, or the file is nested
---    anywhere but as `<slug>/<slug>.md` (a folder task)
---  - `slug-conflict`: the same slug exists as a file and as a folder task
---  - `asset-dangling` (warning): a folder task links `assets/<file>` that is not there
---  - `index-stale`: `ROADMAP/TASKS.md` is missing, outdated, or left over
---  - `bad-blocked-by`, `blocked-by-self`, `blocked-by-dangling`: the blocker is
---    malformed, the task itself, or exists nowhere; `blocked-by-done` (warning):
---    the blocker is already finished
---  - `done-in-roadmap`: `status: done` in `ROADMAP/tasks/`
---  - `open-in-backlog`: a task file in `Backlog/` whose status is not `done`
---  - `duplicate-id`: an open task and a finished one share an id
---  - `unreadable`, `index-error`: something could not be read at all
---  - `frontmatter-warning` (warning): a frontmatter line was kept but not understood
---  - `title-comment` (warning): the title has a trailing YAML comment (` #...`)
---
--- Not its job: fixing anything (`index.write_area` regenerates an index).

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.CheckOpts
---@field root? string
---@field area? string      # Check one area (blockers are still resolved vault-wide).

---@class Tasks.CheckResult
---@field findings Tasks.Finding[]
---@field errors integer
---@field warnings integer
---@field areas integer     # Areas checked.
---@field tasks integer     # Task files read (open and finished).
---@field ok boolean        # No `error` finding.

---@param list Tasks.Finding[]
---@param severity "error"|"warn"
---@param code string
---@param task Tasks.Task|{ area: string, path: string, id?: string }
---@param message string
local function add(list, severity, code, task, message)
  list[#list + 1] = {
    code = code,
    severity = severity,
    area = task.area,
    path = task.path,
    id = task.id,
    message = message,
  }
end

---@param a Tasks.Finding
---@param b Tasks.Finding
---@return boolean
local function finding_less(a, b)
  if a.area ~= b.area then
    return a.area < b.area
  end
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.code ~= b.code then
    return a.code < b.code
  end
  return a.message < b.message
end

---Whether the file a link target names exists below `dir`. A target is a URL
---part: `assets/two%20words.png` is the file `two words.png`.
---@param dir string
---@param target string
---@return boolean
local function asset_exists(dir, target)
  -- A link that climbs out of the task's folder (`assets/../../x`, also percent-encoded) names no asset of
  -- this task: it counts as dangling without asking the file system, so a hand-edited body cannot use the
  -- check to probe which files exist elsewhere.
  local decoded = target:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if target:find("..", 1, true) or decoded:find("..", 1, true) then
    return false
  end
  if fsio.is_file(dir .. "/" .. target) then
    return true
  end
  return decoded ~= target and fsio.is_file(dir .. "/" .. decoded)
end

---Relative `assets/...` links of a folder task's body that point at no file.
---@param task Tasks.Task
---@return string[] missing
local function dangling_assets(task)
  local text = fsio.read(task.path)
  if not text then
    return {}
  end
  local dir = fsio.dirname(task.path)
  local missing, seen = {}, {}
  for target in text:gmatch("%]%((assets/[^)%s]+)%)") do
    if not seen[target] then
      seen[target] = true
      if not asset_exists(dir, target) then
        missing[#missing + 1] = target
      end
    end
  end
  return missing
end

---Run the checks.
---@param opts? Tasks.CheckOpts
---@return Tasks.CheckResult|nil result
---@return string|nil err
function M.run(opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local scan_opts = { root = root }

  local names = {}
  if opts.area then
    if not vault.has_area(root, opts.area) then
      return nil, "unknown area: " .. tostring(opts.area)
    end
    names[1] = opts.area
  else
    for _, a in ipairs(vault.areas(root)) do
      names[#names + 1] = a.name
    end
  end

  -- Blockers are resolved against every open task, whichever area is checked. Every area is scanned ONCE here
  -- and the result is reused below (the per-area checks and the index check); scanning it again for each of
  -- those parsed every open task three times (466 tasks: 410 ms instead of ~170 ms).
  local open_ids = {}
  ---@type table<string, { tasks: Tasks.Task[], errors: string[]|string|nil }>
  local by_area = {}
  for _, a in ipairs(vault.areas(root)) do
    local tasks, errs = scan.area(a.name, scan_opts)
    by_area[a.name] = { tasks = tasks or {}, errors = errs }
    for _, t in ipairs(tasks or {}) do
      open_ids[t.id] = true
    end
  end

  local findings = {}
  local task_count = 0

  for _, name in ipairs(names) do
    local scanned = by_area[name] or { tasks = {} }
    local open, walk_errors = scanned.tasks, scanned.errors
    for _, e in ipairs(type(walk_errors) == "table" and walk_errors or {}) do
      add(findings, "error", "unreadable", { area = name, path = vault.tasks_dir(root, name) }, e)
    end
    local finished, backlog_errors = scan.backlog(name, scan_opts)
    finished = finished or {}
    -- A Backlog that could not be read is reported: without it `duplicate-id` stays silent and a blocker that
    -- was finished looks dangling.
    for _, e in ipairs(type(backlog_errors) == "table" and backlog_errors or {}) do
      add(
        findings,
        "error",
        "unreadable",
        { area = name, path = vault.backlog_dir(root, name, "TASKS") },
        e
      )
    end
    local finished_ids = {}
    for _, t in ipairs(finished) do
      finished_ids[t.id] = t
    end
    task_count = task_count + #open + #finished

    local seen_slug = {}
    for _, t in ipairs(open) do
      if seen_slug[t.id] then
        add(
          findings,
          "error",
          "slug-conflict",
          t,
          "the same slug exists as a file and as a folder task: " .. seen_slug[t.id]
        )
      end
      seen_slug[t.id] = t.path
      if t.folder then
        for _, target in ipairs(dangling_assets(t)) do
          add(findings, "warn", "asset-dangling", t, "linked asset is missing: " .. target)
        end
      end
      for i, msg in ipairs(t.errors) do
        add(findings, "error", t.error_codes[i] or "frontmatter-invalid", t, msg)
      end
      for _, w in ipairs(t.warnings) do
        add(findings, "warn", "frontmatter-warning", t, "line kept but not understood: " .. w)
      end
      for _, h in ipairs(t.hints or {}) do
        add(findings, "warn", h.code, t, h.msg)
      end
      if t.status == "done" then
        add(
          findings,
          "error",
          "done-in-roadmap",
          t,
          "status is done but the file is still in ROADMAP/tasks/ (tasks done moves it)"
        )
      end
      if finished_ids[t.id] then
        add(
          findings,
          "error",
          "duplicate-id",
          t,
          "a finished task with this id exists: " .. finished_ids[t.id].path
        )
      end
      for _, ref in ipairs(t.blocked_by) do
        local _, ref_slug = vault.parse_id(ref)
        if ref_slug then
          if ref == t.id then
            add(findings, "error", "blocked-by-self", t, "blocked_by names the task itself")
          elseif not open_ids[ref] then
            if scan.find_done(ref, scan_opts) then
              add(
                findings,
                "warn",
                "blocked-by-done",
                t,
                "blocked_by " .. ref .. " is already finished"
              )
            else
              add(
                findings,
                "error",
                "blocked-by-dangling",
                t,
                "blocked_by " .. ref .. " does not exist"
              )
            end
          end
        end
      end
    end

    for _, t in ipairs(finished) do
      if t.status ~= "done" then
        add(
          findings,
          "error",
          "open-in-backlog",
          t,
          ("status is '%s' but the file is in Backlog/ (only done belongs there)"):format(
            tostring(t.status)
          )
        )
      end
    end

    local res, ierr = index.write_area(name, { root = root, check = true, scanned = scanned })
    local index_target = { area = name, path = vault.index_path(root, name) }
    if not res then
      add(findings, "error", "index-error", index_target, tostring(ierr))
    elseif res.action == "stale" then
      local why = {
        missing = "ROADMAP/TASKS.md is missing although tasks are open",
        outdated = "ROADMAP/TASKS.md is out of date",
        orphan = "ROADMAP/TASKS.md exists although no task is open",
      }
      add(
        findings,
        "error",
        "index-stale",
        index_target,
        (why[res.reason] or "ROADMAP/TASKS.md is stale") .. " (tasks index regenerates it)"
      )
    end
  end

  table.sort(findings, finding_less)
  local errors, warnings = 0, 0
  for _, f in ipairs(findings) do
    if f.severity == "error" then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end
  return {
    findings = findings,
    errors = errors,
    warnings = warnings,
    areas = #names,
    tasks = task_count,
    ok = errors == 0,
  },
    nil
end

---`<path relative to the vault>  <code>  <message>`, forward slashes.
---@param finding Tasks.Finding
---@param root string
---@return string
function M.format(finding, root)
  local rel = fsio.norm(finding.path)
  if rel:sub(1, #root + 1) == root .. "/" then
    rel = rel:sub(#root + 2)
  end
  local tag = finding.severity == "warn" and "warn " or ""
  -- The message and the path carry text from the files (a status, a ref, a file
  -- name): a control character in them must not reach the terminal.
  return fsio.clean(("%s  %s%s  %s"):format(rel, tag, finding.code, finding.message))
end

return M
