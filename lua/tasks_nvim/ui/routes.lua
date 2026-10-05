---@module 'tasks_nvim.ui.routes'
---@brief The composer routes and argument types of `:Tasks` (and, nested as `tasks` / `task <verb>` / `open`, for a host that mounts them under its own verb).
---@description
--- Declares the grammar of the task commands for
--- `lib.nvim.bindings.usercmd.composer` -- one route tree, from which
--- dispatch, `<Tab>` completion and the generated usage text all come. The
--- handlers live in `tasks_cmd`; the engine they call is the plugin `tasks.nvim` (`tasks_nvim.*`).
---
--- Grammar (verb-first, concept section 5.1):
---  - `tasks [<area>|all] [--status= --prio= --kind= --tag= --stale= --blocked] [--to= --format=]`
---  - `tasks index [<area>|--all] [--check]`
---  - `task new [<area> [title...]] [kind= prio= effort= tags= status=]` (no area: the form)
---  - `task set <id> key=value ...`, `task done <id> [done_in= date= --yes]`
---  - `task template [--to=]`, `task open <id>`, `task preview <id>` (mdview)
---  - `open <area> [tasks|roadmap|backlog|handover|notes|all] [--action= --list --to=]`
---
--- Argument types registered here (both read the vault on every call, so a
--- new area or task shows up at once, and both fail soft: no vault means no
--- candidates, never an error in the middle of typing):
---  - `TASK_AREA`: an area of the vault (the `extra_areas` of `setup()` included); with
---    `allow_all = true` the keyword `all` (every area) too
---  - `TASK_ID`: `<area>/<slug>` of an open task; `allow_done = true` also
---    accepts a finished one
---
--- Not its job: running anything (`tasks_cmd`), rendering (`tasks_view`).

local composer = require("lib.nvim.bindings.usercmd.composer")

local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---Seconds the task-id completion may reuse its directory walk (typing `<Tab>`
---repeatedly must not rescan 40 folders each time).
local COMPLETE_TTL = 3

---@return table
local function cmd()
  return require("tasks_nvim.ui.cmd")
end

---@param candidates string[]
---@param lead string
---@return string[]
local function prefix_ci(candidates, lead)
  local out = {}
  local low = lead:lower()
  for _, c in ipairs(candidates) do
    if c:lower():sub(1, #low) == low then
      out[#out + 1] = c
    end
  end
  return out
end

---@return string[]
local function area_names()
  local root = vault.root()
  if not root then
    return {}
  end
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    names[#names + 1] = a.name
  end
  return names
end

---Register `TASK_AREA` and `TASK_ID` with the composer. Safe to call twice.
---@return nil
function M.register_types()
  composer.register_type("TASK_AREA", {
    validate = function(raw, spec)
      if spec and spec.allow_all and raw == "all" then
        return true, "all", nil
      end
      local root, err = vault.root()
      if not root then
        return false, nil, tostring(err)
      end
      -- Exact spelling, from the listing: a case-insensitive file system
      -- (Windows, macOS) would otherwise take `all` for the folder `ALL`.
      if not vim.tbl_contains(area_names(), raw) then
        return false, nil, ("'%s' is not an area of the vault"):format(raw)
      end
      return true, raw, nil
    end,
    complete = function(arg_lead, spec)
      local names = area_names()
      if spec and spec.allow_all then
        names[#names + 1] = "all"
      end
      return prefix_ci(names, arg_lead)
    end,
  })

  composer.register_type("TASK_ID", {
    validate = function(raw, spec)
      local root, err = vault.root()
      if not root then
        return false, nil, tostring(err)
      end
      local area, slug, id_err = vault.parse_id(raw)
      if not area or not slug then
        return false, nil, id_err or ("expected <area>/<slug>, got '%s'"):format(raw)
      end
      if not vim.tbl_contains(area_names(), area) then
        return false, nil, ("'%s' is not an area of the vault"):format(area)
      end
      local found, find_err = scan.find(raw, { root = root })
      if found then
        return true, raw, nil
      end
      if spec and spec.allow_done and scan.find_done(raw, { root = root }) then
        return true, raw, nil
      end
      -- `find_err` is "no such open task" or the more useful "exists as file and as folder".
      return false, nil, find_err or ("no such open task: " .. raw)
    end,
    complete = function(arg_lead)
      local ok, tasks = pcall(scan.all, { ttl_seconds = COMPLETE_TTL })
      if not ok or not tasks then
        return {}
      end
      local ids = {}
      for _, t in ipairs(tasks) do
        if model.is_open_status(t.status) then
          ids[#ids + 1] = t.id
        end
      end
      table.sort(ids)
      return prefix_ci(ids, arg_lead)
    end,
  })
end

---@type table[]
local LIST_FLAGS = {
  { name = "status", type = "STRING", values = model.OPEN_STATUSES },
  { name = "prio", type = "STRING", values = { "1", "2", "3", "<=2" } },
  { name = "effort", type = "STRING", values = { "XS", "S", "M", "L", "XL", "<=S", "<=M" } },
  { name = "kind", type = "STRING", values = model.KINDS },
  { name = "category", type = "STRING", values = model.CATEGORIES },
  { name = "severity", type = "STRING", values = model.SEVERITIES },
  { name = "tag", type = "STRING" },
  { name = "stale", type = "STRING", values = { "7", "30", "90", "refs" } },
  { name = "blocked", bool = true },
  { name = "sort", type = "STRING", enum = model.SORTS },
  {
    name = "to",
    type = "STRING",
    values = { "buffer", "clipboard", "qf", "file:", "echo", "mdview" },
  },
  { name = "format", type = "STRING", enum = { "md", "csv" } },
  { name = "force", bool = true },
}

---The `key=` completions of `task set`: every settable key, with value hints.
---@return table[]
local function set_kv()
  local hints = {
    status = model.OPEN_STATUSES,
    kind = model.KINDS,
    category = model.CATEGORIES,
    severity = model.SEVERITIES,
    prio = { "1", "2", "3" },
    effort = model.EFFORTS,
  }
  local out = {}
  for _, key in ipairs(mutate.SETTABLE) do
    out[#out + 1] = { key = key, type = "STRING", values = hints[key] }
  end
  return out
end

---The routes in the nested grammar (a host config can mount them under its own verb) (`tasks`, `tasks index`, `task <verb>`, `open`).
---@return table[] routes
local function nested_routes()
  return {
    {
      path = { "tasks" },
      args = { { name = "area", type = "TASK_AREA", allow_all = true, optional = true } },
      flags = LIST_FLAGS,
      desc = "List the open tasks of one area (default: all) as a Markdown table in a scratch buffer; filter with --status= --prio= --effort=S,M|<=M --kind= --category=bug|security|performance|docs|ruleset --severity=low|medium|high|critical --tag= --stale=<days>|refs (refs: a file named in refs: changed since updated) --blocked, order with --sort=default|prio-effort|severity|frecency, deliver with --to=buffer|clipboard|qf|file:<path>|mdview (a browser preview through mdview.nvim, Markdown only) and --format=md|csv",
      run = function(ctx)
        cmd().list(ctx)
      end,
    },

    {
      path = { "tasks", "index" },
      args = { { name = "area", type = "TASK_AREA", optional = true } },
      flags = { { name = "check", bool = true }, { name = "all", bool = true } },
      desc = "(Re)write ROADMAP/TASKS.md of one area (default: every area); --check writes nothing and reports rule findings and stale indexes",
      run = function(ctx)
        cmd().index(ctx)
      end,
    },

    {
      path = { "task", "new" },
      args = { { name = "area", type = "TASK_AREA", optional = true } },
      kv = {
        { key = "kind", type = "STRING", values = model.KINDS },
        { key = "prio", type = "STRING", values = { "1", "2", "3" } },
        { key = "effort", type = "STRING", values = model.EFFORTS },
        { key = "tags", type = "STRING" },
        { key = "category", type = "STRING", values = model.CATEGORIES },
        { key = "severity", type = "STRING", values = model.SEVERITIES },
        { key = "status", type = "STRING", values = model.OPEN_STATUSES },
      },
      flags = { { name = "folder", bool = true } },
      desc = "Without arguments: a Markdown form (tick kind, prio, effort, category, severity, status; <C-s> submits) and the question whether to attach assets. With an area: create ROADMAP/tasks/<slug>.md in it and open it; the words after the area are the title (asked for when missing); --folder makes a folder task that can hold assets",
      run = function(ctx)
        cmd().task_new(ctx)
      end,
    },

    {
      path = { "task", "set" },
      args = { { name = "id", type = "TASK_ID" } },
      kv = set_kv(),
      desc = "Change frontmatter of an open task (key=value, a value may hold spaces, an empty value removes the key) and regenerate the index",
      run = function(ctx)
        cmd().task_set(ctx)
      end,
    },

    {
      path = { "task", "done" },
      args = { { name = "id", type = "TASK_ID", allow_done = true } },
      kv = {
        { key = "done_in", type = "STRING" },
        { key = "date", type = "STRING" },
      },
      flags = { { name = "yes", bool = true } },
      desc = "Finish a task after confirmation: status done, moved to Backlog/FEATURES|TASKS with a date prefix, Backlog README and index updated; --yes skips the question",
      run = function(ctx)
        cmd().task_done(ctx)
      end,
    },

    {
      path = { "task", "attach" },
      args = {
        { name = "id", type = "TASK_ID" },
        { name = "file", type = "FILE" },
      },
      kv = { { key = "name", type = "STRING" } },
      desc = "Copy a file (screenshot, log) into the task's assets/ folder, turning a plain task into a folder task, and put the Markdown link in the + register; name=<file name> renames the copy",
      run = function(ctx)
        cmd().task_attach(ctx)
      end,
    },

    {
      path = { "task", "folderize" },
      args = { { name = "id", type = "TASK_ID" } },
      desc = "Turn a plain task file into a folder task (<slug>/<slug>.md) so assets can be attached",
      run = function(ctx)
        cmd().task_folderize(ctx)
      end,
    },

    {
      path = { "task", "template" },
      flags = {
        { name = "to", type = "STRING", values = { "clipboard", "buffer", "file:" } },
        { name = "force", bool = true },
      },
      desc = "Copy the task file template to the + register (--to=buffer|file:<path> for the other targets)",
      run = function(ctx)
        cmd().task_template(ctx)
      end,
    },

    {
      path = { "task", "open" },
      args = { { name = "id", type = "TASK_ID", allow_done = true } },
      desc = "Open the file of a task (an open one, else its finished copy in Backlog/)",
      run = function(ctx)
        cmd().task_open(ctx)
      end,
    },

    {
      path = { "task", "preview" },
      args = { { name = "id", type = "TASK_ID", allow_done = true } },
      desc = "Show the file of a task (an open one, else its finished copy in Backlog/) rendered in the browser through mdview.nvim; the file is opened as it is, nothing is written to the vault",
      run = function(ctx)
        cmd().task_preview(ctx)
      end,
    },

    {
      path = { "open" },
      args = {
        { name = "area", type = "TASK_AREA" },
        {
          name = "folder",
          type = "STRING",
          enum = { "tasks", "roadmap", "backlog", "handover", "notes", "all" },
          optional = true,
        },
      },
      flags = {
        { name = "action", type = "STRING", enum = { "files", "grep", "smart" } },
        { name = "list", bool = true },
        { name = "to", type = "STRING", values = { "buffer", "clipboard", "file:", "echo" } },
        { name = "force", bool = true },
      },
      desc = "Picker over the files of one folder of an area (tasks|roadmap|backlog|handover|notes|all, default all) through pickers.nvim; --action=grep|smart searches content, --list or --to= delivers the file list",
      run = function(ctx)
        cmd().open_area(ctx)
      end,
    },
  }
end

---Where a nested path lands in the flat grammar of `:Tasks <verb>`.
---@param path string[]
---@return string[]
local function flat_path(path)
  local head = path[1]
  if head == "tasks" then
    return path[2] and { path[2] } or { "list" }
  elseif head == "task" then
    return { path[2] }
  elseif head == "open" then
    return { "folder" }
  end
  return path
end

---The route list of a verb.
---  - default (nested): `tasks`, `tasks index`, `task new|set|done|...`, `open` -- the nested grammar for a host verb
---  - `opts.flat = true`: the grammar of `:Tasks`: `list`, `index`, `new`, `set`, `done`, `attach`, `folderize`,
---    `template`, `open <id>`, `preview <id>`, and `folder <area> ...` (the old `open <area>`)
---@param opts? { flat?: boolean }
---@return table[] routes
function M.routes(opts)
  local routes = nested_routes()
  if opts and opts.flat then
    for _, route in ipairs(routes) do
      route.path = flat_path(route.path)
    end
  end
  return routes
end

return M
