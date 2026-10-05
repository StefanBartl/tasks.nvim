---@module 'tasks_nvim.mutate'
---@brief Create, change and finish tasks (the only module of the engine that writes task files).
---@description
--- `new` writes a task file, `set` patches its frontmatter, `done` moves it to
--- `Backlog/` (rule R6). `attach` and `folderize` turn a task into a folder task
--- that can hold assets (concept section 12.2). Each regenerates the area index
--- afterwards.
---
--- Key responsibilities:
---  - `template` / `new`: the file text, a collision-safe kebab slug, `created`
---    and `updated`; the file is created with `O_CREAT|O_EXCL`, never overwritten
---  - `set`: validate the patch, then change only the named keys through
---    `lib.nvim.markdown.frontmatter`; `updated` is bumped only when something
---    actually changed
---  - `done`: `status: done` + `done_in`, move to `Backlog/FEATURES|TASKS` with a
---    `YYYY-MM-DD_` prefix, add the row to that `Backlog/README.md`, regenerate
---    the index. The finished copy, the README and the index are snapshotted
---    with `lib.nvim.checkpoint` and restored byte-exact when any step fails (the
---    task file itself is checked for changes right before it goes, and put back
---    by hand); a second run of an already finished task changes nothing, and a
---    run interrupted half way resumes
---
--- Not its job: prompting for input, opening the file, notifying (all UI).

local checkpoint = require("lib.nvim.checkpoint")
local fm = require("lib.nvim.markdown.frontmatter")

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---Patch value that deletes a key (`set`).
M.REMOVE = fm.REMOVE

---Longest slug generated from a title.
M.MAX_SLUG = 60

---Not `s:match("^%s*(.-)%s*$")`: that rescans the whole rest of the string at every space of
---a long inner run (32 000 spaces cost 1.7 s); `vim.trim` is linear.
---@param s string
---@return string
local function trim(s)
  return vim.trim(s)
end

-- ── Slugs ────────────────────────────────────────────────────────────────────

---Lower-case letters with a diacritic -> ASCII. Anything else non-ASCII is dropped.
---@type table<string, string>
local FOLD = {
  ["ä"] = "ae",
  ["ö"] = "oe",
  ["ü"] = "ue",
  ["ß"] = "ss",
  ["à"] = "a",
  ["á"] = "a",
  ["â"] = "a",
  ["ã"] = "a",
  ["å"] = "a",
  ["æ"] = "ae",
  ["ç"] = "c",
  ["è"] = "e",
  ["é"] = "e",
  ["ê"] = "e",
  ["ë"] = "e",
  ["ì"] = "i",
  ["í"] = "i",
  ["î"] = "i",
  ["ï"] = "i",
  ["ñ"] = "n",
  ["ò"] = "o",
  ["ó"] = "o",
  ["ô"] = "o",
  ["õ"] = "o",
  ["ø"] = "o",
  ["œ"] = "oe",
  ["ù"] = "u",
  ["ú"] = "u",
  ["û"] = "u",
  ["ý"] = "y",
  ["ÿ"] = "y",
}

---A kebab-case ASCII slug from free text: umlauts folded (`ü` -> `ue`), other
---characters turned into hyphens, runs of hyphens collapsed, at most
---`MAX_SLUG` characters. Text with no usable character gives `"task"`; a
---result that is a Windows device name (`nul`, `con`, ...) gets `-task`
---appended, since a folder task of that name cannot be created there.
---@param title string
---@return string
function M.slugify(title)
  local lowered = vim.fn.tolower(title)
  local out = {}
  for ch in lowered:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if ch:match("^[a-z0-9]$") then
      out[#out + 1] = ch
    elseif FOLD[ch] then
      out[#out + 1] = FOLD[ch]
    else
      out[#out + 1] = "-"
    end
  end
  local slug = table.concat(out):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if #slug > M.MAX_SLUG then
    slug = slug:sub(1, M.MAX_SLUG):gsub("%-$", "")
  end
  if slug == "" then
    return "task"
  end
  if vault.is_reserved_name(slug) then
    return slug .. "-task"
  end
  return slug
end

-- ── Template ─────────────────────────────────────────────────────────────────

---Body languages of the template (R11: a task is written in the language of the
---plugin's book). German is the default; the frontmatter is English either way.
---@alias Tasks.Lang "de"|"en"

---Visible placeholders: the text to paste into an editor and fill in.
---@type table<Tasks.Lang, string>
local TEMPLATE_BODY = {
  de = table.concat({
    "",
    "Eine Zeile Zusammenfassung — sie landet im Index.",
    "",
    "## Kontext",
    "",
    "Warum, woher kam das.",
    "",
    "## Akzeptanz",
    "",
    "- [ ] was am Ende wahr sein muss",
    "",
    "## Notizen",
    "",
    "Entscheidungen, Sackgassen, Verweise.",
    "",
  }, "\n"),
  en = table.concat({
    "",
    "One line summary - it ends up in the index.",
    "",
    "## Context",
    "",
    "Why, where this came from.",
    "",
    "## Acceptance",
    "",
    "- [ ] what must be true at the end",
    "",
    "## Notes",
    "",
    "Decisions, dead ends, references.",
    "",
  }, "\n"),
}

---Invisible placeholders (HTML comments): a task created without a summary must
---not get a placeholder sentence as its index summary.
---@type table<Tasks.Lang, string>
local NEW_BODY_SECTIONS = {
  de = table.concat({
    "## Kontext",
    "",
    "<!-- Warum, woher kam das. -->",
    "",
    "## Akzeptanz",
    "",
    "<!-- was am Ende wahr sein muss, als Checkliste -->",
    "",
    "## Notizen",
    "",
    "<!-- Entscheidungen, Sackgassen, Verweise. -->",
    "",
  }, "\n"),
  en = table.concat({
    "## Context",
    "",
    "<!-- Why, where this came from. -->",
    "",
    "## Acceptance",
    "",
    "<!-- what must be true at the end, as a checklist -->",
    "",
    "## Notes",
    "",
    "<!-- Decisions, dead ends, references. -->",
    "",
  }, "\n"),
}

---@param lang any
---@return Tasks.Lang|nil lang
---@return string|nil err
local function check_lang(lang)
  if lang == nil then
    return "de", nil
  end
  if lang == "de" or lang == "en" then
    return lang, nil
  end
  return nil, ("unknown lang '%s' (expected de or en)"):format(tostring(lang))
end

---Frontmatter keys in the order concept section 3 shows them.
---@param meta { title: string, status: string, kind?: string, prio?: integer|string, effort?: string, tags?: string[], category?: string[], severity?: string, refs?: string[], created: string, updated: string }
---@return table[] pairs
local function meta_pairs(meta)
  local pairs_ = {
    { "title", meta.title },
    { "status", meta.status },
  }
  if meta.kind then
    pairs_[#pairs_ + 1] = { "kind", meta.kind }
  end
  if meta.prio then
    pairs_[#pairs_ + 1] = { "prio", tostring(meta.prio) }
  end
  if meta.effort then
    pairs_[#pairs_ + 1] = { "effort", meta.effort }
  end
  if meta.tags then
    pairs_[#pairs_ + 1] = { "tags", meta.tags }
  end
  if meta.category then
    pairs_[#pairs_ + 1] = { "category", meta.category }
  end
  if meta.severity then
    pairs_[#pairs_ + 1] = { "severity", meta.severity }
  end
  pairs_[#pairs_ + 1] = { "created", meta.created }
  pairs_[#pairs_ + 1] = { "updated", meta.updated }
  if meta.refs then
    pairs_[#pairs_ + 1] = { "refs", meta.refs }
  end
  return pairs_
end

---The task template as text, with every field present and visible placeholders.
---An unknown `lang` falls back to German (the CLI validates it before).
---@param opts? { title?: string, kind?: string, prio?: integer, effort?: string, tags?: string[], today?: string, lang?: Tasks.Lang }
---@return string text
function M.template(opts)
  opts = opts or {}
  local today = opts.today or model.today()
  local text = fm.update_text(
    TEMPLATE_BODY[opts.lang or "de"] or TEMPLATE_BODY.de,
    meta_pairs({
      title = opts.title or "Titel",
      status = "open",
      kind = opts.kind or "task",
      prio = opts.prio or 2,
      effort = opts.effort or "M",
      tags = opts.tags or {},
      created = today,
      updated = today,
    }),
    { create = true }
  )
  return text or ""
end

-- ── Validation ───────────────────────────────────────────────────────────────

---@param value any
---@param what string
---@return string|nil text
---@return string|nil err
local function one_line(value, what)
  if type(value) ~= "string" then
    return nil, what .. " must be text"
  end
  local t = trim(value)
  if t == "" then
    return nil, what .. " must not be empty"
  end
  if t:find("[\r\n]") then
    return nil, what .. " must be a single line"
  end
  return t, nil
end

---A list of single-line strings. A string is split at commas; one pair of
---brackets around the whole string (`[a, b]`, as the file shows it) is dropped.
---With `strict`, an item must also be safe inside an inline `[a, b]` list
---(tags: no comma, bracket, quote or `#`); refs and commits may contain them.
---@param value any
---@param what string
---@param strict? boolean
---@return string[]|nil list
---@return string|nil err
local function string_list(value, what, strict)
  if type(value) == "string" then
    local out = {}
    local inner = trim(value):match("^%[(.*)%]$")
    for item in (inner or value):gmatch("[^,]+") do
      local t = trim(item)
      if t ~= "" then
        out[#out + 1] = t
      end
    end
    value = out
  end
  if type(value) ~= "table" then
    return nil, what .. " must be a list"
  end
  local out = {}
  for _, item in ipairs(value) do
    local t, err = one_line(item, what .. " item")
    if not t then
      return nil, err
    end
    if strict and t:find("[,%[%]\"'#]") then
      return nil, ("%s item '%s' must not contain , [ ] quotes or #"):format(what, t)
    end
    out[#out + 1] = t
  end
  return out, nil
end

---@param value any
---@return string[]|nil ids
---@return string|nil err
local function id_list(value)
  local list, err = string_list(value, "blocked_by")
  if not list then
    return nil, err
  end
  for _, id in ipairs(list) do
    local _, slug, id_err = vault.parse_id(id)
    if id_err or not slug then
      return nil, "blocked_by: " .. (id_err or ("expected <area>/<slug>, got " .. id))
    end
  end
  return list, nil
end

---A list of categories (`model.CATEGORIES`), each checked.
---@param value any
---@return string[]|nil list
---@return string|nil err
local function category_list(value)
  local list, err = string_list(value, "category", true)
  if not list then
    return nil, err
  end
  for _, c in ipairs(list) do
    if not model.is_category(c) then
      return nil,
        ("unknown category '%s' (expected %s)"):format(c, table.concat(model.CATEGORIES, ", "))
    end
  end
  return list, nil
end

---Keys `set` accepts, in the order they are written when new. `updated` is
---deliberately absent: the tool sets it. Exported as `M.SETTABLE` for front
---ends that complete or document the keys.
local SETTABLE = {
  "title",
  "status",
  "kind",
  "prio",
  "effort",
  "tags",
  "category",
  "severity",
  "summary",
  "blocked_by",
  "refs",
  "rules",
  "done_in",
  "created",
}

---@type string[]
M.SETTABLE = SETTABLE

---Check and normalise a `set` patch into an ordered list of `{ key, value }`.
---A value of `REMOVE` deletes the key (not for `title` and `status`).
---@param patch table<string, any>
---@param opts? { allow_unknown?: boolean }
---@return table[]|nil pairs
---@return string|nil err
local function normalize_patch(patch, opts)
  local result = {}
  local known = {}
  for _, key in ipairs(SETTABLE) do
    known[key] = true
  end
  local keys = {}
  for key in pairs(patch) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local ia, ib = #SETTABLE + 1, #SETTABLE + 1
    for i, k in ipairs(SETTABLE) do
      ia = k == a and i or ia
      ib = k == b and i or ib
    end
    if ia ~= ib then
      return ia < ib
    end
    return a < b
  end)
  if #keys == 0 then
    return nil, "nothing to set"
  end

  for _, key in ipairs(keys) do
    local value = patch[key]
    local removing = value == M.REMOVE
    if key == "updated" then
      return nil, "updated is set by the tool, not by hand"
    elseif not known[key] and not (opts and opts.allow_unknown) then
      return nil, ("unknown field '%s' (settable: %s)"):format(key, table.concat(SETTABLE, ", "))
    elseif not key:match("^[%a_][%w_]*$") then
      return nil, "invalid field name: " .. tostring(key)
    elseif removing and (key == "title" or key == "status") then
      return nil, key .. " cannot be removed"
    elseif removing then
      result[#result + 1] = { key, M.REMOVE }
    elseif key == "title" then
      local t, err = one_line(value, "title")
      if not t then
        return nil, err
      end
      result[#result + 1] = { key, t }
    elseif key == "status" then
      if value == "done" then
        return nil, "status 'done' is set by finishing the task (tasks done), which also moves it"
      end
      if not model.is_open_status(value) then
        return nil,
          ("unknown status '%s' (expected %s)"):format(
            tostring(value),
            table.concat(model.OPEN_STATUSES, ", ")
          )
      end
      result[#result + 1] = { key, value }
    elseif key == "kind" then
      if not model.is_kind(value) then
        return nil,
          ("unknown kind '%s' (expected %s)"):format(
            tostring(value),
            table.concat(model.KINDS, ", ")
          )
      end
      result[#result + 1] = { key, value }
    elseif key == "prio" then
      local prio = model.to_prio(value)
      if not prio then
        return nil, "prio must be 1, 2 or 3, got " .. tostring(value)
      end
      result[#result + 1] = { key, tostring(prio) }
    elseif key == "effort" then
      if not model.is_effort(value) then
        return nil, ("effort '%s' is neither XS..XL nor days like 0.5d"):format(tostring(value))
      end
      result[#result + 1] = { key, value }
    elseif key == "created" then
      if not model.is_date(value) then
        return nil, ("created '%s' is not a date (YYYY-MM-DD)"):format(tostring(value))
      end
      result[#result + 1] = { key, value }
    elseif key == "severity" then
      if not model.is_severity(value) then
        return nil,
          ("unknown severity '%s' (expected %s)"):format(
            tostring(value),
            table.concat(model.SEVERITIES, ", ")
          )
      end
      result[#result + 1] = { key, value }
    elseif key == "category" then
      local list, err = category_list(value)
      if not list then
        return nil, err
      end
      result[#result + 1] = { key, #list > 0 and list or M.REMOVE }
    elseif key == "tags" or key == "refs" or key == "rules" or key == "done_in" then
      local list, err = string_list(value, key, key == "tags")
      if not list then
        return nil, err
      end
      if #list == 0 then
        result[#result + 1] = { key, M.REMOVE }
      elseif key == "done_in" then
        result[#result + 1] = { key, table.concat(list, ", ") }
      else
        result[#result + 1] = { key, list }
      end
    elseif key == "blocked_by" then
      local ids, err = id_list(value)
      if not ids then
        return nil, err
      end
      if #ids == 0 then
        result[#result + 1] = { key, M.REMOVE }
      elseif #ids == 1 then
        result[#result + 1] = { key, ids[1] }
      else
        result[#result + 1] = { key, ids }
      end
    else
      -- summary, or an allowed unknown field: a single-line text.
      local t, err = one_line(value, key)
      if not t then
        return nil, err
      end
      result[#result + 1] = { key, t }
    end
  end
  return result, nil
end

-- ── new ──────────────────────────────────────────────────────────────────────

---Create a task file under `<area>/ROADMAP/tasks/`.
---
---The slug comes from the title (`opts.slug` overrides it); a taken slug gets
---`-2`, `-3`, ... unless it was given explicitly, which is then an error.
---`status` defaults to `open`, `kind` to `task`; `prio`, `effort`, `tags` and
---`summary` are written only when given.
---@param area string
---@param opts Tasks.NewOpts
---@return { id: string, area: string, slug: string, path: string, folder: boolean, index?: Tasks.IndexResult, index_err?: string }|nil result
---@return string|nil err
function M.new(area, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area)
  end

  local title, terr = one_line(opts.title, "title")
  if not title then
    return nil, terr
  end
  local status = opts.status or "open"
  if not model.is_open_status(status) then
    return nil,
      ("unknown status '%s' (expected %s)"):format(
        tostring(status),
        table.concat(model.OPEN_STATUSES, ", ")
      )
  end
  local kind = opts.kind or "task"
  if not model.is_kind(kind) then
    return nil,
      ("unknown kind '%s' (expected %s)"):format(tostring(kind), table.concat(model.KINDS, ", "))
  end
  local prio
  if opts.prio ~= nil then
    prio = model.to_prio(opts.prio)
    if not prio then
      return nil, "prio must be 1, 2 or 3, got " .. tostring(opts.prio)
    end
  end
  if opts.effort ~= nil and not model.is_effort(opts.effort) then
    return nil, ("effort '%s' is neither XS..XL nor days like 0.5d"):format(tostring(opts.effort))
  end
  local tags
  if opts.tags ~= nil then
    local list, lerr = string_list(opts.tags, "tags", true)
    if not list then
      return nil, lerr
    end
    tags = #list > 0 and list or nil
  end
  local category
  if opts.category ~= nil then
    local list, cerr = category_list(opts.category)
    if not list then
      return nil, cerr
    end
    category = #list > 0 and list or nil
  end
  if opts.severity ~= nil and not model.is_severity(opts.severity) then
    return nil,
      ("unknown severity '%s' (expected %s)"):format(
        tostring(opts.severity),
        table.concat(model.SEVERITIES, ", ")
      )
  end
  local refs
  if opts.refs ~= nil then
    local list, rerr2 = string_list(opts.refs, "refs")
    if not list then
      return nil, rerr2
    end
    refs = #list > 0 and list or nil
  end
  local lang, langerr = check_lang(opts.lang)
  if not lang then
    return nil, langerr
  end
  local summary
  if opts.summary ~= nil then
    local s, serr = one_line(opts.summary, "summary")
    if not s then
      return nil, serr
    end
    summary = s
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  if opts.slug ~= nil and not vault.valid_slug(opts.slug) then
    return nil, "invalid slug: " .. tostring(opts.slug)
  end
  if opts.slug ~= nil and vault.is_reserved_name(opts.slug) then
    return nil, ("slug '%s' is a reserved Windows device name"):format(opts.slug)
  end

  local lead = summary and (summary .. "\n\n") or ""
  local body = "\n" .. lead .. NEW_BODY_SECTIONS[lang]
  local text, ferr = fm.update_text(
    body,
    meta_pairs({
      title = title,
      status = status,
      kind = kind,
      prio = prio,
      effort = opts.effort,
      tags = tags,
      category = category,
      severity = opts.severity,
      refs = refs,
      created = today,
      updated = today,
    }),
    { create = true }
  )
  if not text then
    return nil, "cannot build the task file: " .. tostring(ferr)
  end

  local taken, berr = scan.backlog_slugs(area, { root = root })
  if not taken then
    return nil, berr
  end

  local base = opts.slug or M.slugify(title)
  local n = 1
  while true do
    local slug = n == 1 and base or (base .. "-" .. n)
    -- A slug is taken by a file or a folder task of that name, in either form.
    local in_use = fsio.is_dir(vault.task_dir(root, area, slug))
      or fsio.is_file(vault.task_path(root, area, slug))
    if not taken[slug] and not in_use then
      local path = opts.folder and vault.folder_task_path(root, area, slug)
        or vault.task_path(root, area, slug)
      local ok, err = fsio.create_exclusive(path, text)
      if ok then
        ---@type table
        local result = {
          id = area .. "/" .. slug,
          area = area,
          slug = slug,
          path = path,
          folder = opts.folder == true,
        }
        if opts.index ~= false then
          result.index, result.index_err = index.write_area(area, { root = root })
        end
        return result, nil
      elseif err ~= "exists" then
        return nil, "cannot create " .. path .. ": " .. tostring(err)
      end
    end
    if opts.slug then
      return nil, "task already exists: " .. area .. "/" .. opts.slug
    end
    n = n + 1
    if n > 999 then
      return nil, "no free slug for " .. base
    end
  end
end

-- ── set ──────────────────────────────────────────────────────────────────────

---Change frontmatter keys of an open task and set `updated`.
---
---`patch` maps key -> value (`REMOVE` deletes). Nothing is written, and
---`updated` stays as it was, when the patch would not change the file.
---@param id string
---@param patch table<string, any>
---@param opts? { root?: string, today?: string, index?: boolean, allow_unknown?: boolean }
---@return { id: string, path: string, changed: boolean, index?: Tasks.IndexResult, index_err?: string }|nil result
---@return string|nil err
function M.set(id, patch, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local task, ferr = scan.find(id, { root = root })
  if not task then
    return nil, ferr
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local pairs_, perr = normalize_patch(patch, opts)
  if not pairs_ then
    return nil, perr
  end

  local text, rd_err = fsio.read(task.path)
  if not text then
    return nil, "cannot read " .. task.path .. ": " .. tostring(rd_err)
  end
  local probe, uerr = fm.update_text(text, pairs_)
  if not probe then
    return nil, "cannot update " .. task.path .. ": " .. tostring(uerr)
  end
  local result = { id = task.id, path = task.path, changed = probe ~= text }
  if not result.changed then
    return result, nil
  end

  pairs_[#pairs_ + 1] = { "updated", today }
  local ok, werr = fm.update(task.path, pairs_)
  if not ok then
    return nil, "cannot write " .. task.path .. ": " .. tostring(werr)
  end
  if opts.index ~= false then
    result.index, result.index_err = index.write_area(task.area, { root = root })
  end
  return result, nil
end

-- ── Backlog README ───────────────────────────────────────────────────────────

---@param s string
---@return string
local function cell(s)
  return fsio.md_cell(s)
end

---The README row of a finished task.
---`rel` is the path below `Backlog/<bucket>/` (`<file>.md`, or `<dir>/<file>.md`
---for a folder task); the link text is always the file name.
---@param bucket Tasks.Bucket
---@param rel string
---@param task Tasks.Task
---@param date string
---@return string
local function readme_row(bucket, rel, task, date)
  local content = cell(task.title)
  if task.summary ~= "" and task.summary ~= task.title then
    local summary = task.summary
    if vim.fn.strchars(summary) > 120 then
      summary = vim.fn.strcharpart(summary, 0, 119) .. "…"
    end
    content = content .. " — " .. cell(summary)
  end
  -- The names are `YYYY-MM-DD_<slug>` with a validated slug: nothing to escape.
  local filename = rel:match("([^/]*)$")
  return ("| [`%s`](./%s/%s) | %s (%s) |"):format(filename, bucket, rel, content, date)
end

---Add `row` to the `## <bucket> (N)` section of a `Backlog/README.md` text.
---
---A section holding the `_noch leer_` placeholder gets a table instead; a
---missing section is appended. The row goes first (newest on top), the count is
---recomputed from the table, the file's line ending and its trailing newline
---are kept, and a row for the same file that is already there changes nothing.
---@param text string
---@param bucket Tasks.Bucket
---@param filename string
---@param row string
---@return string text
---@return boolean changed
function M.readme_add_row(text, bucket, filename, row)
  local eol = fsio.eol_of(text)
  local body = fsio.lf(text)
  local trailing = body:sub(-1) == "\n"
  if trailing then
    body = body:sub(1, -2)
  end
  local lines = vim.split(body, "\n", { plain = true })
  local marker = ("(./%s/%s)"):format(bucket, filename)
  local table_head = { "| Datei | Inhalt |", "|---|---|" }

  local heading
  for i, line in ipairs(lines) do
    if line:match("^##%s+" .. bucket .. "%f[%W]") then
      heading = i
      break
    end
  end

  if not heading then
    if #lines > 0 and lines[#lines] ~= "" then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = ("## %s (1)"):format(bucket)
    lines[#lines + 1] = ""
    lines[#lines + 1] = table_head[1]
    lines[#lines + 1] = table_head[2]
    lines[#lines + 1] = row
  else
    local last = #lines
    for i = heading + 1, #lines do
      if lines[i]:match("^##%s") then
        last = i - 1
        break
      end
    end
    local sep, placeholder
    for i = heading + 1, last do
      if lines[i]:find(marker, 1, true) then
        return text, false
      end
      if not sep and lines[i]:match("^|%s*%-%-%-") then
        sep = i
      end
      if not placeholder and trim(lines[i]) == "_noch leer_" then
        placeholder = i
      end
    end
    if sep then
      table.insert(lines, sep + 1, row)
    elseif placeholder then
      lines[placeholder] = table_head[1]
      table.insert(lines, placeholder + 1, table_head[2])
      table.insert(lines, placeholder + 2, row)
    else
      -- A section with neither a table nor the placeholder: start the table
      -- after the heading, separated by a blank line.
      table.insert(lines, heading + 1, "")
      table.insert(lines, heading + 2, table_head[1])
      table.insert(lines, heading + 3, table_head[2])
      table.insert(lines, heading + 4, row)
    end
    -- Recount the rows of that section for the heading.
    local count, from, to = 0, heading + 1, #lines
    for i = heading + 1, #lines do
      if lines[i]:match("^##%s") then
        to = i - 1
        break
      end
    end
    local after_sep = false
    for i = from, to do
      if lines[i]:match("^|%s*%-%-%-") then
        after_sep = true
      elseif after_sep and lines[i]:match("^|") then
        count = count + 1
      end
    end
    lines[heading] = ("## %s (%d)"):format(bucket, count)
  end

  local out = table.concat(lines, "\n") .. (trailing and "\n" or "")
  if eol == "\r\n" then
    out = out:gsub("\n", "\r\n")
  end
  return out, true
end

-- ── done ─────────────────────────────────────────────────────────────────────

---Call an `fsio` function the way a rollback needs it: never raise, answer
---`ok, err`.
---@param fn fun(...): boolean|nil, string|nil
---@param ... any
---@return boolean ok
---@return string|nil err
local function attempt(fn, ...)
  local called, ok, err = pcall(fn, ...)
  if not called then
    return false, tostring(ok)
  end
  return ok == true, err
end

---@class Tasks.DoneOpts
---@field root? string
---@field done_in? string|string[]   # Commit(s) that delivered the task.
---@field date? string               # `YYYY-MM-DD` filename prefix (default: today).
---@field today? string              # Sets `updated` (default: today).
---@field index? boolean             # Regenerate the area index (default true).
---@field checkpoint_dir? string     # Where the safety snapshot goes.

---Finish an open task (rule R6): set `status: done` and `done_in`, move the
---file to `Backlog/FEATURES` (feature, idea, research) or `Backlog/TASKS` (task,
---bug) as `YYYY-MM-DD_<slug>.md`, add its row to that `Backlog/README.md`, and
---regenerate the area index. A folder task moves as a whole, to
---`YYYY-MM-DD_<slug>/YYYY-MM-DD_<slug>.md`; a failure puts the folder back.
---
---The finished copy, the README and the index are snapshotted first; if any step
---fails they are restored byte-exact. The task file is not part of the snapshot (a
---restore would overwrite what was written to it meanwhile): when it changed since
---it was read, `done` stops before removing it; when it was already removed it is
---written back from the text read at the start. What cannot be undone is named in
---the error as `rollback incomplete: <path>`. A task that is already finished answers
---`already = true` and changes nothing; if an earlier run died between creating
---the Backlog file and deleting the old one, this run completes it.
---@param id string
---@param opts? Tasks.DoneOpts
---@return table|nil result
---@return string|nil err
function M.done(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local area, slug, id_err = vault.parse_id(id)
  if not area or not slug then
    return nil, id_err or ("expected <area>/<slug>, got " .. tostring(id))
  end

  local task, find_err = scan.find(id, { root = root })
  if not task then
    local finished = scan.find_done(id, { root = root })
    if finished then
      return { id = id, already = true, to = finished.path }, nil
    end
    -- `find_err` is "no such open task" or the more useful "exists as file and as folder".
    return nil, find_err or ("no such open task: " .. id)
  end

  local kind = task.kind or "task"
  local bucket = vault.BUCKET_OF_KIND[kind]
  if not bucket then
    return nil,
      ("task has unknown kind '%s'; fix it first (tasks set %s kind=...)"):format(kind, id)
  end
  local today = opts.today or model.today()
  local date = opts.date or today
  if not (model.is_date(today) and model.is_date(date)) then
    return nil, "date must be YYYY-MM-DD"
  end

  local patch = { { "status", "done" } }
  if opts.done_in ~= nil then
    local list, lerr = string_list(opts.done_in, "done_in")
    if not list then
      return nil, lerr
    end
    if #list > 0 then
      patch[#patch + 1] = { "done_in", table.concat(list, ", ") }
    end
  end
  patch[#patch + 1] = { "updated", today }

  local old_text, rd_err = fsio.read(task.path)
  if not old_text then
    return nil, "cannot read " .. task.path .. ": " .. tostring(rd_err)
  end
  local new_text, uerr = fm.update_text(old_text, patch)
  if not new_text then
    return nil, "cannot update " .. task.path .. ": " .. tostring(uerr)
  end

  local stem = date .. "_" .. slug
  local filename = stem .. ".md"
  local rel = task.folder and (stem .. "/" .. filename) or filename
  local target = vault.backlog_dir(root, area, bucket) .. "/" .. rel
  local src_dir = task.folder and fsio.dirname(task.path) or nil
  local target_dir = task.folder and fsio.dirname(target) or nil
  local resume = false
  local existing = scan.find_done(id, { root = root })
  if existing and existing.path ~= target then
    return nil, ("a finished task with this id already exists: %s"):format(existing.path)
  end
  if task.folder then
    if fsio.is_dir(target_dir) then
      return nil, "target folder exists: " .. target_dir
    end
  elseif fsio.is_file(target) then
    local present = fsio.read(target)
    if present ~= new_text then
      return nil, "target exists with different content: " .. target
    end
    resume = true
  end

  local readme_path = vault.backlog_readme(root, area)
  local readme_old = fsio.is_file(readme_path) and fsio.read(readme_path) or nil
  local readme_new, readme_state = readme_old, "missing"
  if readme_old then
    local changed
    readme_new, changed =
      M.readme_add_row(readme_old, bucket, rel, readme_row(bucket, rel, task, date))
    readme_state = changed and "updated" or "unchanged"
  end

  -- The task file itself is not snapshotted: restoring it from a snapshot would overwrite whatever
  -- was written to it since. It is only ever put back by hand, and only after `done` removed it.
  local tracked = { vault.index_path(root, area) }
  if not task.folder then
    tracked = { target, vault.index_path(root, area) }
  end
  if readme_old then
    tracked[#tracked + 1] = readme_path
  end
  local cp, cerr = checkpoint.create(tracked, { dir = opts.checkpoint_dir })
  if not cp then
    return nil, "cannot snapshot before moving: " .. tostring(cerr)
  end

  local moved, removed_original = false, false
  -- Someone (the editor, another `tasks` run) may have written the task file since it was read
  -- above; finishing would then drop that change. Looked at right before the original goes.
  local function changed_meanwhile()
    return fsio.read(task.path) ~= old_text
  end
  local changed_msg = ("%s changed while it was being finished; nothing was changed, run done again"):format(
    task.path
  )
  local function run()
    if task.folder then
      if changed_meanwhile() then
        return nil, changed_msg
      end
      local made, merr = fsio.mkdirp(fsio.dirname(target_dir))
      if not made then
        return nil, "cannot create " .. fsio.dirname(target_dir) .. ": " .. tostring(merr)
      end
      local renamed, rerr2 = fsio.rename(src_dir, target_dir)
      if not renamed then
        return nil, "cannot move " .. src_dir .. ": " .. tostring(rerr2)
      end
      moved = true
      local wrote, werr = fsio.write_atomic(target, new_text)
      if not wrote then
        return nil, "cannot write " .. target .. ": " .. tostring(werr)
      end
      local old_name = target_dir .. "/" .. slug .. ".md"
      local removed, rm_err = fsio.remove(old_name)
      if not removed then
        return nil, "cannot remove " .. old_name .. ": " .. tostring(rm_err)
      end
    else
      if not resume then
        local ok, err = fsio.create_exclusive(target, new_text)
        if not ok then
          return nil, "cannot create " .. target .. ": " .. tostring(err)
        end
      end
      if changed_meanwhile() then
        return nil, changed_msg
      end
      local removed, rm_err = fsio.remove(task.path)
      if not removed then
        return nil, "cannot remove " .. task.path .. ": " .. tostring(rm_err)
      end
      removed_original = true
    end
    if readme_old and readme_new ~= readme_old then
      local ok, err = fsio.write_atomic(readme_path, readme_new)
      if not ok then
        return nil, "cannot write " .. readme_path .. ": " .. tostring(err)
      end
    end
    if opts.index ~= false then
      local res, ierr = index.write_area(area, { root = root })
      if not res then
        return nil, "cannot regenerate the index: " .. tostring(ierr)
      end
      return res, nil
    end
    return true, nil
  end

  local ok, res, err = pcall(run)
  if not ok then
    err = tostring(res)
    res = nil
  end
  if not res then
    -- What could not be undone, named in the message (a silent half state is the worst answer).
    local stuck = {}
    if moved then
      -- Put the folder back exactly as it was: old file name, old text. The finished copy
      -- goes only after the original is back: until then it may be the only holder of the text.
      local old_name = target_dir .. "/" .. slug .. ".md"
      -- Still there (the failure came before it was removed): it holds the original, maybe newer
      -- than `old_text` -- never overwrite it. Only a removed one is written back.
      local wrote, w_err = true, nil
      if not fsio.is_file(old_name) then
        wrote, w_err = attempt(fsio.write_atomic, old_name, old_text)
      end
      if wrote then
        attempt(fsio.remove, target)
        local back, b_err = attempt(fsio.rename, target_dir, src_dir)
        if not back then
          stuck[#stuck + 1] = ("%s (cannot move it back to %s: %s)"):format(
            target_dir,
            src_dir,
            tostring(b_err)
          )
        end
      else
        stuck[#stuck + 1] = ("%s (cannot restore %s: %s)"):format(
          target_dir,
          old_name,
          tostring(w_err)
        )
      end
    end
    if removed_original then
      -- Back before the finished copy is dropped (the snapshot restore below deletes it). A file
      -- that exists again was written by someone since: theirs stays.
      local back, b_err = attempt(fsio.create_exclusive, task.path, old_text)
      if not back and not fsio.is_file(task.path) then
        stuck[#stuck + 1] = ("%s (cannot restore it: %s; the finished copy %s holds the text)"):format(
          task.path,
          tostring(b_err),
          target
        )
        -- `target` is now the only holder of the text: the restore must not delete it.
        for i = #cp.entries, 1, -1 do
          local entry = cp.entries[i]
          if entry.path == target then
            if entry.backup then
              pcall(os.remove, entry.backup)
            end
            table.remove(cp.entries, i)
          end
        end
      end
    end
    local _, restore_errors = checkpoint.restore(cp)
    checkpoint.discard(cp)
    for _, e in ipairs(restore_errors) do
      stuck[#stuck + 1] = e.path
    end
    local msg = tostring(err)
    if #stuck > 0 then
      msg = msg .. " (rollback incomplete: " .. table.concat(stuck, ", ") .. ")"
    end
    return nil, msg
  end
  checkpoint.discard(cp)

  return {
    id = id,
    area = area,
    from = task.path,
    to = target,
    bucket = bucket,
    resumed = resume,
    readme = readme_state,
    index = type(res) == "table" and res or nil,
  },
    nil
end

-- ── folder tasks: folderize and attach ───────────────────────────────────────

---Image extensions an attached file gets `![]()` for.
---@type table<string, boolean>
local IMAGE_EXT =
  { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true, bmp = true }

---Folder inside a folder task that `attach` puts files in.
M.ASSETS_DIR = "assets"

---Move a plain task file into its own folder: `tasks/<slug>.md` becomes
---`tasks/<slug>/<slug>.md`.
---@param root string
---@param task Tasks.Task
---@return string|nil path  the new task file
---@return string|nil err
local function to_folder(root, task)
  local dir = vault.task_dir(root, task.area, task.slug)
  if fsio.is_dir(dir) then
    return nil, "folder already exists: " .. dir
  end
  local made, merr = fsio.mkdirp(dir)
  if not made then
    return nil, "cannot create " .. dir .. ": " .. tostring(merr)
  end
  local dest = vault.folder_task_path(root, task.area, task.slug)
  local moved, rerr = fsio.rename(task.path, dest)
  if not moved then
    pcall((vim.uv or vim.loop).fs_rmdir, dir)
    return nil, "cannot move " .. task.path .. ": " .. tostring(rerr)
  end
  return dest, nil
end

---Undo `to_folder` after a failed `attach`: the task file goes back to
---`tasks/<slug>.md` and the folder `to_folder` made a moment ago is removed. The
---half-copied `asset` and the then empty `assets/` go first; `rmdir` only takes
---empty folders, so anything else that has appeared in there is never touched.
---@param plain string        the path the task had before
---@param folder_file string  the path `to_folder` gave it
---@param asset string        the file the failed copy may have left behind
---@return boolean ok
---@return string|nil err
local function undo_folder(plain, folder_file, asset)
  local dir = fsio.dirname(folder_file)
  local uv = vim.uv or vim.loop
  if fsio.is_file(asset) then
    pcall(fsio.remove, asset)
  end
  pcall(uv.fs_rmdir, dir .. "/" .. M.ASSETS_DIR)
  local moved, err = fsio.rename(folder_file, plain)
  if not moved then
    return false, err
  end
  pcall(uv.fs_rmdir, dir)
  return true, nil
end

---Turn an open task into a folder task so assets can be attached. A task that
---already is one is left alone (`changed = false`).
---@param id string
---@param opts? { root?: string, index?: boolean }
---@return { id: string, path: string, changed: boolean, index?: Tasks.IndexResult, index_err?: string }|nil result
---@return string|nil err
function M.folderize(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local task, ferr = scan.find(id, { root = root })
  if not task then
    return nil, ferr
  end
  if task.folder then
    return { id = task.id, path = task.path, changed = false }, nil
  end
  local dest, err = to_folder(root, task)
  if not dest then
    return nil, err
  end
  local result = { id = task.id, path = dest, changed = true }
  if opts.index ~= false then
    result.index, result.index_err = index.write_area(task.area, { root = root })
  end
  return result, nil
end

---A file name that is safe inside `assets/`: spaces become hyphens; letters,
---digits, `_`, `.`, `-` and non-ASCII bytes stay; no separators, no `..`.
---@param name any
---@return string|nil name
---@return string|nil err
local function asset_name(name)
  if type(name) ~= "string" then
    return nil, "asset name must be text"
  end
  local n = trim(name):gsub("%s+", "-")
  if n == "" then
    return nil, "asset name is empty"
  end
  -- Bytes 128-255 pass (non-ASCII letters), but not the C1 controls (`\194\128`..`\194\159`: CSI and OSC for
  -- terminals that act on them): the name goes into the Markdown link and the file system as it is.
  if
    n:find("..", 1, true)
    or n:find("\194[\128-\159]")
    or not n:match("^[%w_\128-\255][%w_.%-\128-\255]*$")
  then
    return nil, "asset name may only use letters, digits, _ . - (got '" .. n .. "'; pass --name=)"
  end
  -- Windows drops a trailing dot, so the link would name a file that is not there.
  if n:sub(-1) == "." then
    return nil, "asset name must not end with a dot (got '" .. n .. "'; pass --name=)"
  end
  -- `nul` and friends are devices there: the "copy" would succeed and store nothing.
  if vault.is_reserved_name(n) then
    return nil, ("asset name '%s' is a reserved Windows device name (pass --name=)"):format(n)
  end
  return n, nil
end

---Copy a file into a task's `assets/` folder and give back the Markdown to link
---it. A plain task file becomes a folder task first. `opts.name` renames the
---copy; an asset of that name that already exists is an error, never replaced.
---@param id string
---@param src string                 # The file to attach.
---@param opts? { root?: string, today?: string, name?: string, index?: boolean }
---@return { id: string, path: string, asset: string, rel: string, link: string, folderized: boolean, index?: Tasks.IndexResult, index_err?: string }|nil result
---@return string|nil err
function M.attach(id, src, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if type(src) ~= "string" or src == "" then
    return nil, "attach needs a file"
  end
  src = fsio.norm(src)
  if not fsio.is_file(src) then
    return nil, "not a file: " .. src
  end
  local name, nerr = asset_name(opts.name or (src:match("([^/]*)$") or src))
  if not name then
    return nil, nerr
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local task, ferr = scan.find(id, { root = root })
  if not task then
    return nil, ferr
  end

  local path, folderized = task.path, false
  if not task.folder then
    local dest, err = to_folder(root, task)
    if not dest then
      return nil, err
    end
    path, folderized = dest, true
  end
  local asset = fsio.dirname(path) .. "/" .. M.ASSETS_DIR .. "/" .. name
  local copied, cerr = fsio.copy(src, asset)
  if not copied then
    local why = cerr == "exists" and ("asset exists: " .. asset .. " (pass --name=)")
      or ("cannot copy to " .. asset .. ": " .. tostring(cerr))
    if not folderized then
      return nil, why
    end
    -- The conversion was only a means to an end: a failed attach leaves the task as it was.
    local undone, uerr = undo_folder(task.path, path, asset)
    if undone then
      return nil, why
    end
    -- It stays a folder task, so keep the index true to what is on disk.
    if opts.index ~= false then
      index.write_area(task.area, { root = root })
    end
    return nil,
      ("%s (the task was turned into a folder task; moving it back failed: %s)"):format(
        why,
        tostring(uerr)
      )
  end

  local rel = M.ASSETS_DIR .. "/" .. name
  local ext = name:match("%.([%w]+)$")
  local is_image = ext ~= nil and IMAGE_EXT[ext:lower()] == true
  local link = (is_image and "![%s](%s)" or "[%s](%s)"):format(name, rel)
  fm.update(path, { { "updated", today } })

  local result = {
    id = task.id,
    path = path,
    asset = asset,
    rel = rel,
    link = link,
    folderized = folderized,
  }
  if opts.index ~= false then
    result.index, result.index_err = index.write_area(task.area, { root = root })
  end
  return result, nil
end

return M
