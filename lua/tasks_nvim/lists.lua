---@module 'tasks_nvim.lists'
---@brief Named lists: a filter combination plus a sort order (and an area) with a name, from three sources.
---@description
--- A list is "all open tasks with effort <= S and value >= 4, best return first" under a name, so nobody types the
--- filter twice. Its fields are the option words the command line already knows, written as strings:
---
---     { status = "open,doing", effort = "<=S", value = ">=4", sort = "roi", desc = "small and worth it" }
---
--- Fields: `status prio effort kind category severity value actor tag stale plan phase` (strings, `prio` / `value` /
--- `stale` may be numbers), `blocked unestimated stale_refs quick_win` (booleans), `readiness` (`ready` | `waiting`),
--- `sort` (`model.SORTS`), `area` (one area, default all) and `desc` (one line of text).
---
--- Three sources, the later one wins by name:
---  1. built-in examples (`BUILTIN`);
---  2. saved lists: a small state file, written by `save` (the dashboard, `tasks lists save`);
---  3. `setup({ lists = {...} })`: your config. A saved list of the same name is shadowed and `all()` says so; a
---     config list cannot be changed or deleted from here (edit the config).
---
--- Every definition is checked by the same parser as the command line (`filter_opts.parse`, `model.parse_sort`) and a
--- complaint names the list: a typo is an error, never a silently empty list.
---
--- Not its job: running a list (`ui.cmd`, `cli`), the dashboard menu (`ui.dash`), the filter semantics (`model`).

local filter_opts = require("tasks_nvim.filter_opts")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")

local uv = vim.uv or vim.loop

local M = {}

---Format version of the state file.
M.VERSION = 1

---Longest list name; shorter keeps the menus and the command line readable.
M.MAX_NAME = 40

---A saved-lists file bigger than this is not ours (it counts as corrupt and is never read whole).
M.MAX_FILE_BYTES = 256 * 1024

---Most lists one state file holds.
M.MAX_SAVED = 200

---@class Tasks.ListDef
---@field desc? string
---@field area? string
---@field sort? string
---@field status? string
---@field prio? string|integer
---@field effort? string
---@field kind? string
---@field category? string
---@field severity? string
---@field value? string|integer
---@field actor? string
---@field tag? string
---@field stale? string|integer
---@field plan? string
---@field phase? string
---@field blocked? boolean
---@field unestimated? boolean
---@field stale_refs? boolean
---@field quick_win? boolean
---@field readiness? "ready"|"waiting"

---@alias Tasks.ListSource "builtin"|"saved"|"config"

---@class Tasks.ListEntry
---@field name string
---@field def Tasks.ListDef
---@field source Tasks.ListSource

---@type table<string, "string"|"stringnum"|"boolean">
local FIELDS = {
  desc = "string",
  area = "string",
  sort = "string",
  status = "string",
  prio = "stringnum",
  effort = "string",
  kind = "string",
  category = "string",
  severity = "string",
  value = "stringnum",
  actor = "string",
  tag = "string",
  stale = "stringnum",
  plan = "string",
  phase = "string",
  blocked = "boolean",
  unestimated = "boolean",
  stale_refs = "boolean",
  quick_win = "boolean",
  readiness = "string",
}

---Fields in the order a definition is written out.
---@type string[]
M.FIELD_ORDER = {
  "desc",
  "area",
  "status",
  "prio",
  "effort",
  "kind",
  "category",
  "severity",
  "value",
  "actor",
  "tag",
  "stale",
  "plan",
  "phase",
  "blocked",
  "unestimated",
  "stale_refs",
  "quick_win",
  "readiness",
  "sort",
}

---The lists every install has. Replace one by saving or configuring a list of the same name.
---@type table<string, Tasks.ListDef>
M.BUILTIN = {
  ["quick-wins"] = {
    desc = "Value and effort at the quick-win thresholds, best return first",
    quick_win = true,
    status = "open,doing,decision",
    sort = "roi",
  },
  ["small-and-important"] = {
    desc = "Prio 1-2, effort S or less, startable now",
    status = "open,doing",
    prio = "<=2",
    effort = "<=S",
    readiness = "ready",
    sort = "prio-effort",
  },
  unestimated = {
    desc = "Missing an effort or a value (what `estimate --walk` asks for)",
    unestimated = true,
    status = "open,doing,decision",
  },
}

---@param name any
---@return boolean ok
---@return string|nil why
function M.valid_name(name)
  if type(name) ~= "string" or name == "" then
    return false, "a list needs a name"
  end
  if #name > M.MAX_NAME then
    return false, ("a list name is at most %d characters"):format(M.MAX_NAME)
  end
  if not name:match("^[%w][%w_-]*$") then
    return false, "a list name is letters, digits, `-` and `_` (starting with a letter or digit)"
  end
  return true, nil
end

---The option map `filter_opts.parse` takes.
---@param def Tasks.ListDef
---@return table
local function option_map(def)
  return {
    status = def.status,
    prio = def.prio,
    effort = def.effort,
    kind = def.kind,
    category = def.category,
    severity = def.severity,
    value = def.value,
    actor = def.actor,
    tag = def.tag,
    stale = def.stale,
    plan = def.plan,
    phase = def.phase,
    stale_refs = def.stale_refs == true,
    blocked = def.blocked == true,
    unestimated = def.unestimated == true,
    quick_win = def.quick_win == true,
  }
end

---Check one definition: the keys, their types, and that the whole thing parses. Returns the cleaned definition (only
---known keys, numbers turned into strings) or the reason, always naming the list.
---@param name string
---@param def any
---@return Tasks.ListDef|nil clean
---@return string|nil err
function M.normalize(name, def)
  local valid, why = M.valid_name(name)
  if not valid then
    return nil, ("list '%s': %s"):format(tostring(name), why)
  end
  if type(def) ~= "table" then
    return nil, ("list '%s': a list is a table of options, got %s"):format(name, type(def))
  end
  local clean = {}
  local unknown = {}
  for key, value in pairs(def) do
    local kind = type(key) == "string" and FIELDS[key] or nil
    if not kind then
      unknown[#unknown + 1] = tostring(key)
    elseif kind == "boolean" then
      if type(value) ~= "boolean" then
        return nil, ("list '%s': `%s` must be true or false, got %s"):format(name, key, type(value))
      end
      if value then
        clean[key] = true
      end
    elseif kind == "stringnum" and type(value) == "number" then
      clean[key] = tostring(value)
    elseif type(value) == "string" then
      if value ~= "" then
        clean[key] = value
      end
    else
      return nil, ("list '%s': `%s` must be a string, got %s"):format(name, key, type(value))
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    return nil, ("list '%s': unknown option(s): %s"):format(name, table.concat(unknown, ", "))
  end
  if clean.readiness ~= nil and clean.readiness ~= "ready" and clean.readiness ~= "waiting" then
    return nil,
      ('list \'%s\': `readiness` must be "ready" or "waiting", got %s'):format(
        name,
        clean.readiness
      )
  end
  if clean.desc and (clean.desc:find("[\r\n]") or #clean.desc > 200) then
    return nil, ("list '%s': `desc` is one line of at most 200 characters"):format(name)
  end
  local _, serr = model.parse_sort(clean.sort)
  if serr then
    return nil, ("list '%s': %s"):format(name, serr)
  end
  local _, ferr = filter_opts.parse(option_map(clean))
  if ferr then
    return nil, ("list '%s': %s"):format(name, ferr)
  end
  return clean, nil
end

---The filter, the sort order and the area a list stands for.
---@param def Tasks.ListDef  A definition that passed `normalize`.
---@return { filter: Tasks.Filter, sort: string, area: string|nil }|nil resolved
---@return string|nil err
function M.resolve(def)
  local filter, ferr = filter_opts.parse(option_map(def))
  if not filter then
    return nil, ferr
  end
  if def.readiness then
    filter.readiness = def.readiness
  end
  local order, serr = model.parse_sort(def.sort)
  if not order then
    return nil, serr
  end
  return { filter = filter, sort = order, area = def.area }, nil
end

---The list as option words of the command line (for `lists show`), in a fixed order.
---@param def Tasks.ListDef
---@return string[] words
function M.words(def)
  local out = {}
  for _, key in ipairs(M.FIELD_ORDER) do
    local v = def[key]
    if v ~= nil and key ~= "desc" and key ~= "area" then
      local flag = key:gsub("_", "-")
      if key == "readiness" then
        out[#out + 1] = "--" .. v
      elseif v == true then
        out[#out + 1] = "--" .. flag
      else
        out[#out + 1] = ("--%s=%s"):format(flag, tostring(v))
      end
    end
  end
  return out
end

---A definition from a live filter (what the dashboard shows): the inverse of `resolve`.
---@param filter Tasks.Filter|nil
---@param sort? string
---@param area? string
---@param desc? string
---@return Tasks.ListDef
function M.from_filter(filter, sort, area, desc)
  local f = filter or {}
  local function joined(list)
    return type(list) == "table" and #list > 0 and table.concat(list, ",") or nil
  end
  local def = {
    desc = desc,
    area = area,
    status = joined(f.status),
    kind = joined(f.kind),
    category = joined(f.category),
    severity = joined(f.severity),
    actor = joined(f.actor),
    tag = joined(f.tag),
    plan = joined(f.plan),
    phase = joined(f.phase),
    stale = f.stale and tostring(f.stale) or nil,
    stale_refs = f.stale_refs or nil,
    blocked = f.blocked or nil,
    unestimated = f.unestimated or nil,
    readiness = f.readiness,
    sort = (sort and sort ~= "default") and sort or nil,
  }
  if f.prio_max then
    def.prio = "<=" .. f.prio_max
  else
    def.prio = joined(f.prio)
  end
  if require("tasks_nvim.estimate").is_quick_win_filter(f) then
    -- Saved as the definition, so the list keeps following the thresholds in force.
    def.quick_win = true
  else
    def.effort = f.effort_max and ("<=" .. f.effort_max) or joined(f.effort)
    def.value = f.value_min and (">=" .. f.value_min) or joined(f.value)
  end
  return def
end

-- ── the state file ───────────────────────────────────────────────────────────

---@type string|nil
local override_path

---Pin the file for this process (nil clears it). Used by specs.
---@param path string|nil
function M.set_path(path)
  override_path = path and fsio.norm(path) or nil
end

---Where the saved lists live: `set_path`, `$TASKS_LISTS_FILE`, then `stdpath("state")/tasks/lists.json`.
---@return string
function M.path()
  if override_path and override_path ~= "" then
    return override_path
  end
  local env = vim.env.TASKS_LISTS_FILE
  if env and env ~= "" then
    return fsio.norm(env)
  end
  return fsio.norm(vim.fn.stdpath("state")) .. "/tasks/lists.json"
end

---Parse the file text. Lists that do not validate are skipped and reported, so one bad entry never costs the rest.
---@param text string|nil
---@return table<string, Tasks.ListDef>|nil lists
---@return string[] skipped  One message per rejected list.
---@return string|nil err    Set when the text is not a saved-lists file at all.
function M.decode(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil, {}, "empty file"
  end
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, {}, "not valid JSON"
  end
  if type(data.lists) ~= "table" then
    return nil, {}, "no lists table"
  end
  local out, skipped, n = {}, {}, 0
  for name, def in pairs(data.lists) do
    n = n + 1
    if n > M.MAX_SAVED then
      skipped[#skipped + 1] = ("more than %d lists: the rest is ignored"):format(M.MAX_SAVED)
      break
    end
    local clean, err = M.normalize(name, def)
    if clean then
      out[name] = clean
    else
      skipped[#skipped + 1] = err
    end
  end
  return out, skipped, nil
end

---@param lists table<string, Tasks.ListDef>
---@return string
function M.encode(lists)
  if next(lists) == nil then
    return '{"version":' .. M.VERSION .. ',"lists":{}}'
  end
  return vim.json.encode({ version = M.VERSION, lists = lists })
end

---@alias Tasks.ListsStatus "ok"|"missing"|"corrupt"|"unreadable"

---Read the saved lists. Never raises and never returns nil: a missing, corrupt or unreadable file is an empty table
---with the reason in `status`; rejected single lists are in `skipped`.
---@return table<string, Tasks.ListDef> lists
---@return Tasks.ListsStatus status
---@return string[] notes  Why the file or single lists were not used.
function M.load()
  local path = M.path()
  local st = uv.fs_stat(path)
  if not st then
    return {}, "missing", {}
  end
  if st.type == "file" and st.size > M.MAX_FILE_BYTES then
    return {}, "corrupt", { ("%s is larger than %d bytes"):format(path, M.MAX_FILE_BYTES) }
  end
  local text, rerr = fsio.read(path)
  if not text then
    return {}, "unreadable", { tostring(rerr) }
  end
  local lists, skipped, derr = M.decode(text)
  if not lists then
    return {}, "corrupt", { ("%s: %s"):format(path, derr) }
  end
  return lists, "ok", skipped
end

---Write the saved lists (atomically, parent folder created). Callers refuse to write over an unreadable or corrupt file.
---@param lists table<string, Tasks.ListDef>
---@return boolean ok
---@return string|nil err
local function write(lists)
  return fsio.write_atomic(M.path(), M.encode(lists))
end

-- ── the three sources ────────────────────────────────────────────────────────

---The lists of `setup({ lists })`, validated one by one (a bad one is skipped and named in `notes`).
---@return table<string, Tasks.ListDef> lists
---@return string[] notes
local function from_config()
  local raw = require("tasks_nvim.config").get().lists
  local out, notes = {}, {}
  if type(raw) ~= "table" then
    return out, notes
  end
  for name, def in pairs(raw) do
    local clean, err = M.normalize(name, def)
    if clean then
      out[name] = clean
    else
      notes[#notes + 1] = "setup({ lists }): " .. err
    end
  end
  return out, notes
end

---Every list there is, by name. A config list shadows a saved one, a saved one shadows a built-in.
---@return Tasks.ListEntry[] entries  Sorted by name.
---@return string[] notes  Shadowed names, rejected definitions, an unreadable file.
function M.all()
  local notes = {}
  local by_name = {}
  for name, def in pairs(M.BUILTIN) do
    by_name[name] = { name = name, def = vim.deepcopy(def), source = "builtin" }
  end
  local saved, status, snotes = M.load()
  if status ~= "ok" and status ~= "missing" then
    notes[#notes + 1] = "saved lists not used: " .. table.concat(snotes, "; ")
  else
    vim.list_extend(notes, snotes)
  end
  for name, def in pairs(saved) do
    by_name[name] = { name = name, def = def, source = "saved" }
  end
  local configured, cnotes = from_config()
  vim.list_extend(notes, cnotes)
  for name, def in pairs(configured) do
    if by_name[name] and by_name[name].source == "saved" then
      notes[#notes + 1] = ("list '%s' is defined in setup() and shadows the saved one of that name"):format(
        name
      )
    end
    by_name[name] = { name = name, def = def, source = "config" }
  end
  local out = {}
  for _, entry in pairs(by_name) do
    out[#out + 1] = entry
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  table.sort(notes)
  return out, notes
end

---One list by name.
---@param name string
---@return Tasks.ListEntry|nil entry
---@return string|nil err  Unknown name: says which lists exist.
function M.get(name)
  local entries = M.all()
  local names = {}
  for _, e in ipairs(entries) do
    if e.name == name then
      return e, nil
    end
    names[#names + 1] = e.name
  end
  return nil, ("unknown list '%s' (lists: %s)"):format(tostring(name), table.concat(names, ", "))
end

---One line that says what a list selects: its `desc`, else its option words.
---@param def Tasks.ListDef
---@return string
function M.summary(def)
  if def.desc and def.desc ~= "" then
    return fsio.clean(def.desc)
  end
  local words = M.words(def)
  if def.area then
    table.insert(words, 1, "area=" .. def.area)
  end
  return #words > 0 and table.concat(words, " ") or "(everything)"
end

-- ── changing the saved lists ─────────────────────────────────────────────────

---Save a list under a name. Replaces a saved list of that name; a name of the config is refused, a name of a
---built-in list is allowed (the saved list then replaces it).
---@param name string
---@param def Tasks.ListDef
---@return boolean ok
---@return string|nil err
function M.save(name, def)
  local clean, err = M.normalize(name, def)
  if not clean then
    return false, err
  end
  local configured = from_config()
  if configured[name] then
    return false, ("list '%s' is defined in setup(); change it there"):format(name)
  end
  local saved, status, notes = M.load()
  if status == "unreadable" or status == "corrupt" then
    return false,
      ("the saved lists cannot be read (%s); fix or remove %s"):format(
        table.concat(notes, "; "),
        M.path()
      )
  end
  if saved[name] == nil then
    local n = 0
    for _ in pairs(saved) do
      n = n + 1
    end
    if n >= M.MAX_SAVED then
      return false, ("at most %d saved lists"):format(M.MAX_SAVED)
    end
  end
  saved[name] = clean
  return write(saved)
end

---Delete a saved list. Config and built-in lists cannot be deleted.
---@param name string
---@return boolean ok
---@return string|nil err
function M.delete(name)
  local configured = from_config()
  if configured[name] then
    return false, ("list '%s' is defined in setup(); remove it there"):format(name)
  end
  local saved, status, notes = M.load()
  if status == "unreadable" or status == "corrupt" then
    return false,
      ("the saved lists cannot be read (%s); fix or remove %s"):format(
        table.concat(notes, "; "),
        M.path()
      )
  end
  if saved[name] == nil then
    if M.BUILTIN[name] then
      return false,
        ("list '%s' is built in and cannot be deleted (save a list of that name to replace it)"):format(
          name
        )
    end
    return false, ("no saved list '%s'"):format(name)
  end
  saved[name] = nil
  return write(saved)
end

---Rename a saved list.
---@param old string
---@param new string
---@return boolean ok
---@return string|nil err
function M.rename(old, new)
  local valid, why = M.valid_name(new)
  if not valid then
    return false, why
  end
  local configured = from_config()
  if configured[old] or configured[new] then
    return false, "a list of setup() cannot be renamed or replaced from here"
  end
  local saved, status, notes = M.load()
  if status == "unreadable" or status == "corrupt" then
    return false,
      ("the saved lists cannot be read (%s); fix or remove %s"):format(
        table.concat(notes, "; "),
        M.path()
      )
  end
  if saved[old] == nil then
    return false, ("no saved list '%s'"):format(old)
  end
  if saved[new] ~= nil then
    return false, ("a saved list '%s' exists already"):format(new)
  end
  saved[new], saved[old] = saved[old], nil
  return write(saved)
end

return M
