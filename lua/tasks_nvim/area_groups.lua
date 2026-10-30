---@module 'tasks_nvim.area_groups'
---@brief Area groups: a name that stands for several areas (`nvim` = every `*.nvim` area) wherever a filter takes one.
---@description
--- A group is a filter, never a place: `list nvim`, `next nvim`, `plans nvim`, the dashboard and the desktop app show
--- the tasks of every member area; `new nvim` is refused (a task lives in one area). Members are the areas whose name
--- matches one of `include` (exact names or `*`/`?` globs) and none of `exclude`, so a new `.nvim` area joins `nvim`
--- without an entry of its own. An area may sit in several groups; a group is never a member of another one.
---
--- Two sources, the later one wins by name:
---  1. `<vault>/area-groups.json`: the shared definition, read by the headless CLI, Neovim and tasks-desktop alike:
---
---         { "version": 1, "groups": { "nvim": { "include": ["*.nvim"], "desc": "my Neovim plugins" },
---                                     "native": { "include": ["*-desktop", "takt"], "exclude": ["docmap-desktop"] } } }
---
---  2. `setup({ area_groups = {...} })`: same shape, only inside Neovim (the CLI has no `setup`).
---
--- A real area always wins over a group of the same name (the group is then `shadowed`, `check` reports it).
---
--- Not its job: the filters themselves (`scan`, `plan_scope`, `contract`, `ui.*` ask `vault.area_scope`).

local fsio = require("tasks_nvim.fsio")
local matcher = require("lib.nvim.fs.find_upward_dir.matcher")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---The file in the vault root that holds the shared groups.
M.FILE = "area-groups.json"

---The file format version `encode` writes and `decode` accepts.
M.VERSION = 1

---A larger file is refused unread (it is a handful of lines by design).
M.MAX_FILE_BYTES = 256 * 1024

---@class Tasks.AreaGroupDef
---@field include string[]  Area names or `*`/`?` globs; at least one.
---@field exclude? string[] Area names or globs taken out again.
---@field desc? string      One line of text.

---@class Tasks.AreaGroup
---@field name string
---@field include string[]
---@field exclude string[]
---@field desc string|nil
---@field source "file"|"config"
---@field members string[]   The vault's areas that match, sorted.
---@field shadowed boolean   An area of the same name exists; the area wins.

---@class Tasks.AreaScope
---@field name string                 What was asked for.
---@field group boolean               Whether `name` is a group (false: one area).
---@field areas string[]              The areas the name stands for, sorted.
---@field set table<string, boolean>  The same as a set.

---@param list any
---@return boolean
local function is_string_list(list)
  if type(list) ~= "table" or not vim.islist(list) then
    return false
  end
  for _, v in ipairs(list) do
    if type(v) ~= "string" or v == "" then
      return false
    end
  end
  return true
end

---Check one definition. A bad one is refused with the reason, naming the group.
---@param name any
---@param def any
---@return Tasks.AreaGroupDef|nil clean
---@return string|nil err
function M.normalize(name, def)
  if not vault.valid_area(name) then
    return nil, ("area group '%s': the name must look like an area name"):format(tostring(name))
  end
  -- `all` is the keyword for every area in the CLI and the routes: a group of that name would mean two things
  if name:lower() == "all" then
    return nil, ("area group '%s': the name is reserved (all areas)"):format(name)
  end
  if type(def) ~= "table" then
    return nil, ("area group '%s': expected a table with `include`"):format(name)
  end
  for key in pairs(def) do
    if key ~= "include" and key ~= "exclude" and key ~= "desc" then
      return nil, ("area group '%s': unknown key `%s`"):format(name, tostring(key))
    end
  end
  if not is_string_list(def.include) or #def.include == 0 then
    return nil,
      ("area group '%s': `include` must be a non-empty list of area names or globs"):format(name)
  end
  if def.exclude ~= nil and not is_string_list(def.exclude) then
    return nil, ("area group '%s': `exclude` must be a list of area names or globs"):format(name)
  end
  if def.desc ~= nil and type(def.desc) ~= "string" then
    return nil, ("area group '%s': `desc` must be a string"):format(name)
  end
  return {
    include = vim.deepcopy(def.include),
    exclude = vim.deepcopy(def.exclude or {}),
    desc = def.desc ~= nil and fsio.clean(def.desc) or nil,
  },
    nil
end

---Parse the file text. Groups that do not validate are skipped and reported.
---@param text string|nil
---@return table<string, Tasks.AreaGroupDef>|nil groups
---@return string[] skipped
---@return string|nil err  Set when the text is no area-groups file at all.
function M.decode(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return {}, {}, nil
  end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, {}, "not valid JSON"
  end
  if data.version ~= nil and data.version ~= M.VERSION then
    return nil, {}, ("unknown version %s (expected %d)"):format(tostring(data.version), M.VERSION)
  end
  if type(data.groups) ~= "table" or vim.islist(data.groups) and next(data.groups) ~= nil then
    return nil, {}, "no `groups` table"
  end
  local out, skipped = {}, {}
  for name, def in pairs(data.groups) do
    local clean, err = M.normalize(name, def)
    if clean then
      out[name] = clean
    else
      skipped[#skipped + 1] = err
    end
  end
  table.sort(skipped)
  return out, skipped, nil
end

---@param root string
---@return string
function M.path(root)
  return root .. "/" .. M.FILE
end

---What the last `load` decoded, keyed by path and the file's text: the file is small and read on every question (a
---rewrite of the same size within one timestamp tick would fool a size+mtime key), the decode is what is saved.
---@type table<string, { text: string, groups: table, notes: string[], ok: boolean }>
local cache = {}

---The groups of the vault file. Never raises: a missing file is no groups; a broken one is no groups plus a note.
---@param root string
---@return table<string, Tasks.AreaGroupDef> groups
---@return string[] notes  Why the file or single groups were not used.
---@return boolean ok      False when the file exists but could not be used at all.
function M.load(root)
  local path = M.path(root)
  local st = uv.fs_stat(path)
  if not st then
    cache[path] = nil
    return {}, {}, true
  end
  local groups, ok = {}, true
  ---@type string[]
  local notes
  if st.type ~= "file" then
    notes, ok = { ("%s is not a regular file"):format(M.FILE) }, false
  elseif st.size > M.MAX_FILE_BYTES then
    notes, ok = { ("%s is larger than %d bytes"):format(M.FILE, M.MAX_FILE_BYTES) }, false
  else
    local text, rerr = fsio.read(path)
    if not text then
      notes, ok = { ("%s: %s"):format(M.FILE, tostring(rerr)) }, false
    else
      local hit = cache[path]
      if hit and hit.text == text then
        return vim.deepcopy(hit.groups), vim.deepcopy(hit.notes), hit.ok
      end
      local decoded, skipped, derr = M.decode(text)
      if decoded then
        groups, notes = decoded, skipped
      else
        notes, ok = { ("%s: %s"):format(M.FILE, derr) }, false
      end
      cache[path] = { text = text, groups = groups, notes = notes, ok = ok }
    end
  end
  return vim.deepcopy(groups), vim.deepcopy(notes), ok
end

---The groups of `setup({ area_groups })`, validated one by one.
---@return table<string, Tasks.AreaGroupDef> groups
---@return string[] notes
local function from_config()
  local raw = require("tasks_nvim.config").get().area_groups
  local out, notes = {}, {}
  if type(raw) ~= "table" then
    return out, notes
  end
  for name, def in pairs(raw) do
    local clean, err = M.normalize(name, def)
    if clean then
      out[name] = clean
    else
      notes[#notes + 1] = "setup({ area_groups }): " .. err
    end
  end
  return out, notes
end

---The areas of `names` a definition takes in.
---@param def Tasks.AreaGroupDef
---@param names string[]  The vault's areas.
---@return string[]
function M.members(def, names)
  local take = matcher.build(def.include)
  local drop = matcher.build(def.exclude or {})
  local out = {}
  for _, name in ipairs(names) do
    if take(name) and not drop(name) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@param root string
---@return { groups: Tasks.AreaGroup[], notes: string[], file_notes: string[], config_notes: string[] }
local function build(root)
  local names = vault.area_names(root)
  local is_area = {}
  for _, n in ipairs(names) do
    is_area[n] = true
  end
  local file, file_notes = M.load(root)
  local notes = vim.list_extend({}, file_notes)
  local by_name = {}
  for name, def in pairs(file) do
    by_name[name] = { def = def, source = "file" }
  end
  local configured, cnotes = from_config()
  vim.list_extend(notes, cnotes)
  for name, def in pairs(configured) do
    if by_name[name] then
      notes[#notes + 1] = ("area group '%s' is defined in setup() and shadows the one in %s"):format(
        name,
        M.FILE
      )
    end
    by_name[name] = { def = def, source = "config" }
  end
  local out = {}
  for name, e in pairs(by_name) do
    out[#out + 1] = {
      name = name,
      include = e.def.include,
      exclude = e.def.exclude or {},
      desc = e.def.desc,
      source = e.source,
      members = M.members(e.def, names),
      shadowed = is_area[name] == true,
    }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  table.sort(notes)
  return { groups = out, notes = notes, file_notes = file_notes, config_notes = cnotes }
end

---Every group with its members, sorted by name (copies: callers may edit them).
---@param root string
---@return Tasks.AreaGroup[] groups
---@return string[] notes  Rejected definitions, an unusable file, groups `setup()` shadows.
function M.all(root)
  local built = fsio.scope_memo("area_groups:" .. root, function()
    return build(root)
  end)
  return vim.deepcopy(built.groups), vim.deepcopy(built.notes)
end

---What cannot be used, by source: `file` (an unusable `area-groups.json` or a rejected group of it) and `config` (a
---rejected group of `setup({ area_groups })`). A group of `setup()` that replaces one of the file by name is no
---problem: that is what it is for (`all` still names it in its notes).
---@param root string
---@return { file: string[], config: string[] }
function M.problems(root)
  local built = fsio.scope_memo("area_groups:" .. root, function()
    return build(root)
  end)
  return { file = vim.deepcopy(built.file_notes), config = vim.deepcopy(built.config_notes) }
end

---One group by name; nil when there is none or an area of that name wins.
---@param root string
---@param name string
---@return Tasks.AreaGroup|nil
function M.get(root, name)
  for _, g in ipairs(M.all(root)) do
    if g.name == name then
      return not g.shadowed and g or nil
    end
  end
  return nil
end

---The names of the groups that are in force (not shadowed).
---@param root string
---@return string[]
function M.names(root)
  local out = {}
  for _, g in ipairs(M.all(root)) do
    if not g.shadowed then
      out[#out + 1] = g.name
    end
  end
  return out
end

---@param areas string[]
---@return table<string, boolean>
local function to_set(areas)
  local set = {}
  for _, a in ipairs(areas) do
    set[a] = true
  end
  return set
end

---What a name a filter takes stands for: an area (wins) or a group's members.
---@param root string
---@param name string
---@return Tasks.AreaScope|nil scope
---@return string|nil err  Neither area nor group: the message names what comes close.
function M.resolve(root, name)
  if type(name) ~= "string" then
    return nil, "area must be a string"
  end
  if vault.has_area(root, name) then
    return { name = name, group = false, areas = { name }, set = { [name] = true } }, nil
  end
  local g = M.get(root, name)
  if g then
    return { name = name, group = true, areas = vim.deepcopy(g.members), set = to_set(g.members) },
      nil
  end
  local names = vault.area_names(root)
  vim.list_extend(names, M.names(root))
  return nil, vault.not_an_area_message(name, names)
end

---The message for `new <group>`: a task lives in one area.
---@param group Tasks.AreaGroup
---@return string
function M.not_a_target_message(group)
  local members = #group.members > 0 and table.concat(group.members, ", ") or "none"
  return ("'%s' is an area group (members: %s): name one area"):format(group.name, members)
end

return M
