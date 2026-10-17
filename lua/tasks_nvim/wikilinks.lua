---@module 'tasks_nvim.wikilinks'
---@brief Obsidian wikilinks in `blocked_by`, `after` and `plan`: read them as task ids, write ids as wikilinks on request.
---@description
--- A reference to a task or a plan is a plain id (`<area>/<slug>`) or, as Obsidian writes it, a wikilink in quotes:
---
---  - `"[[<area>/<slug>]]"`, also with an alias (`"[[<area>/<slug>|Text]]"`) or a heading (`#...`): the id;
---  - `"[[<area>/ROADMAP/tasks/<slug>]]"` and the other vault paths of a task or plan file (folder task, plan file,
---    `Backlog/<bucket>/YYYY-MM-DD_<slug>`), with or without `.md`: the id of that file;
---  - `"[[<slug>]]"` (Obsidian's "shortest path"): the one task or plan of that slug over every area. It needs the
---    vault, so a file is read without it (`read` answers `slug`) and `resolve` settles it after the scan; a slug that
---    names nothing (`wikilink-dangling`) or several ids (`wikilink-ambiguous`, with the candidates) stays unresolved.
---
--- The written form is a switch (`setup({ links = "plain" | "wikilink" })`, `$TASKS_LINKS` for the headless CLI):
--- `plain` (the default) writes ids, `wikilink` writes `[[<slug>]]` when that slug is unique in the vault and
--- otherwise the vault path of the file with the id as alias (`[[<area>/ROADMAP/tasks/<slug>|<area>/<slug>]]`), which
--- Obsidian resolves too. A value the file already holds keeps its form (`forms`).
---
--- Not its job: the frontmatter syntax (`lib.nvim.markdown.frontmatter` quotes `[[...]]`), what an id means (`check`,
--- `plan`).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---The written forms `setup({ links = ... })` takes.
---@type string[]
M.MODES = { "plain", "wikilink" }

---The fields whose values are references.
---@type string[]
M.FIELDS = { "blocked_by", "after", "plan" }

local DATE_PREFIX = "^%d%d%d%d%-%d%d%-%d%d_"

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Whether `s` is written as a wikilink (`[[...]]`).
---@param s any
---@return boolean
function M.is_wikilink(s)
  return type(s) == "string" and #s >= 4 and s:sub(1, 2) == "[[" and s:sub(-2) == "]]"
end

---@param area string
---@param slug string
---@return "id"|"bad" kind
---@return string value
local function as_id(area, slug)
  local id = area .. "/" .. slug
  local _, s, err = vault.parse_id(id)
  if err or not s then
    return "bad", err or ("expected <area>/<slug>, got " .. id)
  end
  return "id", id
end

---What one reference names.
---
---  - `plain`: no wikilink; `value` is the text as it is (the caller checks it as an id)
---  - `id`: a wikilink with an id or a vault path; `value` is the id
---  - `slug`: a wikilink with a bare slug; `value` is the slug (see `resolve`)
---  - `bad`: a wikilink that names no id; `value` says why
---@param raw string
---@return "plain"|"id"|"slug"|"bad" kind
---@return string value
function M.read(raw)
  if not M.is_wikilink(raw) then
    return "plain", raw
  end
  local inner = raw:sub(3, -3)
  if inner:find("[%[%]]") then
    return "bad", "malformed wikilink: " .. raw
  end
  -- `[[target|alias]]`, `[[target#heading]]`: only the target names the file
  local target = trim((inner:match("^([^|]*)") or ""):gsub("#.*$", ""))
  target = target:gsub("%.md$", "")
  if target == "" then
    return "bad", "empty wikilink: " .. raw
  end
  local area, a, b = target:match("^([^/]+)/ROADMAP/tasks/([^/]+)/([^/]+)$")
  if area and a == b then
    return as_id(area, a)
  end
  area, a = target:match("^([^/]+)/ROADMAP/tasks/([^/]+)$")
  if not area then
    area, a = target:match("^([^/]+)/ROADMAP/plans/([^/]+)$")
  end
  if area then
    return as_id(area, a)
  end
  local bucket
  area, bucket, a, b = target:match("^([^/]+)/Backlog/([^/]+)/([^/]+)/([^/]+)$")
  if not (area and a == b) then
    area, bucket, a = target:match("^([^/]+)/Backlog/([^/]+)/([^/]+)$")
  end
  if area and (bucket == "TASKS" or bucket == "FEATURES") then
    return as_id(area, (a:gsub(DATE_PREFIX, "")))
  end
  area, a = target:match("^([^/]+)/([^/]+)$")
  if area then
    return as_id(area, a)
  end
  if not target:find("/", 1, true) then
    local slug = target:gsub(DATE_PREFIX, "")
    if vault.valid_slug(slug) then
      return "slug", slug
    end
    return "bad", "invalid slug in wikilink: " .. raw
  end
  return "bad", "wikilink names no task (expected [[<area>/<slug>]] or [[<slug>]]): " .. raw
end

---Split a typed list of references (`a/b, [[c]], "[[d|D]]"`, one pair of brackets around it as the file shows it)
---into its items. A comma inside `[[...]]` or inside quotes does not split; quotes around an item are dropped.
---@param s string
---@return string[]
function M.split(s)
  s = trim(s)
  -- `[a, b]` / `["[[x]]", y]` / `[[[x]], y]`: the outer brackets of a list; `[[x]], y` has none
  if s:sub(1, 1) == "[" and (s:sub(2, 2) ~= "[" or s:sub(3, 3) == "[") and s:sub(-1) == "]" then
    local body = s:sub(2, -2)
    -- `[[x]]` alone keeps its brackets: the last `]` belongs to the link, not to a list
    if not (s:sub(2, 2) == "[" and not M.is_wikilink(trim(body))) then
      s = body
    end
  end
  local out, buf = {}, {}
  local i, n = 1, #s
  local function flush()
    local item = trim(table.concat(buf))
    local q = item:sub(1, 1)
    if (q == '"' or q == "'") and #item >= 2 and item:sub(-1) == q then
      item = trim(item:sub(2, -2))
    end
    if item ~= "" then
      out[#out + 1] = item
    end
    buf = {}
  end
  while i <= n do
    local c = s:sub(i, i)
    if s:sub(i, i + 1) == "[[" then
      local close = s:find("]]", i + 2, true)
      local stop = close and (close + 1) or n
      buf[#buf + 1] = s:sub(i, stop)
      i = stop + 1
    elseif c == '"' or c == "'" then
      local close = s:find(c, i + 1, true)
      local stop = close or n
      buf[#buf + 1] = s:sub(i, stop)
      i = stop + 1
    elseif c == "," then
      flush()
      i = i + 1
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return out
end

-- ── the vault's slugs ───────────────────────────────────────────────────────

---@param dir string
---@return { name: string, kind: string }[]
local function entries(dir)
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
    if name:sub(1, 1) ~= "." then
      if not kind then
        local st = uv.fs_stat(dir .. "/" .. name)
        kind = st and st.type or "unknown"
      end
      out[#out + 1] = { name = name, kind = kind }
    end
  end
  return out
end

---@class Tasks.LinkIndex
---@field by_slug table<string, string[]>  # slug -> the ids of that slug, sorted
---@field path_of table<string, string>    # id -> the vault path of its file, without `.md` (an open file first)

---Every task and plan id of the vault by slug, from the folder listings alone (nothing is read): open tasks (file and
---folder tasks), plan files, and the finished ones in `Backlog/TASKS` and `Backlog/FEATURES`.
---@param root string
---@return Tasks.LinkIndex
function M.build_index(root)
  local by_slug, path_of = {}, {}
  ---@param area string
  ---@param slug string
  ---@param rel string
  local function add(area, slug, rel)
    if not vault.valid_slug(slug) then
      return
    end
    local id = area .. "/" .. slug
    if path_of[id] == nil then
      path_of[id] = rel
      local list = by_slug[slug] or {}
      list[#list + 1] = id
      by_slug[slug] = list
    end
  end
  for _, a in ipairs(vault.areas(root)) do
    local area = a.name
    local tasks_dir = vault.tasks_dir(root, area)
    for _, e in ipairs(entries(tasks_dir)) do
      local slug = e.name:match("^(.+)%.md$")
      if e.kind == "file" and slug then
        add(area, slug, area .. "/ROADMAP/tasks/" .. slug)
      elseif
        e.kind == "directory" and fsio.is_file(tasks_dir .. "/" .. e.name .. "/" .. e.name .. ".md")
      then
        add(area, e.name, area .. "/ROADMAP/tasks/" .. e.name .. "/" .. e.name)
      end
    end
    for _, e in ipairs(entries(vault.plans_dir(root, area))) do
      local slug = e.name:match("^(.+)%.md$")
      if e.kind == "file" and slug then
        add(area, slug, area .. "/ROADMAP/plans/" .. slug)
      end
    end
    for _, bucket in ipairs({ "FEATURES", "TASKS" }) do
      local dir = vault.backlog_dir(root, area, bucket)
      for _, e in ipairs(entries(dir)) do
        local base = area .. "/Backlog/" .. bucket .. "/"
        local stem = e.name:match("^(.+)%.md$")
        if e.kind == "file" and stem and e.name ~= "README.md" then
          add(area, (stem:gsub(DATE_PREFIX, "")), base .. stem)
        elseif e.kind == "directory" then
          add(area, (e.name:gsub(DATE_PREFIX, "")), base .. e.name .. "/" .. e.name)
        end
      end
    end
  end
  for _, list in pairs(by_slug) do
    table.sort(list)
  end
  return { by_slug = by_slug, path_of = path_of }
end

---@class Tasks.LinkResolver
---@field root string
---@field candidates fun(slug: string): string[]  # the ids of a slug, sorted (empty: none)
---@field path fun(id: string): string|nil         # the vault path of the id's file, without `.md`

---A resolver over the vault `root`. The index is built on the first question only (a vault without bare-slug
---wikilinks never lists a folder for it) and once per read scope (`fsio.scope_memo`).
---@param root string|nil
---@return Tasks.LinkResolver
function M.resolver(root)
  local index
  local function get()
    if not index then
      if not root then
        index = { by_slug = {}, path_of = {} }
      else
        index = fsio.scope_memo("wikilinks:" .. root, function()
          return M.build_index(root)
        end)
      end
    end
    return index
  end
  return {
    root = root or "",
    candidates = function(slug)
      return get().by_slug[slug] or {}
    end,
    path = function(id)
      return get().path_of[id]
    end,
  }
end

---@class Tasks.LinkProblem
---@field code "wikilink-dangling"|"wikilink-ambiguous"
---@field field string           # `blocked_by`, `after` or `plan`
---@field raw string             # the value as written
---@field candidates string[]    # the ids the slug names (empty for a dangling one)

---Settle the bare-slug wikilinks `model.parse_text` left (`task.wikilinks`): a slug of exactly one id becomes that id
---in `blocked_by` / `after` / `plan`; any other stays as written (a blocker that is neither open nor finished: the
---task waits, like on a dangling id) and is named in `task.link_problems`. Changes the tasks in place.
---@param tasks Tasks.Task[]
---@param resolver Tasks.LinkResolver
---@return Tasks.Task[] tasks
function M.resolve(tasks, resolver)
  for _, t in ipairs(tasks) do
    local pending = t.wikilinks
    if pending then
      t.wikilinks = nil
      local problems = {}
      for _, p in ipairs(pending) do
        local ids = resolver.candidates(p.slug)
        if #ids == 1 then
          if p.field == "plan" then
            t.plan = ids[1]
          else
            t[p.field][p.index] = ids[1]
          end
        else
          problems[#problems + 1] = {
            code = #ids == 0 and "wikilink-dangling" or "wikilink-ambiguous",
            field = p.field,
            raw = p.raw,
            candidates = vim.list_slice(ids, 1),
          }
        end
      end
      t.link_problems = #problems > 0 and problems or nil
    end
  end
  return tasks
end

---The ids of the tasks that name `slug` as a bare `[[slug]]` in `blocked_by`, `after` or `plan`, read from the raw
---frontmatter (`task.meta`), so it does not matter whether the scan could resolve the link. Sorted, each id once.
---@param tasks Tasks.Task[]
---@param slug string
---@param skip? string  # an id to leave out (the task that was just created)
---@return string[]
function M.slug_referrers(tasks, slug, skip)
  local out, seen = {}, {}
  for _, t in ipairs(tasks) do
    local meta = t.meta or {}
    for _, field in ipairs(M.FIELDS) do
      local v = meta[field]
      for _, raw in ipairs(type(v) == "table" and v or { v }) do
        if type(raw) == "string" and t.id ~= skip and not seen[t.id] then
          local kind, value = M.read(trim(raw))
          if kind == "slug" and value == slug then
            seen[t.id] = true
            out[#out + 1] = t.id
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

---@class Tasks.NewAmbiguity
---@field slug string        # the slug the new task shares
---@field ids string[]       # the ids `[[slug]]` names now (the old one and the new one), sorted
---@field tasks string[]     # the tasks whose `[[slug]]` named the old id and is `wikilink-ambiguous` now

---The warning for a new task whose slug turned bare `[[slug]]` links into `wikilink-ambiguous` ones.
---@param amb Tasks.NewAmbiguity
---@return string
function M.ambiguity_message(amb)
  return ("[[%s]] now names %s: wikilink-ambiguous in %s (write the id there)"):format(
    amb.slug,
    table.concat(amb.ids, " and "),
    table.concat(amb.tasks, ", ")
  )
end

---The id one reference names, or nil (a malformed one, a slug that is not exactly one id).
---@param raw string
---@param resolver? Tasks.LinkResolver
---@return string|nil id
function M.id_of(raw, resolver)
  local kind, value = M.read(raw)
  if kind == "plain" or kind == "id" then
    return value
  elseif kind == "slug" and resolver then
    local ids = resolver.candidates(value)
    return #ids == 1 and ids[1] or nil
  end
  return nil
end

---Read one typed reference (a CLI or `set` value) as an id: a plain id is checked, a wikilink resolved.
---@param raw string
---@param what string     # the field, for the message
---@param resolver? Tasks.LinkResolver
---@return string|nil id
---@return string|nil err
function M.typed_id(raw, what, resolver)
  local kind, value = M.read(raw)
  if kind == "plain" or kind == "id" then
    local _, slug, err = vault.parse_id(value)
    if err or not slug then
      return nil, what .. ": " .. (err or ("expected <area>/<slug>, got " .. value))
    end
    return value, nil
  elseif kind == "bad" then
    return nil, what .. ": " .. value
  end
  if not resolver then
    return nil, ("%s: %s needs the vault to be resolved"):format(what, raw)
  end
  local ids = resolver.candidates(value)
  if #ids == 1 then
    return ids[1], nil
  elseif #ids == 0 then
    return nil, ("%s: %s names no task or plan (wikilink-dangling)"):format(what, raw)
  end
  return nil,
    ("%s: %s names several tasks, write one of them (wikilink-ambiguous): %s"):format(
      what,
      raw,
      table.concat(ids, ", ")
    )
end

---The written form `opts.links`, `setup({ links })` or `$TASKS_LINKS` asks for: `wikilink` when one of them says so
---(in that order: an explicit `opts.links` wins), else `plain`.
---@param opts? { links?: string }
---@return "plain"|"wikilink"
function M.mode(opts)
  local asked = opts and opts.links
  if asked == "plain" or asked == "wikilink" then
    return asked
  end
  if require("tasks_nvim.config").get().links == "wikilink" then
    return "wikilink"
  end
  if vim.env.TASKS_LINKS == "wikilink" then
    return "wikilink"
  end
  return "plain"
end

---How the id `id` is written in `mode`. `plain`: the id. `wikilink`: `[[<slug>]]` when the slug names this id only,
---else `[[<vault path>|<id>]]` when the file exists, else `[[<id>]]`.
---@param id string
---@param mode "plain"|"wikilink"
---@param resolver? Tasks.LinkResolver
---@return string
function M.render(id, mode, resolver)
  if mode ~= "wikilink" then
    return id
  end
  local _, slug = vault.parse_id(id)
  if not slug or not resolver then
    return "[[" .. id .. "]]"
  end
  local ids = resolver.candidates(slug)
  if #ids == 1 and ids[1] == id then
    return "[[" .. slug .. "]]"
  end
  local rel = resolver.path(id)
  if rel then
    return "[[" .. rel .. "|" .. id .. "]]"
  end
  return "[[" .. id .. "]]"
end

---The writer of one field: for each id the text to write. An id the file already names (`current`, the raw value of
---the field) keeps the form it has there, an id given as a wikilink (`typed`) keeps that one, any other is written in
---`mode` (`render`).
---@param current any            # the field's raw frontmatter value (string, list or nil)
---@param mode "plain"|"wikilink"
---@param resolver? Tasks.LinkResolver
---@param typed? table<string, string>  # id -> the wikilink it was given as
---@return fun(id: string): string
function M.forms(current, mode, resolver, typed)
  local by_id = {}
  local items = type(current) == "table" and current or { current }
  for _, raw in ipairs(items) do
    if type(raw) == "string" then
      raw = trim(raw)
      local id = raw ~= "" and M.id_of(raw, resolver) or nil
      if id and by_id[id] == nil then
        by_id[id] = raw
      end
    end
  end
  return function(id)
    return by_id[id] or (typed and typed[id]) or M.render(id, mode, resolver)
  end
end

return M
