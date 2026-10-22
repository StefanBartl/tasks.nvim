---The saved views of the tasks, in the vault: one small Markdown file each at `<area>/ROADMAP/views/<slug>.md` (a view
---of tasks of several areas lives in the area `ALL`, like a task of several). A view is a selection (which tasks), a
---grouping (by which field, and for a matrix by a second one) and a way to draw it; it holds no task and no rule. The
---engine reads them with the vault and writes them only through the operations `view_save` and `view_delete`, with a
---version tag (`if_match`) like every other file it writes.
---
---Frontmatter: `title`, `group_by`, `group_by2`, `display`, `collapsed` (the groups that are folded), `sel_areas`,
---`sel_statuses`, `sel_actors`, `sel_kinds`, `sel_tags`, `sel_plans`, `sel_query`, `created`, `updated`.
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---How a view is drawn.
M.DISPLAYS = { "columns", "list", "matrix" }

---The fields a view may group by (the ones `tasks.groupings` names).
M.GROUP_FIELDS = {
  "status",
  "prio",
  "actor",
  "kind",
  "effort",
  "value",
  "tags",
  "plan",
  "phase",
  "area",
  "state",
  "cross",
}

---The selection of a view: its name, the frontmatter key, and what the entries are checked against.
---@type { name: string, key: string }[]
M.SELECT = {
  { name = "areas", key = "sel_areas" },
  { name = "statuses", key = "sel_statuses" },
  { name = "actors", key = "sel_actors" },
  { name = "kinds", key = "sel_kinds" },
  { name = "tags", key = "sel_tags" },
  { name = "plans", key = "sel_plans" },
}

---Most entries of a list of the selection, and of the folded groups; longest entry or query, in characters.
M.MAX_LIST = 100
M.MAX_ENTRY = 300

local function set_of(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = true
  end
  return out
end

local DISPLAY_SET = set_of(M.DISPLAYS)
local FIELD_SET = set_of(M.GROUP_FIELDS)

---The directory of the views of an area.
---@param root string
---@param area string
---@return string
function M.dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/views"
end

---@param root string
---@param area string
---@param slug string
---@return string
function M.path(root, area, slug)
  return M.dir(root, area) .. "/" .. slug .. ".md"
end

---Why the views of an area must not be read or written, or nil: the folder (or the nearest one of its parents that is
---there) leads out of the vault by a symbolic link or a junction.
---@param root string
---@param area string
---@return string|nil err
local function leaves(root, area)
  local dir = M.dir(root, area)
  while not fsio.is_dir(dir) and #dir > #root do
    dir = vim.fs.dirname(dir)
  end
  return vault.leaves(root, dir)
end

local function has_control(s)
  return type(s) == "string" and s:find("[%c]") ~= nil
end

---A list of short single-line words (the entries of the selection, the folded groups).
---@param value any
---@param what string
---@return string[]|nil list
---@return string|nil err
local function words(value, what)
  if value == nil or value == vim.NIL then
    return {}, nil
  end
  if type(value) ~= "table" then
    return nil, what .. " must be a list of words"
  end
  if #value > M.MAX_LIST then
    return nil, ("%s has more than %d entries"):format(what, M.MAX_LIST)
  end
  local out, seen = {}, {}
  for _, v in ipairs(value) do
    if type(v) ~= "string" or v == "" or has_control(v) then
      return nil, what .. " holds an entry that is not a word"
    end
    if vim.fn.strchars(v) > M.MAX_ENTRY then
      return nil, ("%s holds an entry longer than %d characters"):format(what, M.MAX_ENTRY)
    end
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out, nil
end

---Check a view as a caller gives it and put it in the shape the file and the document have.
---@param def table  # `{ title, group_by, group_by2?, display, collapsed?, select? }`
---@return table|nil view
---@return string|nil err
function M.normalize(def)
  if type(def) ~= "table" then
    return nil, "a view must be an object"
  end
  if type(def.title) ~= "string" or vim.trim(def.title) == "" then
    return nil, "a view needs a title"
  end
  if has_control(def.title) then
    return nil, "title contains a control character"
  end
  if vim.fn.strchars(def.title) > M.MAX_ENTRY then
    return nil, ("title is longer than %d characters"):format(M.MAX_ENTRY)
  end
  if not DISPLAY_SET[def.display] then
    return nil,
      ("display '%s' is unknown (expected %s)"):format(
        tostring(def.display),
        table.concat(M.DISPLAYS, ", ")
      )
  end
  if not FIELD_SET[def.group_by] then
    return nil,
      ("group_by '%s' is not a field to group by (expected %s)"):format(
        tostring(def.group_by),
        table.concat(M.GROUP_FIELDS, ", ")
      )
  end
  local second = def.group_by2
  if second == vim.NIL then
    second = nil
  end
  if second ~= nil then
    if def.display ~= "matrix" then
      return nil, "group_by2 is for a matrix only"
    end
    if not FIELD_SET[second] then
      return nil, ("group_by2 '%s' is not a field to group by"):format(tostring(second))
    end
    if second == def.group_by then
      return nil, "group_by2 must be another field than group_by"
    end
  elseif def.display == "matrix" then
    return nil, "a matrix needs group_by2"
  end
  local view = {
    title = vim.trim(def.title),
    display = def.display,
    group_by = def.group_by,
    group_by2 = second,
    select = {},
  }
  local collapsed, cerr = words(def.collapsed, "collapsed")
  if not collapsed then
    return nil, cerr
  end
  view.collapsed = collapsed
  local select = def.select
  if select ~= nil and select ~= vim.NIL and type(select) ~= "table" then
    return nil, "select must be an object"
  end
  select = (select ~= vim.NIL and select) or {}
  for key in pairs(select) do
    local known = key == "query"
    for _, s in ipairs(M.SELECT) do
      known = known or s.name == key
    end
    if not known then
      return nil, ("select: unknown entry '%s'"):format(tostring(key))
    end
  end
  for _, s in ipairs(M.SELECT) do
    local list, err = words(select[s.name], "select." .. s.name)
    if not list then
      return nil, err
    end
    view.select[s.name] = list
  end
  local query = select.query
  if query ~= nil and query ~= vim.NIL then
    if type(query) ~= "string" or has_control(query) or vim.fn.strchars(query) > M.MAX_ENTRY then
      return nil, "select.query must be one line of text"
    end
    view.select.query = vim.trim(query) ~= "" and vim.trim(query) or nil
  end
  return view, nil
end

---The frontmatter of a view, as `{ key, value }` pairs in the order the file has them; a key a view does not have is
---`REMOVE` when `patch` (a change of a file that exists), left out when new.
---@param view table
---@param dates { created?: string, updated: string }
---@param patch boolean
---@return table[]
local function pairs_of(view, dates, patch)
  local out =
    { { "title", view.title }, { "display", view.display }, { "group_by", view.group_by } }
  local function optional(key, value)
    if value ~= nil then
      out[#out + 1] = { key, value }
    elseif patch then
      out[#out + 1] = { key, fm.REMOVE }
    end
  end
  optional("group_by2", view.group_by2)
  optional("collapsed", #view.collapsed > 0 and view.collapsed or nil)
  for _, s in ipairs(M.SELECT) do
    local list = view.select[s.name]
    optional(s.key, list and #list > 0 and list or nil)
  end
  optional("sel_query", view.select.query)
  if dates.created then
    out[#out + 1] = { "created", dates.created }
  end
  out[#out + 1] = { "updated", dates.updated }
  return out
end

---A view file's text read as a view.
---@param text string
---@param area string
---@param slug string
---@param path string
---@return table|nil view
---@return string|nil problem
function M.parse_text(text, area, slug, path)
  local parsed, perr = fm.parse(text)
  if not parsed then
    return nil, "frontmatter unreadable: " .. tostring(perr)
  end
  local function get(key)
    return fm.get(parsed, key)
  end
  local function list(key)
    local v = get(key)
    if v == nil then
      return {}
    end
    return type(v) == "table" and v or { v }
  end
  local select = {}
  for _, s in ipairs(M.SELECT) do
    select[s.name] = list(s.key)
  end
  select.query = get("sel_query")
  local view, err = M.normalize({
    title = get("title") or slug,
    display = get("display"),
    group_by = get("group_by"),
    group_by2 = get("group_by2"),
    collapsed = list("collapsed"),
    select = select,
  })
  if not view then
    return nil, err
  end
  view.id = area .. "/" .. slug
  view.area = area
  view.slug = slug
  view.etag = fsio.etag(text)
  view.path = path
  view.created = get("created")
  view.updated = get("updated")
  return view, nil
end

---One file read as a view.
---@param path string
---@param area string
---@param slug string
---@return table|nil view
---@return string|nil problem
function M.read_file(path, area, slug)
  local text, rerr = fsio.read(path)
  if not text then
    return nil, "cannot read: " .. tostring(rerr)
  end
  return M.parse_text(text, area, slug, path)
end

---The view as a caller gives it (and takes it back): what a `view_save` carries, without what the file adds (`id`, the
---version, the dates). The inverse of a change is a `view_save` of this.
---@param view table
---@return table
function M.def_of(view)
  local select = {}
  for _, s in ipairs(M.SELECT) do
    select[s.name] = view.select[s.name]
  end
  select.query = view.select.query
  return {
    title = view.title,
    display = view.display,
    group_by = view.group_by,
    group_by2 = view.group_by2,
    collapsed = view.collapsed,
    select = select,
  }
end

---The files of the views, for their `views_rev` (a view changed elsewhere, by a pull say, is a new state of the views):
---`{ id, path }` for every file with the name of a view, sorted by id; a folder that leads out of the vault is one entry
---without a path (it is not read).
---@param root string
---@return { id: string, path: string|nil }[]
function M.files(root)
  local out = {}
  for _, area in ipairs(vault.areas(root)) do
    local dir = M.dir(root, area.name)
    if fsio.is_dir(dir) then
      if leaves(root, area.name) then
        out[#out + 1] = { id = area.name .. "/views" }
      else
        local names = vim.fn.readdir(dir)
        table.sort(names)
        for _, name in ipairs(names) do
          local slug = name:match("^(.+)%.md$")
          if slug and vault.valid_slug(slug) then
            out[#out + 1] = { id = area.name .. "/" .. slug, path = dir .. "/" .. name }
          end
        end
      end
    end
  end
  return out
end

---Every view of the vault, by id, and what could not be read (a file with a problem is no view but a line in the list of
---problems, and never hides the others).
---@param root string
---@return table[] views
---@return { id: string, file: string, message: string }[] problems
function M.all(root)
  local views, problems = {}, {}
  for _, area in ipairs(vault.areas(root)) do
    local dir = M.dir(root, area.name)
    local escape = fsio.is_dir(dir) and leaves(root, area.name)
    if escape then
      problems[#problems + 1] = {
        id = area.name .. "/views",
        file = area.name .. "/ROADMAP/views",
        message = escape,
      }
    elseif fsio.is_dir(dir) then
      local names = vim.fn.readdir(dir)
      table.sort(names)
      for _, name in ipairs(names) do
        local slug = name:match("^(.+)%.md$")
        if slug and vault.valid_slug(slug) then
          local path = dir .. "/" .. name
          local view, problem
          if fsio.is_link(path) then
            problem = "is a symbolic link: not read"
          else
            view, problem = M.read_file(path, area.name, slug)
          end
          if view then
            views[#views + 1] = view
          else
            problems[#problems + 1] = {
              id = area.name .. "/" .. slug,
              file = ("%s/ROADMAP/views/%s"):format(area.name, name),
              message = tostring(problem),
            }
          end
        end
      end
    end
  end
  table.sort(views, function(a, b)
    return a.id < b.id
  end)
  return views, problems
end

---Version of a file that is not there: a `view_save` with `if_match` of it means "make a new one".
local function conflict(id, expected, actual)
  return nil,
    ("the view %s is not the version the change was made on (it is %s, the change was made on %s)"):format(
      id,
      tostring(actual),
      tostring(expected)
    ),
    { code = "conflict", id = id, expected = expected, actual = actual }
end

---Make or replace a view. Without `slug` a new one is made, its name taken from the title (a free one: `-2`, `-3`);
---with `slug` the view of that name is replaced, and `if_match` (the version tag the caller read) must still be the
---file's; a `slug` of a file that is not there makes it.
---@param root string
---@param area string
---@param def table
---@param opts? { slug?: string, if_match?: string, today?: string, dry_run?: boolean }
---@return { id: string, area: string, slug: string, path: string, created: boolean, etag_before?: string, etag_after?: string, changed: boolean, before?: table }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "conflict"|"not_found"|"invalid_argument" }` when there is a reason to name
function M.save(root, area, def, opts)
  opts = opts or {}
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area), { code = "not_found" }
  end
  local view, verr = M.normalize(def)
  if not view then
    return nil, verr, { code = "invalid_argument" }
  end
  local escape = leaves(root, area)
  if escape then
    return nil, escape, { code = "forbidden" }
  end
  local today = opts.today or model.today()
  if
    opts.slug ~= nil and (not vault.valid_slug(opts.slug) or vault.is_reserved_name(opts.slug))
  then
    return nil, "invalid slug: " .. tostring(opts.slug), { code = "invalid_argument" }
  end
  -- the name: the one given, or one that is free
  local slug = opts.slug
  if slug == nil then
    local base = require("tasks_nvim.mutate").slugify(view.title)
    local n = 1
    repeat
      slug = n == 1 and base or (base .. "-" .. n)
      n = n + 1
    until not fsio.is_file(M.path(root, area, slug)) or n > 999
    if fsio.is_file(M.path(root, area, slug)) then
      return nil, "no free name for " .. base, { code = "invalid_argument" }
    end
  end
  local path = M.path(root, area, slug)
  local id = area .. "/" .. slug
  if fsio.is_link(path) then
    return nil, id .. " is a symbolic link: it is not changed", { code = "forbidden" }
  end
  local exists = fsio.is_file(path)
  local result =
    { id = id, area = area, slug = slug, path = path, created = not exists, changed = true }

  if not exists then
    if opts.if_match ~= nil then
      return conflict(id, opts.if_match, "gone")
    end
    if opts.dry_run then
      return result, nil
    end
    local text, terr = fm.update_text(
      "\n",
      pairs_of(view, { created = today, updated = today }, false),
      { create = true }
    )
    if not text then
      return nil, "cannot build the view file: " .. tostring(terr)
    end
    fsio.mkdirp(M.dir(root, area))
    local ok, err = fsio.create_exclusive(path, text)
    if not ok then
      if fsio.is_exists(err) then
        -- A name this call chose was taken between the look and the create: choose the next free one (a few times).
        if opts.slug == nil and (opts._attempt or 0) < 5 then
          return M.save(
            root,
            area,
            def,
            vim.tbl_extend("force", opts, { _attempt = (opts._attempt or 0) + 1 })
          )
        end
        return nil, "the view exists now: " .. id, { code = "conflict", id = id }
      end
      return nil, "cannot create " .. path .. ": " .. tostring(err)
    end
    result.etag_after = fsio.etag(text)
    return result, nil
  end

  -- an existing file: replaced under the lock, against the text read there
  local ok, werr, winfo = fsio.with_lock(path, function()
    local cur, rerr = fsio.read(path)
    if not cur then
      return nil, "cannot read " .. path .. ": " .. tostring(rerr)
    end
    local etag = fsio.etag(cur)
    result.etag_before = etag
    -- A view that exists is replaced only on the version the caller read: a change made without it could undo another's.
    if opts.if_match ~= etag then
      return conflict(id, opts.if_match or "none", etag)
    end
    local before = M.parse_text(cur, area, slug, path)
    result.before = before and M.def_of(before) or nil
    local parsed = fm.parse(cur)
    local created = parsed and fm.get(parsed, "created") or today
    local text, terr =
      fm.update_text(cur, pairs_of(view, { updated = today, created = created }, true))
    if not text then
      return nil, "cannot build the view file: " .. tostring(terr)
    end
    result.etag_after = fsio.etag(text)
    result.changed = result.etag_after ~= etag
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = fsio.write_atomic(path, text)
    if not wrote then
      return nil, "cannot write " .. path .. ": " .. tostring(wr_err)
    end
    return true
  end)
  if not ok then
    if winfo and winfo.code == "conflict" then
      return nil, werr, winfo
    end
    return nil, werr, winfo
  end
  return result, nil
end

---Delete a view. `if_match` (the version tag the caller read) must still be the file's.
---@param root string
---@param id string  # `<area>/<slug>`
---@param opts? { if_match?: string, dry_run?: boolean }
---@return { id: string, area: string, slug: string, path: string, etag_before: string, before?: table }|nil result
---@return string|nil err
---@return table|nil info
function M.delete(root, id, opts)
  opts = opts or {}
  local area, slug = tostring(id):match("^([^/]+)/([^/]+)$")
  if not area or not vault.valid_slug(slug) or not vault.has_area(root, area) then
    return nil, "no such view: " .. tostring(id), { code = "not_found" }
  end
  local path = M.path(root, area, slug)
  local escape = leaves(root, area)
  if escape then
    return nil, escape, { code = "forbidden" }
  end
  if fsio.is_link(path) then
    return nil, id .. " is a symbolic link: it is not deleted", { code = "forbidden" }
  end
  if not fsio.is_file(path) then
    return nil, "no such view: " .. tostring(id), { code = "not_found" }
  end
  local result = { id = id, area = area, slug = slug, path = path }
  local ok, werr, winfo = fsio.with_lock(path, function()
    local cur, rerr = fsio.read(path)
    if not cur then
      return nil, "cannot read " .. path .. ": " .. tostring(rerr)
    end
    result.etag_before = fsio.etag(cur)
    if opts.if_match ~= nil and opts.if_match ~= result.etag_before then
      return conflict(id, opts.if_match, result.etag_before)
    end
    local before = M.parse_text(cur, area, slug, path)
    result.before = before and M.def_of(before) or nil
    if opts.dry_run then
      return true
    end
    local removed, err = fsio.remove(path)
    if not removed then
      return nil, "cannot delete " .. path .. ": " .. tostring(err)
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

return M
