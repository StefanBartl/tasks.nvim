---@module 'tasks_nvim.rules_import'
---@brief `import --from-rules` and `bootstrap`: a work list of rules.nvim (`rules-work-list/1`) becomes tasks of an area.
---@description
--- rules.nvim judges the rules of a project and writes what it found as a work list (`docs/WORK-LIST.md` there);
--- this module turns that list into task files. The coupling is the JSON document alone: rules.nvim is never
--- required, and tasks.nvim works the same without it.
---
--- Key responsibilities:
---  - `parse`: read and check the document (schema, version, sizes); names that come from it (the rule id, the
---    target's folder name) are cleaned of control sequences first, then held against a whitelist (SEC-42)
---  - `plan`: what a run would do, entry by entry - create a task, one exists already (open or finished: a finished
---    one is not opened again), the rule is waived, it passes, the entry is unusable. The key of "exists" is the
---    rule id in `rules:` plus the anchor `rules-target:<folder>` in `refs:`
---  - `apply`: create the tasks of a plan (the area index once at the end)
---  - `bootstrap_plan` / `bootstrap`: the folders and READMEs of a new area, nothing existing overwritten
---
--- Not its job: running rules (rules.nvim), printing (`cli`), choosing the area (the caller names it).

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local vault_ops = require("tasks_nvim.vault_ops")

local M = {}

---The schema this module reads, and its one version.
M.SCHEMA = "rules-work-list"
M.SCHEMA_VERSION = 1

---Limits on what a document may hold: a work list is a few hundred rules, not megabytes.
M.MAX_BYTES = 4 * 1024 * 1024
M.MAX_ENTRIES = 2000
---Findings a task names (refs and body); the rest is counted.
M.MAX_FINDINGS = 20

---The prefix of the ref that names the checked project: a `name:thing` anchor, which `--stale-refs` skips.
M.TARGET_REF = "rules-target:"

---@alias Tasks.RulesAction "create"|"exists"|"done"|"waived"|"pass"|"invalid"

---@class Tasks.RulesFinding
---@field file string     # Relative to the target (an absolute one is outside it and never written).
---@field line? integer
---@field text string

---@class Tasks.RulesEntry
---@field rule_id string
---@field family string
---@field severity? "critical"|"recommended"|"nice-to-have"
---@field kind "automated"|"manual"
---@field status "pass"|"fail"|"waived"|"unchecked"
---@field title string
---@field section? string
---@field description string
---@field source? string   # The rule's file relative to its ruleset (`regeln/ERR.md:41`), never a path of this machine.
---@field ruleset? string
---@field findings Tasks.RulesFinding[]
---@field findings_outside integer   # Findings outside the target (an absolute path): counted, not named.
---@field error? string
---@field waiver? { reason: string, expired: boolean }

---@class Tasks.RulesDoc
---@field target string      # The checked folder's name (`my.nvim`).
---@field commit? string     # Its commit, short.
---@field generated_at? string
---@field entries Tasks.RulesEntry[]
---@field invalid { at: integer, why: string }[]   # Entries that could not be read (1-based position).

---@class Tasks.RulesItem
---@field action Tasks.RulesAction
---@field rule_id? string
---@field id? string          # The task: the one that exists, or the id a new one gets.
---@field title? string
---@field note? string        # Why (a waiver's reason, an unusable entry).
---@field new_opts? Tasks.NewOpts

---@class Tasks.RulesPlan
---@field area string
---@field target string
---@field items Tasks.RulesItem[]
---@field counts table<Tasks.RulesAction, integer>

-- ── reading the document ─────────────────────────────────────────────────────

---Text from the document as one clean line: ANSI sequences out first, then every other control character
---(SEC-42: strip, then judge), blanks folded, cut at `max` bytes on a character boundary.
---@param value any
---@param max integer
---@return string
local function line_of(value, max)
  if type(value) ~= "string" then
    return ""
  end
  local s = value:gsub("\27%[[%d;?]*[%a@]", ""):gsub("\27", "")
  s = fsio.clean(s):gsub("%s+", " ")
  s = vim.trim(s)
  if #s > max then
    s = s:sub(1, max)
    -- do not leave half a UTF-8 character at the end
    s = s:gsub("[\192-\255][\128-\191]*$", "")
    s = s .. "..."
  end
  return s
end

---Prose from the document: control characters out (newlines stay), a line that would read as a Markdown heading
---(the task's own sections are headings) is escaped, cut at `max` bytes.
---@param value any
---@param max integer
---@return string
local function prose_of(value, max)
  if type(value) ~= "string" then
    return ""
  end
  local s = fsio.lf(value):gsub("\27%[[%d;?]*[%a@]", "")
  s = s:gsub("[%z\1-\9\11-\31\127]", " "):gsub("\194[\128-\159]", " ")
  if #s > max then
    s = s:sub(1, max):gsub("[\192-\255][\128-\191]*$", "") .. "..."
  end
  local out = {}
  for l in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = l:match("^%s*#") and ("\\" .. vim.trim(l)) or l
  end
  return vim.trim(table.concat(out, "\n"))
end

---A rule id is a word of letters, digits, `.`, `_` and `-` (`ERR-03`, `SEC-40`); nothing else may reach a file.
---@param value any
---@return string|nil
local function rule_id_of(value)
  local s = line_of(value, 64)
  return s:match("^[%w][%w._-]*$") and s or nil
end

---@type table<string, boolean>
local STATUSES = { pass = true, fail = true, waived = true, unchecked = true }
---@type table<string, boolean>
local SEVERITIES = { critical = true, recommended = true, ["nice-to-have"] = true }

---@param path string
---@return boolean
local function is_absolute(path)
  return path:match("^/") ~= nil
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^[/\\][/\\]") ~= nil
end

---A line number from the document: a whole number from 1 up, else nil.
---@param value any
---@return integer|nil
local function line_number(value)
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) or value > 1e9 then
    return nil
  end
  return math.floor(value)
end

---The rule's file relative to the folder of its ruleset, or its bare name: a path of this machine never reaches
---a task (the vault is shared, the user name is in the path).
---@param source any
---@param ruleset_dir? string
---@return string|nil
local function source_of(source, ruleset_dir)
  if type(source) ~= "table" or type(source.file) ~= "string" then
    return nil
  end
  local file = fsio.norm(line_of(source.file, 400))
  local rel
  if ruleset_dir and file:sub(1, #ruleset_dir + 1) == ruleset_dir .. "/" then
    rel = file:sub(#ruleset_dir + 2)
  else
    rel = file:match("([^/]+)$")
  end
  if not rel or rel == "" or rel:find("%.%.") then
    return nil
  end
  local line = line_number(source.line)
  return line and (rel .. ":" .. line) or rel
end

---@param raw table
---@param ruleset_dirs table<string, string>
---@return Tasks.RulesEntry|nil entry
---@return string|nil why
local function entry_of(raw, ruleset_dirs)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  local id = rule_id_of(raw.rule_id)
  if not id then
    return nil, "rule_id is missing or not a word of letters, digits, . _ -"
  end
  if not STATUSES[raw.status] then
    return nil, id .. ": unknown status " .. line_of(tostring(raw.status), 40)
  end
  local kind = raw.kind == "manual" and "manual" or "automated"
  local ruleset = type(raw.ruleset) == "string" and line_of(raw.ruleset, 120) or nil
  ---@type Tasks.RulesEntry
  local e = {
    rule_id = id,
    family = rule_id_of(raw.family) or (id:match("^(%a+)") or id),
    severity = SEVERITIES[raw.severity] and raw.severity or nil,
    kind = kind,
    status = raw.status,
    title = line_of(raw.title, 200),
    section = raw.section ~= nil and line_of(raw.section, 200) or nil,
    description = prose_of(raw.description, 4000),
    ruleset = ruleset ~= "" and ruleset or nil,
    source = source_of(raw.source, ruleset and ruleset_dirs[ruleset] or nil),
    findings = {},
    findings_outside = 0,
    error = raw.error ~= nil and line_of(raw.error, 300) or nil,
  }
  if e.section == "" then
    e.section = nil
  end
  if type(raw.findings) == "table" then
    for _, f in ipairs(raw.findings) do
      local file = type(f) == "table" and line_of(f.file, 300) or ""
      if file ~= "" then
        if is_absolute(file) or file:find("%.%.") then
          e.findings_outside = e.findings_outside + 1
        else
          e.findings[#e.findings + 1] =
            { file = fsio.norm(file), line = line_number(f.line), text = line_of(f.text, 160) }
        end
      end
    end
  end
  if type(raw.waiver) == "table" then
    e.waiver = { reason = line_of(raw.waiver.reason, 300), expired = raw.waiver.expired == true }
  end
  return e, nil
end

---Read a work list. A document of another schema or version, a broken one and one over the limits is refused as a
---whole; a single entry that is unusable is kept in `invalid` and the others are read.
---@param text string
---@return Tasks.RulesDoc|nil doc
---@return string|nil err
function M.parse(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil, "the work list is empty"
  end
  if #text > M.MAX_BYTES then
    return nil, ("the work list is larger than %d bytes"):format(M.MAX_BYTES)
  end
  local ok, raw = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(raw) ~= "table" then
    return nil, "the work list is no JSON object"
  end
  if raw.schema ~= M.SCHEMA then
    return nil,
      ("not a work list of rules.nvim (schema %s, expected %s)"):format(
        line_of(tostring(raw.schema), 60),
        M.SCHEMA
      )
  end
  if raw.schema_version ~= M.SCHEMA_VERSION then
    return nil,
      ("work list version %s is not known (this engine reads %d)"):format(
        line_of(tostring(raw.schema_version), 20),
        M.SCHEMA_VERSION
      )
  end
  if type(raw.entries) ~= "table" or not vim.islist(raw.entries) then
    return nil, "the work list has no list of entries"
  end
  if #raw.entries > M.MAX_ENTRIES then
    return nil, ("the work list has more than %d entries"):format(M.MAX_ENTRIES)
  end
  local target = type(raw.target) == "table" and raw.target or {}
  local folder = fsio.norm(line_of(target.path, 400)):match("([^/]+)$")
  if not folder or not folder:match("^[%w][%w._-]*$") or #folder > 100 then
    return nil, "the work list names no usable target folder (target.path)"
  end
  local ruleset_dirs = {}
  if type(raw.rulesets) == "table" then
    for _, r in ipairs(raw.rulesets) do
      if type(r) == "table" and type(r.name) == "string" and type(r.source) == "string" then
        ruleset_dirs[line_of(r.name, 120)] = fsio.norm(line_of(r.source, 400))
      end
    end
  end
  local commit = line_of(target.commit, 64)
  ---@type Tasks.RulesDoc
  local doc = {
    target = folder,
    commit = commit:match("^%x+$") and commit:sub(1, 12) or nil,
    generated_at = line_of(raw.generated_at, 40):match("^[%dT:Z-]+$"),
    entries = {},
    invalid = {},
  }
  for i, item in ipairs(raw.entries) do
    local e, why = entry_of(item, ruleset_dirs)
    if e then
      doc.entries[#doc.entries + 1] = e
    else
      doc.invalid[#doc.invalid + 1] = {
        at = i,
        why = why --[[@as string]],
      }
    end
  end
  return doc, nil
end

-- ── the tasks a run makes ────────────────────────────────────────────────────

---`critical` -> 1, `recommended` -> 2, `nice-to-have` -> 3.
local PRIO = { critical = 1, recommended = 2, ["nice-to-have"] = 3 }

---The body words per language.
local WORDS = {
  de = {
    context = "## Kontext",
    acceptance = "## Akzeptanz",
    notes = "## Notizen",
    rule = "Regel `%s` (%s, %s)",
    from = " aus `%s`",
    section = "Abschnitt: %s",
    run = "Lauf: %s, Stand `%s`%s",
    findings = "Fundstellen (%d):",
    more = "  - und %d weitere",
    outside = "%d Fundstelle(n) außerhalb des Projekts (nicht genannt)",
    error = "Die Prüfung lief nicht: %s",
    expired = "Der Waiver ist abgelaufen (Grund war: %s)",
    holds = "- [ ] %s",
    automated = "- [ ] `:Rules check --family=%s` meldet `%s` nicht mehr",
    manual = "- [ ] Von Hand geprüft, das Ergebnis steht in den Notizen",
    created = "- %s: angelegt von `tasks import --from-rules`",
  },
  en = {
    context = "## Context",
    acceptance = "## Acceptance",
    notes = "## Notes",
    rule = "Rule `%s` (%s, %s)",
    from = " from `%s`",
    section = "Section: %s",
    run = "Run: %s, state `%s`%s",
    findings = "Findings (%d):",
    more = "  - and %d more",
    outside = "%d finding(s) outside the project (not named)",
    error = "The check did not run: %s",
    expired = "The waiver has expired (its reason was: %s)",
    holds = "- [ ] %s",
    automated = "- [ ] `:Rules check --family=%s` no longer reports `%s`",
    manual = "- [ ] Checked by hand, the result is in the notes",
    created = "- %s: created by `tasks import --from-rules`",
  },
}

---The heading text of the rule without its id in front (`` `ERR-03` — pcall results are checked `` ->
---`pcall results are checked`).
---@param e Tasks.RulesEntry
---@return string
local function plain_title(e)
  local t = e.title:gsub("`", "")
  local esc = vim.pesc(e.rule_id)
  t = t:gsub("^%s*" .. esc .. "%s*", ""):gsub("^[:%-%s]+", ""):gsub("^\226\128[\147\148]%s*", "")
  t = vim.trim(t)
  if t == "" then
    t = e.section or e.family
  end
  return t
end

---@param text string
---@return string
local function code(text)
  return (text:gsub("`", "'"))
end

---@param e Tasks.RulesEntry
---@param doc Tasks.RulesDoc
---@param lang "de"|"en"
---@param today string
---@return string
local function body_of(e, doc, lang, today)
  local w = WORDS[lang]
  local out = {}
  if e.description ~= "" then
    out[#out + 1] = e.description
    out[#out + 1] = ""
  end
  out[#out + 1] = w.context
  out[#out + 1] = ""
  local rule = w.rule:format(e.rule_id, e.severity or "-", e.kind)
  if e.ruleset then
    rule = rule .. w.from:format(code(e.ruleset))
  end
  if e.source then
    rule = rule .. ", `" .. code(e.source) .. "`"
  end
  out[#out + 1] = "- " .. rule
  if e.section then
    out[#out + 1] = "- " .. w.section:format(e.section)
  end
  local commit = doc.commit and (" @ " .. doc.commit) or ""
  out[#out + 1] = "- " .. w.run:format(doc.generated_at or "-", e.status, commit)
  if e.error then
    out[#out + 1] = "- " .. w.error:format(e.error)
  end
  if e.waiver and e.waiver.expired then
    out[#out + 1] = "- " .. w.expired:format(e.waiver.reason ~= "" and e.waiver.reason or "-")
  end
  if #e.findings > 0 then
    out[#out + 1] = "- " .. w.findings:format(#e.findings)
    for i, f in ipairs(e.findings) do
      if i > M.MAX_FINDINGS then
        out[#out + 1] = w.more:format(#e.findings - M.MAX_FINDINGS)
        break
      end
      local at = f.line and (f.file .. ":" .. f.line) or f.file
      -- the line of the finding as code too: its backticks would open a code span of their own
      local shown = f.text ~= "" and (" `" .. code(f.text) .. "`") or ""
      out[#out + 1] = ("  - `%s`%s"):format(code(at), shown)
    end
  end
  if e.findings_outside > 0 then
    out[#out + 1] = "- " .. w.outside:format(e.findings_outside)
  end
  out[#out + 1] = ""
  out[#out + 1] = w.acceptance
  out[#out + 1] = ""
  out[#out + 1] = w.holds:format(plain_title(e))
  if e.kind == "automated" then
    out[#out + 1] = w.automated:format(e.family, e.rule_id)
  else
    out[#out + 1] = w.manual
  end
  out[#out + 1] = ""
  out[#out + 1] = w.notes
  out[#out + 1] = ""
  out[#out + 1] = w.created:format(today)
  return table.concat(out, "\n")
end

---The rule ids a task names in `rules:`, and whether its `refs:` name a target (and which).
---@param meta table
---@return string[] rules
---@return table<string, boolean> targets
---@return boolean any_target
local function keys_of(meta)
  local function list(v)
    if type(v) == "string" then
      local out = {}
      for item in (v:match("^%[(.*)%]$") or v):gmatch("[^,]+") do
        out[#out + 1] = vim.trim(item)
      end
      return out
    end
    return type(v) == "table" and v or {}
  end
  local targets, any = {}, false
  for _, ref in ipairs(list(meta.refs)) do
    if type(ref) == "string" and ref:sub(1, #M.TARGET_REF) == M.TARGET_REF then
      targets[ref:sub(#M.TARGET_REF + 1)] = true
      any = true
    end
  end
  return list(meta.rules), targets, any
end

---The tasks of `area` that hold a rule for `target`: rule id -> `{ id, done }`. A task that names the rule and no
---target at all (written by hand) counts for every target; one for another target does not.
---@param area string
---@param target string
---@param root string
---@return table<string, { id: string, done: boolean }>
local function existing(area, target, root)
  local found = {}
  local function take(tasks, done)
    for _, t in ipairs(tasks or {}) do
      local rules, targets, any = keys_of(t.meta or {})
      if not any or targets[target] then
        for _, r in ipairs(rules) do
          -- an open task wins over a finished one of the same rule
          if type(r) == "string" and (not found[r] or (found[r].done and not done)) then
            found[r] = { id = t.id, done = done }
          end
        end
      end
    end
  end
  take(scan.backlog(area, { root = root }), true)
  take(scan.area(area, { root = root }), false)
  return found
end

---@class Tasks.RulesPlanOpts
---@field root string
---@field today string
---@field lang? "de"|"en"

---What a run of `doc` into `area` would do. Nothing is written; the ids of new tasks are the ones they would get now.
---@param doc Tasks.RulesDoc
---@param area string
---@param opts Tasks.RulesPlanOpts
---@return Tasks.RulesPlan|nil plan
---@return string|nil err
function M.plan(doc, area, opts)
  local root = opts.root
  local lang = opts.lang or "de"
  if not WORDS[lang] then
    return nil, "lang must be de or en"
  end
  ---@type Tasks.RulesPlan
  local plan = {
    area = area,
    target = doc.target,
    items = {},
    counts = { create = 0, exists = 0, done = 0, waived = 0, pass = 0, invalid = 0 },
  }
  local function add(item)
    plan.items[#plan.items + 1] = item
    plan.counts[item.action] = plan.counts[item.action] + 1
  end
  -- an area `bootstrap` has not made yet holds no task: every id is the slug of the title
  local area_exists = vault.has_area(root, area)
  local have = area_exists and existing(area, doc.target, root) or {}
  local seen = {}
  for _, e in ipairs(doc.entries) do
    local has = have[e.rule_id]
    if seen[e.rule_id] then
      add({ action = "invalid", rule_id = e.rule_id, note = "named twice in the work list" })
    elseif e.status == "pass" then
      -- an open task for a rule that passes now is worth a word: it may be finished
      add({ action = "pass", rule_id = e.rule_id, id = has and not has.done and has.id or nil })
    elseif e.status == "waived" then
      add({ action = "waived", rule_id = e.rule_id, note = e.waiver and e.waiver.reason or nil })
    elseif has then
      add({ action = has.done and "done" or "exists", rule_id = e.rule_id, id = has.id })
    else
      local title = ("%s: %s"):format(e.rule_id, plain_title(e))
      local refs = { M.TARGET_REF .. doc.target }
      for i, f in ipairs(e.findings) do
        if i > M.MAX_FINDINGS then
          break
        end
        refs[#refs + 1] = f.line and (f.file .. ":" .. f.line) or f.file
      end
      ---@type Tasks.NewOpts
      local new_opts = {
        root = root,
        today = opts.today,
        title = line_of(title, 120),
        kind = "task",
        prio = e.severity and PRIO[e.severity] or 2,
        effort = e.kind == "automated" and "S" or "M",
        category = { "ruleset" },
        rules = { e.rule_id },
        refs = refs,
        lang = lang,
        body = body_of(e, doc, lang, opts.today),
        index = false,
      }
      local probe, perr
      if area_exists then
        probe, perr = mutate.new(area, vim.tbl_extend("force", new_opts, { dry_run = true }))
      else
        probe = { id = area .. "/" .. mutate.slugify(new_opts.title) }
      end
      if not probe then
        add({ action = "invalid", rule_id = e.rule_id, note = perr })
      else
        add({
          action = "create",
          rule_id = e.rule_id,
          id = probe.id,
          title = new_opts.title,
          new_opts = new_opts,
        })
      end
    end
    seen[e.rule_id] = true
  end
  for _, bad in ipairs(doc.invalid) do
    add({ action = "invalid", note = ("entry %d: %s"):format(bad.at, bad.why) })
  end
  return plan, nil
end

---Create the tasks of `plan`. One that cannot be created is reported and the others are made; the area index is
---written once at the end.
---@param plan Tasks.RulesPlan
---@param opts { root: string }
---@return { created: { rule_id: string, id: string, path: string }[], failed: { rule_id: string, err: string }[], index?: Tasks.IndexResult, index_err?: string }
function M.apply(plan, opts)
  local result = { created = {}, failed = {} }
  for _, item in ipairs(plan.items) do
    if item.action == "create" then
      local res, err = mutate.new(plan.area, item.new_opts)
      if res then
        item.id = res.id
        result.created[#result.created + 1] =
          { rule_id = item.rule_id, id = res.id, path = res.path }
      else
        result.failed[#result.failed + 1] = { rule_id = item.rule_id, err = tostring(err) }
      end
    end
  end
  if #result.created > 0 then
    result.index, result.index_err = index.write_area(plan.area, { root = opts.root })
  end
  return result
end

-- ── a new area ───────────────────────────────────────────────────────────────

---The README of a new area.
---@param area string
---@return string
local function area_readme(area)
  return ("# %s\n\nOpen tasks in `ROADMAP/tasks/`, their overview in `ROADMAP/TASKS.md` (generated), finished work in"):format(
    area
  ) .. " `Backlog/` with its index `Backlog/README.md`.\n"
end

---@param area string
---@return string
local function backlog_readme(area)
  return ("# %s -- Backlog\n\nFinished work of this area.\n"):format(area)
end

---What `bootstrap` would make for `area`, relative to the vault: the folders and files that do not exist yet.
---@param root string
---@param area string
---@return string[]|nil missing
---@return string|nil err
function M.bootstrap_plan(root, area)
  local name_err = vault_ops.area_name_error(area)
  if name_err then
    return nil, name_err
  end
  local dir = root .. "/" .. area
  if fsio.is_file(dir) then
    return nil, area .. " is a file in the vault"
  end
  if fsio.is_link(dir) then
    return nil, area .. " is a link out of the vault: not used"
  end
  local missing = {}
  for _, sub in ipairs({ "ROADMAP/tasks", "Backlog/FEATURES", "Backlog/TASKS" }) do
    if not fsio.is_dir(dir .. "/" .. sub) then
      missing[#missing + 1] = area .. "/" .. sub .. "/"
    end
  end
  for _, file in ipairs({ "README.md", "Backlog/README.md", "ROADMAP/TASKS.md" }) do
    if not fsio.is_file(dir .. "/" .. file) then
      missing[#missing + 1] = area .. "/" .. file
    end
  end
  return missing, nil
end

---Make the folders and READMEs of `area` (an existing area is completed, nothing in it overwritten) and write its
---index.
---@param root string
---@param area string
---@return string[]|nil made  relative to the vault
---@return string|nil err
function M.bootstrap(root, area)
  local missing, perr = M.bootstrap_plan(root, area)
  if not missing then
    return nil, perr
  end
  local made, serr = vault_ops.scaffold_area(root, area)
  if serr then
    return nil, serr
  end
  made = vim.tbl_map(function(p)
    return p .. "/"
  end, made or {})
  for file, text in pairs({
    ["README.md"] = area_readme(area),
    ["Backlog/README.md"] = backlog_readme(area),
  }) do
    local path = root .. "/" .. area .. "/" .. file
    if not fsio.is_file(path) then
      local ok, err = fsio.create_exclusive(path, text)
      if ok then
        made[#made + 1] = area .. "/" .. file
      elseif not fsio.is_exists(err) then
        return nil, ("cannot write %s/%s: %s"):format(area, file, tostring(err))
      end
    end
  end
  local had_index = fsio.is_file(vault.index_path(root, area))
  local res, ierr = index.write_area(area, { root = root })
  if not res then
    return nil, "the area is made, its index is not: " .. tostring(ierr)
  end
  if not had_index then
    made[#made + 1] = area .. "/ROADMAP/TASKS.md"
  end
  table.sort(made)
  return made, nil
end

return M
