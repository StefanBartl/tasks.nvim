---@module 'tasks_nvim.model'
---@brief The task record: read one file, validate it, rank and filter lists of them.
---@description
--- A task is one Markdown file with flat-YAML frontmatter (concept section 3).
--- `parse_text` / `from_file` turn it into a `Tasks.Task` -- always, even for a
--- broken file: the problems go into `errors` and `valid` is false, so one bad
--- file can never hide the rest. The frontmatter itself is read by
--- `lib.nvim.markdown.frontmatter`; this module only interprets the fields.
---
--- Key responsibilities:
---  - the enums (status, kind, prio, effort) and the date check
---  - `summary`: frontmatter `summary`, else the first body paragraph
---  - `compare` / `sort`: status rank, then prio, then area, then slug; the orders
---    `prio-effort` (small first within a prio), `severity` (critical first) and
---    `frecency` (what the dashboard touches most, from `tasks.frecency`)
---  - `filter`: status, prio, effort, kind, tag, category, severity, area, blocked, stale
---
--- Not its job: finding files (`scan`), rendering (`index`), writing (`mutate`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local steps = require("tasks_nvim.steps")
local vault = require("tasks_nvim.vault")

local M = {}

---Status words in rank order: the order tasks are listed in.
---@type Tasks.Status[]
M.STATUSES = { "doing", "decision", "blocked", "open", "parked", "done" }

---The statuses an open task may have (everything but `done`).
---@type Tasks.Status[]
M.OPEN_STATUSES = { "doing", "decision", "blocked", "open", "parked" }

---@type Tasks.Kind[]
M.KINDS = { "feature", "task", "bug", "idea", "research" }

---Concerns a task can serve (concept section 12.1). Independent of `kind`:
---`kind: bug` implies `bug`, a tag of the same name counts as well.
---@type string[]
M.CATEGORIES = { "bug", "security", "performance", "docs", "ruleset" }

---Severity of a bug or security task, worst last. Optional, see `model.categories`.
---@type string[]
M.SEVERITIES = { "low", "medium", "high", "critical" }

---The listing orders `sort` knows. `default` is what the index uses.
---@type string[]
M.SORTS = { "default", "prio-effort", "severity", "frecency", "roi" }

---@type integer[]
M.PRIOS = { 1, 2, 3 }

---Expected benefit of a task, 5 = the most. Not `prio` (the order decision, set by the human): the benefit does not
---depend on the time, so a high value may sit in a low prio for now.
---@type integer[]
M.VALUES = { 1, 2, 3, 4, 5 }

---Who can do a task: `cdx` an AI session alone, `me` only the human, `pair` the AI drafts and the human decides the
---rest. A task without the field is "unclear" (see `model.actor` for what is derived).
---@type string[]
M.ACTORS = { "cdx", "me", "pair" }

---@type string[]
M.EFFORTS = { "XS", "S", "M", "L", "XL" }

---@type table<string, integer>
local STATUS_RANK = {}
for i, s in ipairs(M.STATUSES) do
  STATUS_RANK[s] = i
end

---@type table<string, boolean>
local KIND_SET = {}
for _, k in ipairs(M.KINDS) do
  KIND_SET[k] = true
end

---@type table<string, boolean>
local CATEGORY_SET = {}
for _, c in ipairs(M.CATEGORIES) do
  CATEGORY_SET[c] = true
end

---@type table<string, integer>
local SEVERITY_RANK = {}
for i, v in ipairs(M.SEVERITIES) do
  SEVERITY_RANK[v] = i
end

---Day equivalents of the size words; only used to put sizes and day values
---(`3d`) on one scale for ordering and `<=` filters, not a promise.
---@type table<string, number>
local EFFORT_DAYS = { XS = 0.25, S = 0.5, M = 1, L = 3, XL = 5 }

---@type table<string, boolean>
local EFFORT_SET = {}
for _, e in ipairs(M.EFFORTS) do
  EFFORT_SET[e] = true
end

---Sorts after prio 3: a task without a (valid) prio is the least urgent.
local NO_PRIO_RANK = 4

---@param s any
---@return boolean
function M.is_status(s)
  return type(s) == "string" and STATUS_RANK[s] ~= nil
end

---@param s any
---@return boolean
function M.is_open_status(s)
  return type(s) == "string" and STATUS_RANK[s] ~= nil and s ~= "done"
end

---@param s any
---@return boolean
function M.is_kind(s)
  return type(s) == "string" and KIND_SET[s] == true
end

---@param s any
---@return boolean
function M.is_category(s)
  return type(s) == "string" and CATEGORY_SET[s] == true
end

---The categories a task counts for: its `category` list, `bug` when `kind` is
---`bug`, and every tag that is spelled like a category. In `CATEGORIES` order.
---@param task { category?: string[], kind?: string, tags?: string[] }
---@return string[]
function M.categories(task)
  local have = {}
  for _, c in ipairs(task.category or {}) do
    have[c] = true
  end
  if task.kind == "bug" then
    have.bug = true
  end
  for _, tag in ipairs(task.tags or {}) do
    if CATEGORY_SET[tag] then
      have[tag] = true
    end
  end
  local out = {}
  for _, c in ipairs(M.CATEGORIES) do
    if have[c] then
      out[#out + 1] = c
    end
  end
  return out
end

---@param s any
---@return boolean
function M.is_severity(s)
  return type(s) == "string" and SEVERITY_RANK[s] ~= nil
end

---`XS`..`XL`, or days: `3d`, `0.5d`.
---@param s any
---@return boolean
function M.is_effort(s)
  if type(s) ~= "string" then
    return false
  end
  return EFFORT_SET[s] == true or s:match("^%d+d$") ~= nil or s:match("^%d*%.%d+d$") ~= nil
end

---Where an effort value sits on the common scale (see `EFFORT_DAYS`).
---@param effort any
---@return number|nil days  nil when `effort` is missing or not a valid effort
function M.effort_days(effort)
  if not M.is_effort(effort) then
    return nil
  end
  if EFFORT_DAYS[effort] then
    return EFFORT_DAYS[effort]
  end
  return tonumber((effort:gsub("d$", "")))
end

---@param s any
---@return integer|nil prio  1..3, or nil when `s` is no valid prio
function M.to_prio(s)
  if type(s) == "number" then
    s = tostring(s)
  end
  if type(s) == "string" and s:match("^[123]$") then
    return tonumber(s)
  end
  return nil
end

---@param s any
---@return integer|nil value  1..5, or nil when `s` is no valid value
function M.to_value(s)
  if type(s) == "number" then
    s = tostring(s)
  end
  if type(s) == "string" and s:match("^[1-5]$") then
    return tonumber(s)
  end
  return nil
end

---@param s any
---@return boolean
function M.is_actor(s)
  for _, a in ipairs(M.ACTORS) do
    if a == s then
      return true
    end
  end
  return false
end

---Who does the task: the written `actor`; else `me` for a task that waits for a decision (`status: decision`) or
---carries the tag `needs-user`; else `nil` ("unclear"). Like `categories`, this makes the existing vault filterable
---without touching a file.
---@param task Tasks.Task
---@return string|nil actor
function M.actor(task)
  if task.actor and M.is_actor(task.actor) then
    return task.actor
  end
  if task.status == "decision" then
    return "me"
  end
  for _, tag in ipairs(task.tags or {}) do
    if tag == "needs-user" then
      return "me"
    end
  end
  return nil
end

---Smallest effort a return-on-effort figure divides by (a task is never "free").
local ROI_MIN_DAYS = 0.25

---`value / max(effort_days, 0.25)`; `nil` when the task has no value or no (valid) effort. Derived, never stored; a
---task without an estimate has NO figure (not 0), so it cannot look worse or better than it is.
---@param task Tasks.Task
---@return number|nil roi
function M.roi(task)
  local days = M.effort_days(task.effort)
  if not task.value or not days then
    return nil
  end
  return task.value / math.max(days, ROI_MIN_DAYS)
end

---@param y integer
---@param m integer
---@return integer
local function days_in_month(y, m)
  if m == 2 then
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    return leap and 29 or 28
  end
  return (m == 4 or m == 6 or m == 9 or m == 11) and 30 or 31
end

---`YYYY-MM-DD` that is a real calendar date.
---@param s any
---@return boolean
function M.is_date(s)
  if type(s) ~= "string" then
    return false
  end
  local ys, ms, ds = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not ys then
    return false
  end
  local y = tonumber(ys) --[[@as integer]]
  local m = tonumber(ms) --[[@as integer]]
  local d = tonumber(ds) --[[@as integer]]
  return m >= 1 and m <= 12 and d >= 1 and d <= days_in_month(y, m)
end

---Days since 1970-01-01 of a valid `YYYY-MM-DD` (proleptic Gregorian).
---@param s string
---@return integer
local function day_number(s)
  local y, m, d = s:match("^(%d+)-(%d+)-(%d+)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---Whole days from date `a` to date `b` (positive when `b` is later).
---@param a string
---@param b string
---@return integer|nil days  nil when either is not a valid date
function M.days_between(a, b)
  if not (M.is_date(a) and M.is_date(b)) then
    return nil
  end
  return day_number(b) - day_number(a)
end

---Today as `YYYY-MM-DD` (local time).
---@return string
function M.today()
  return os.date("%Y-%m-%d") --[[@as string]]
end

local trim = fsio.trim

---The first paragraph of a body: consecutive text lines, skipping blank lines,
---headings, single-line HTML comments and fenced code. Whitespace is collapsed.
---@param body string
---@return string
function M.first_paragraph(body)
  local para = {}
  local in_fence = false
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local t = trim(line)
    if t:match("^```") or t:match("^~~~") then
      in_fence = not in_fence
      if #para > 0 then
        break
      end
    elseif in_fence then
      if #para > 0 then
        break
      end
    elseif t == "" or t:match("^#+%s") or t:match("^<!%-%-.*%-%->$") then
      if #para > 0 then
        break
      end
    else
      para[#para + 1] = t
    end
  end
  return (fsio.clean(table.concat(para, " ")):gsub("%s+", " "))
end

---@param value any
---@param field string
---@param bad fun(code: string, msg: string)
---@return string|nil
local function as_text(value, field, bad)
  if value == nil then
    return nil
  end
  if type(value) ~= "string" then
    bad("field-type", field .. " must be text")
    return nil
  end
  local t = trim(fsio.clean(value))
  return t ~= "" and t or nil
end

---A scalar counts as a one-element list.
---@param value any
---@param field string
---@param bad fun(code: string, msg: string)
---@return string[]
local function as_list(value, field, bad)
  if value == nil then
    return {}
  end
  if type(value) == "string" then
    local t = trim(fsio.clean(value))
    return t ~= "" and { t } or {}
  end
  if type(value) == "table" then
    local out = {}
    for _, item in ipairs(value) do
      local t = type(item) == "string" and trim(fsio.clean(item)) or ""
      if t ~= "" then
        out[#out + 1] = t
      end
    end
    return out
  end
  bad("field-type", field .. " must be a list")
  return {}
end

---The slug of a task file: the filename without `.md`, and without the
---`YYYY-MM-DD_` prefix `done` gives files in `Backlog/`.
---@param path string
---@param location Tasks.Location
---@return string
function M.slug_of(path, location)
  local name = fsio.norm(path):match("([^/]*)$") or path
  name = name:gsub("%.md$", "")
  if location == "backlog" then
    name = name:gsub("^%d%d%d%d%-%d%d%-%d%d_", "")
  end
  return name
end

---Interpret the text of a task file.
---
---`ctx.path` and `ctx.area` are required; `ctx.location` defaults to
---`"roadmap"`; `ctx.slug` defaults to the one derived from the filename.
---Never raises on bad content.
---@param text string
---@param ctx { path: string, area: string, location?: Tasks.Location, slug?: string, nested?: boolean, folder?: boolean }
---@return Tasks.Task
function M.parse_text(text, ctx)
  local location = ctx.location or "roadmap"
  local slug = ctx.slug or M.slug_of(ctx.path, location)
  local errors, codes, warnings, hints = {}, {}, {}, {}

  ---@param code string
  ---@param msg string
  local function bad(code, msg)
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end

  ---@type Tasks.Task
  local task = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    location = location,
    folder = ctx.folder == true,
    title = slug,
    tags = {},
    category = {},
    blocked_by = {},
    after = {},
    refs = {},
    summary = "",
    meta = {},
    errors = errors,
    error_codes = codes,
    warnings = warnings,
    hints = hints,
    valid = false,
  }

  if not vault.valid_slug(slug) then
    bad("slug", "filename is not a kebab-case ASCII slug: " .. fsio.clean(slug))
  end
  if ctx.nested then
    bad(
      "slug",
      "task file must lie directly in tasks/ or be <slug>/<slug>.md, not in another subfolder"
    )
  end

  local parsed, perr = fm.parse(text)
  if not parsed then
    bad("frontmatter-missing", "frontmatter unreadable: " .. tostring(perr))
  elseif not parsed.has_block then
    if parsed.unterminated then
      bad("frontmatter-missing", "frontmatter block is never closed (no closing ---)")
    else
      bad("frontmatter-missing", "no frontmatter block")
    end
  else
    local meta = parsed.meta
    task.meta = meta
    for _, w in ipairs(parsed.warnings) do
      -- A key with an unsupported value is already an error below; its warning would only say the
      -- same thing twice. The key is read out of the warning (`... key 'k' ...`) and looked up: a loop
      -- over all opaque keys per warning is quadratic, 10 000 of them froze the editor for 7 s (SEC-32).
      local named = w:match("key '([^']*)'")
      local repeated = named ~= nil and parsed.opaque[named] ~= nil
      if not repeated then
        warnings[#warnings + 1] = w
      end
    end
    for key, reason in pairs(parsed.opaque) do
      bad("frontmatter-invalid", ("%s: unsupported value (%s)"):format(key, reason))
    end

    local title = as_text(meta.title, "title", bad)
    if title then
      task.title = title
      local tentry = parsed.by_key.title
      -- A quoted title ends at its closing quote, so a comment after it is a real comment.
      local quoted = tentry and tentry.raw:match("^[^:]*:%s*[\"']") ~= nil
      if tentry and tentry.comment and not quoted then
        -- `title: Fix bug #12` reads "Fix bug": a ` #` starts a YAML comment.
        hints[#hints + 1] = {
          code = "title-comment",
          msg = ("title ends at ' #' (the rest is a YAML comment: '%s'); quote the title if the # belongs to it"):format(
            vim.trim(tentry.comment)
          ),
        }
      end
    elseif meta.title == nil then
      bad("title-missing", "title is missing")
    else
      bad("title-missing", "title is empty")
    end

    local status = as_text(meta.status, "status", bad)
    if status then
      task.status = status
      if not M.is_status(status) then
        bad(
          "unknown-status",
          ("unknown status '%s' (expected %s)"):format(status, table.concat(M.STATUSES, ", "))
        )
      end
    elseif meta.status == nil then
      bad("status-missing", "status is missing")
    end

    local kind = as_text(meta.kind, "kind", bad)
    if kind then
      task.kind = kind
      if not M.is_kind(kind) then
        bad(
          "unknown-kind",
          ("unknown kind '%s' (expected %s)"):format(kind, table.concat(M.KINDS, ", "))
        )
      end
    end

    if meta.prio ~= nil then
      local prio = M.to_prio(meta.prio)
      if prio then
        task.prio = prio
      else
        bad("bad-prio", "prio must be 1, 2 or 3, got " .. vim.inspect(meta.prio))
      end
    end

    if meta.value ~= nil then
      local value = M.to_value(meta.value)
      if value then
        task.value = value
      else
        bad("bad-value", "value must be 1, 2, 3, 4 or 5, got " .. vim.inspect(meta.value))
      end
    end

    local actor = as_text(meta.actor, "actor", bad)
    if actor then
      task.actor = actor
      if not M.is_actor(actor) then
        bad(
          "bad-actor",
          ("unknown actor '%s' (expected %s)"):format(actor, table.concat(M.ACTORS, ", "))
        )
      end
    end

    local effort = as_text(meta.effort, "effort", bad)
    if effort then
      task.effort = effort
      if not M.is_effort(effort) then
        bad("bad-effort", ("effort '%s' is neither XS..XL nor days like 0.5d"):format(effort))
      end
    end

    task.tags = as_list(meta.tags, "tags", bad)
    task.refs = as_list(meta.refs, "refs", bad)
    task.category = as_list(meta.category, "category", bad)
    for _, c in ipairs(task.category) do
      if not M.is_category(c) then
        bad(
          "unknown-category",
          ("unknown category '%s' (expected %s)"):format(c, table.concat(M.CATEGORIES, ", "))
        )
      end
    end

    local severity = as_text(meta.severity, "severity", bad)
    if severity then
      task.severity = severity
      if not M.is_severity(severity) then
        bad(
          "unknown-severity",
          ("unknown severity '%s' (expected %s)"):format(severity, table.concat(M.SEVERITIES, ", "))
        )
      else
        local cats = {}
        for _, c in ipairs(M.categories(task)) do
          cats[c] = true
        end
        if not (cats.bug or cats.security) then
          hints[#hints + 1] = {
            code = "severity-without-bug-or-security",
            msg = "severity is meant for bug or security tasks (kind: bug, or category bug/security)",
          }
        end
      end
    end

    for _, field in ipairs({ "created", "updated" }) do
      local date = as_text(meta[field], field, bad)
      if date then
        task[field] = date
        if not M.is_date(date) then
          bad("bad-date", ("%s '%s' is not a date (YYYY-MM-DD)"):format(field, date))
        end
      end
    end

    task.blocked_by = as_list(meta.blocked_by, "blocked_by", bad)
    for _, ref in ipairs(task.blocked_by) do
      local _, ref_slug, id_err = vault.parse_id(ref)
      if id_err or not ref_slug then
        bad("bad-blocked-by", "blocked_by: " .. (id_err or ("expected <area>/<slug>, got " .. ref)))
      end
    end

    task.after = as_list(meta.after, "after", bad)
    for _, ref in ipairs(task.after) do
      local _, ref_slug, id_err = vault.parse_id(ref)
      if id_err or not ref_slug then
        bad("bad-after", "after: " .. (id_err or ("expected <area>/<slug>, got " .. ref)))
      end
    end
    if meta.order ~= nil then
      local n = tonumber(meta.order)
      if n and n == n and n > -math.huge and n < math.huge then
        task.order = n
      else
        bad(
          "bad-order",
          "order must be a number (2.5 slots a task between 2 and 3), got "
            .. vim.inspect(meta.order)
        )
      end
    end

    local plan_ref = as_text(meta.plan, "plan", bad)
    if plan_ref then
      local _, plan_slug, plan_err = vault.parse_id(plan_ref)
      if plan_err or not plan_slug then
        bad("bad-plan", "plan: " .. (plan_err or ("expected <area>/<slug>, got " .. plan_ref)))
      else
        task.plan = plan_ref
      end
    end
    local phase = as_text(meta.phase, "phase", bad)
    if phase then
      if vault.valid_slug(phase) then
        task.phase = phase
      else
        bad("bad-phase", "phase must be a kebab-case word, got '" .. phase .. "'")
      end
    end

    if type(meta.done_in) == "table" then
      task.done_in = table.concat(as_list(meta.done_in, "done_in", bad), ", ")
    else
      task.done_in = as_text(meta.done_in, "done_in", bad)
    end

    task.summary = as_text(meta.summary, "summary", bad) or M.first_paragraph(parsed.body)

    -- The optional `## Plan` section: progress only. A task without it is complete, nothing is said about it.
    task.plan_steps = steps.parse(parsed.body)
    if task.plan_steps then
      local uncovered = steps.uncovered_acceptance(parsed.body)
      if #uncovered > 0 then
        hints[#hints + 1] = {
          code = "plan-acceptance-uncovered",
          msg = ("acceptance point(s) %s are covered by no step of the plan (-- Acceptance n)"):format(
            table.concat(uncovered, ", ")
          ),
        }
      end
    end
  end

  task.valid = #errors == 0
  return task
end

---Read a frontmatter value as one trimmed line of text (`nil` when absent or empty; a wrong type is reported
---through `bad`). Shared with the plan files (`tasks_nvim.plans`).
---@param value any
---@param field string
---@param bad fun(code: string, msg: string)
---@return string|nil
function M.field_text(value, field, bad)
  return as_text(value, field, bad)
end

---Read a frontmatter value as a list of trimmed strings (a single string is a list of one). Shared with the plan
---files.
---@param value any
---@param field string
---@param bad fun(code: string, msg: string)
---@return string[]
function M.field_list(value, field, bad)
  return as_list(value, field, bad)
end

---Parsed files by path: `{ sec, nsec, size, ctx, task }`. A file is parsed again when its mtime, size or the way
---it is read (`ctx`) changed.
---@type table<string, { sec: integer, nsec: integer, size: integer, ctx: string, task: Tasks.Task }>
local parsed = {}
local parsed_count = 0

---Entries kept at most; the table is dropped when it overflows (it refills on the next scan).
local PARSED_MAX = 5000

---A file this young may still change within the timestamp's resolution (FAT: 2 s) without its mtime moving, so
---it is never trusted from the cache (the same rule git applies to "racily clean" files).
local RACY_SECONDS = 2

---Forget every parsed file (specs that rewrite a file within the racy window need no call: such files are not cached).
function M.reset_parse_cache()
  parsed, parsed_count = {}, 0
end

---@param ctx table
---@return string
local function ctx_key(ctx)
  return table.concat({
    ctx.area or "",
    ctx.location or "",
    ctx.slug or "",
    ctx.nested and "n" or "-",
    ctx.folder and "f" or "-",
  }, "\0")
end

---Read and interpret one task file. An unreadable file yields an invalid task
---carrying the read error, never a raise. A file whose mtime and size did not change since the last call is not read
---and parsed again: the previous result is returned as a fresh copy (a scan of the vault is mostly unchanged files).
---@param path string
---@param ctx { area: string, location?: Tasks.Location, slug?: string, nested?: boolean, folder?: boolean }
---@return Tasks.Task
function M.from_file(path, ctx)
  local uv = vim.uv or vim.loop
  local key = ctx_key(ctx)
  local st = uv.fs_stat(path)
  local mtime = st and st.mtime
  if st and mtime and st.type == "file" then
    local hit = parsed[path]
    if
      hit
      and hit.sec == mtime.sec
      and hit.nsec == mtime.nsec
      and hit.size == st.size
      and hit.ctx == key
    then
      return vim.deepcopy(hit.task)
    end
  end
  local full = vim.tbl_extend("force", { path = path }, ctx)
  local text, err = fsio.read(path)
  if not text then
    local task = M.parse_text("", full)
    task.errors = { "cannot read file: " .. tostring(err) }
    task.error_codes = { "unreadable" }
    task.valid = false
    return task
  end
  local task = M.parse_text(text, full)
  if st and mtime and st.type == "file" and mtime.sec < os.time() - RACY_SECONDS then
    if parsed[path] == nil then
      if parsed_count >= PARSED_MAX then
        parsed, parsed_count = {}, 0
      end
      parsed_count = parsed_count + 1
    end
    parsed[path] =
      { sec = mtime.sec, nsec = mtime.nsec, size = st.size, ctx = key, task = vim.deepcopy(task) }
  end
  return task
end

---@param task Tasks.Task
---@return integer
local function status_rank(task)
  return STATUS_RANK[task.status or ""] or (#M.STATUSES + 1)
end

---The tie-breaks every order ends with: area, slug, path. Total, so a sort is
---deterministic whatever order the files were found in.
---@param a Tasks.Task
---@param b Tasks.Task
---@return boolean
local function by_name(a, b)
  if a.area ~= b.area then
    return a.area < b.area
  end
  if a.slug ~= b.slug then
    return a.slug < b.slug
  end
  return a.path < b.path
end

---Default ordering: status rank, prio, area, slug, path.
---@param a Tasks.Task
---@param b Tasks.Task
---@return boolean
function M.compare(a, b)
  local ra, rb = status_rank(a), status_rank(b)
  if ra ~= rb then
    return ra < rb
  end
  local pa, pb = a.prio or NO_PRIO_RANK, b.prio or NO_PRIO_RANK
  if pa ~= pb then
    return pa < pb
  end
  return by_name(a, b)
end

---Sorts after every real effort: a task without a (valid) effort is the last of its prio.
local NO_EFFORT_DAYS = math.huge

---Status rank, prio, effort ascending, area, slug, path: important and small
---first. A task without a (valid) effort comes last within its prio.
---@param a Tasks.Task
---@param b Tasks.Task
---@return boolean
function M.compare_prio_effort(a, b)
  local ra, rb = status_rank(a), status_rank(b)
  if ra ~= rb then
    return ra < rb
  end
  local pa, pb = a.prio or NO_PRIO_RANK, b.prio or NO_PRIO_RANK
  if pa ~= pb then
    return pa < pb
  end
  local ea = M.effort_days(a.effort) or NO_EFFORT_DAYS
  local eb = M.effort_days(b.effort) or NO_EFFORT_DAYS
  if ea ~= eb then
    return ea < eb
  end
  return by_name(a, b)
end

---Severity first (critical, high, medium, low, none), then the default order.
---@param a Tasks.Task
---@param b Tasks.Task
---@return boolean
function M.compare_severity(a, b)
  -- A missing or unknown severity ranks 0 and so comes after every real one.
  local sa = a.severity and SEVERITY_RANK[a.severity] or 0
  local sb = b.severity and SEVERITY_RANK[b.severity] or 0
  if sa ~= sb then
    return sa > sb
  end
  return M.compare(a, b)
end

---Return on effort first (highest `value / effort`), tasks without a figure after the ones with one, then the
---default order.
---@param a Tasks.Task
---@param b Tasks.Task
---@return boolean
function M.compare_roi(a, b)
  local ra, rb = M.roi(a), M.roi(b)
  if ra and rb then
    if ra ~= rb then
      return ra > rb
    end
  elseif ra or rb then
    return ra ~= nil
  end
  return M.compare(a, b)
end

---`frecency` here is only the fallback (no scores known: the default order);
---`M.sort` builds the real comparator from the scores it is given.
---@type table<string, fun(a: Tasks.Task, b: Tasks.Task): boolean>
local COMPARATORS = {
  default = M.compare,
  ["prio-effort"] = M.compare_prio_effort,
  severity = M.compare_severity,
  roi = M.compare_roi,
  frecency = M.compare,
}

---Highest frecency score first; equal (or no) scores fall back to the default order.
---@param scores table<string, number>
---@return fun(a: Tasks.Task, b: Tasks.Task): boolean
local function compare_frecency(scores)
  return function(a, b)
    local sa, sb = scores[a.id] or 0, scores[b.id] or 0
    if sa ~= sb then
      return sa > sb
    end
    return M.compare(a, b)
  end
end

---Check a `--sort` word; `nil` and `""` mean the default.
---@param name any
---@return string|nil order
---@return string|nil err
function M.parse_sort(name)
  if name == nil or name == "" then
    return "default", nil
  end
  if type(name) == "string" and COMPARATORS[name] then
    return name, nil
  end
  return nil,
    ("unknown --sort '%s' (expected %s)"):format(tostring(name), table.concat(M.SORTS, ", "))
end

---Sort in place and return the list. `order` is one of `M.SORTS` (default:
---`default`); an unknown word sorts like the default.
---
---`frecency` ranks by `opts.scores` (task id -> score, highest first; unscored
---tasks follow in the default order). Without `opts.scores` the scores come from
---the frecency file (`tasks.frecency.load_scores`), so `list --sort=frecency`
---and `:Tasks list --sort=frecency` need no extra wiring; a missing or
---broken file just means no scores, i.e. the default order.
---@param tasks Tasks.Task[]
---@param order? string
---@param opts? { scores?: table<string, number> }
---@return Tasks.Task[]
function M.sort(tasks, order, opts)
  if order == "frecency" then
    local scores = opts and opts.scores
    if scores == nil then
      local ok, loaded = pcall(function()
        return require("tasks_nvim.frecency").load_scores()
      end)
      scores = ok and loaded or {}
    end
    table.sort(tasks, compare_frecency(scores))
    return tasks
  end
  table.sort(tasks, COMPARATORS[order or "default"] or M.compare)
  return tasks
end

---@param value any
---@return table<any, boolean>|nil set
local function to_set(value)
  if value == nil then
    return nil
  end
  local set = {}
  if type(value) == "table" then
    for _, v in ipairs(value) do
      set[v] = true
    end
  else
    set[value] = true
  end
  return set
end

---@param task Tasks.Task
---@param today string
---@param days integer
---@return boolean
local function is_stale(task, today, days)
  local last = task.updated or task.created
  if not last then
    return true
  end
  local age = M.days_between(last, today)
  return age == nil or age >= days
end

---The next open status after `cur`, wrapping around; an unknown or missing status starts at the first.
---@param cur string|nil
---@return string
function M.cycle_status(cur)
  for i, s in ipairs(M.OPEN_STATUSES) do
    if s == cur then
      return M.OPEN_STATUSES[i % #M.OPEN_STATUSES + 1]
    end
  end
  return M.OPEN_STATUSES[1]
end

---The next prio after `cur`: none -> 1 -> 2 -> 3 -> none (`nil` = remove the key).
---@param cur integer|nil
---@return integer|nil
function M.cycle_prio(cur)
  if cur == nil then
    return M.PRIOS[1]
  end
  for i, p in ipairs(M.PRIOS) do
    if p == cur then
      return M.PRIOS[i + 1]
    end
  end
  return M.PRIOS[1]
end

---Keep the tasks matching every given criterion. Does not reorder.
---@param tasks Tasks.Task[]
---@param f? Tasks.Filter
---@return Tasks.Task[]
---@return Tasks.StalenessReport|nil stale_report  # Only when `f.stale_refs` asked for the check.
function M.filter(tasks, f)
  f = f or {}
  local status, kind, area = to_set(f.status), to_set(f.kind), to_set(f.area)
  local prio, tag = to_set(f.prio), to_set(f.tag)
  local category = to_set(f.category)
  local effort, severity = to_set(f.effort), to_set(f.severity)
  local value, actor = to_set(f.value), to_set(f.actor)
  local plan_set, phase_set = to_set(f.plan), to_set(f.phase)
  local effort_max = f.effort_max and M.effort_days(f.effort_max) or nil
  local today = f.today or M.today()
  -- `--stale=refs`: the caller may hand in a ready map (`f.ref_stale`); else the
  -- files the tasks reference are looked at once, below, after every other
  -- criterion has narrowed the list (each ref costs stats, each repo a git call).
  local ref_stale = f.ref_stale

  local out = {}
  for _, t in ipairs(tasks) do
    local keep = true
    if status and not (t.status and status[t.status]) then
      keep = false
    elseif kind and not (t.kind and kind[t.kind]) then
      keep = false
    elseif area and not area[t.area] then
      keep = false
    elseif prio and not (t.prio and prio[t.prio]) then
      keep = false
    elseif f.prio_max and not (t.prio and t.prio <= f.prio_max) then
      keep = false
    elseif tag then
      keep = false
      for _, name in ipairs(t.tags) do
        if tag[name] then
          keep = true
          break
        end
      end
    end
    if keep and category then
      keep = false
      for _, c in ipairs(M.categories(t)) do
        if category[c] then
          keep = true
          break
        end
      end
    end
    if keep and effort and not (t.effort and effort[t.effort]) then
      keep = false
    end
    if keep and effort_max then
      local days = M.effort_days(t.effort)
      keep = days ~= nil and days <= effort_max
    end
    if keep and severity and not (t.severity and severity[t.severity]) then
      keep = false
    end
    if keep and value and not (t.value and value[t.value]) then
      keep = false
    end
    if keep and f.value_min and not (t.value and t.value >= f.value_min) then
      keep = false
    end
    if keep and actor then
      -- `none` matches the tasks nobody classified (not even by derivation).
      local who = M.actor(t) or "none"
      keep = actor[who] == true
    end
    if keep and plan_set and not (t.plan and plan_set[t.plan]) then
      keep = false
    end
    if keep and phase_set and not (t.phase and phase_set[t.phase]) then
      keep = false
    end
    if keep and f.unestimated and t.value ~= nil and M.effort_days(t.effort) ~= nil then
      keep = false
    end
    if keep and f.blocked and not (t.status == "blocked" or #t.blocked_by > 0) then
      keep = false
    end
    if keep and f.stale and not is_stale(t, today, f.stale) then
      keep = false
    end
    if keep and f.stale_refs and ref_stale and not ref_stale[t.id] then
      keep = false
    end
    if keep then
      out[#out + 1] = t
    end
  end

  ---@type Tasks.StalenessReport|nil
  local stale_report
  if f.stale_refs and not ref_stale then
    local staleness = require("tasks_nvim.staleness")
    local ok, report = pcall(staleness.compute, out, f.ref_opts)
    if not ok then
      report = {
        stale = {},
        tasks = 0,
        files = 0,
        unresolved = 0,
        skipped = 0,
        capped = 0,
        notes = {
          "refs could not be checked: "
            .. tostring(report)
            .. " -- showing every task that has refs (unverified)",
        },
      }
      -- Fail open: an optional signal that cannot be read must not look like "nothing is stale". Every task
      -- with refs stays in the list, marked as unverified.
      for _, t in ipairs(out) do
        if #(t.refs or {}) > 0 then
          report.stale[t.id] = {
            { ref = "(refs could not be checked)", file = "", date = "?", source = "unverified" },
          }
        end
      end
    end
    ---@cast report Tasks.StalenessReport
    stale_report = report
    local dated = {}
    for _, t in ipairs(out) do
      if report.stale[t.id] then
        dated[#dated + 1] = t
      end
    end
    out = dated
  end
  return out, stale_report
end

return M
