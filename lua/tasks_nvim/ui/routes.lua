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

---What the completions read, kept for `COMPLETE_TTL` seconds per vault: the open tasks (parsing 466 files is
---96 ms, too slow for every `<Tab>`), their sorted ids and tags, and the ids of the finished ones.
---@type { at: integer, root: string|nil, open: Tasks.Task[]|nil, ids: string[]|nil, tags: string[]|nil }
local list_cache = { at = 0 }
---@type { at: integer, root: string|nil, ids: string[]|nil }
local done_cache = { at = 0 }

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

---@return integer
local function now_ms()
  return (vim.uv or vim.loop).now()
end

---@return Tasks.Task[]
local function cached_open()
  local root = vault.root()
  if
    list_cache.open
    and list_cache.root == root
    and now_ms() - list_cache.at < COMPLETE_TTL * 1000
  then
    return list_cache.open
  end
  local ok, open = pcall(scan.open_tasks, { ttl_seconds = COMPLETE_TTL })
  if not ok or not open then
    return {}
  end
  list_cache = { at = now_ms(), root = root, open = open }
  return open
end

---@return string[]
local function open_ids()
  local open = cached_open()
  if not list_cache.ids or list_cache.open ~= open then
    local ids = {}
    for _, t in ipairs(open) do
      ids[#ids + 1] = t.id
    end
    table.sort(ids)
    list_cache.ids = ids
  end
  return list_cache.ids or {}
end

---@return string[]
local function open_tags()
  local open = cached_open()
  if not list_cache.tags or list_cache.open ~= open then
    local seen, tags = {}, {}
    for _, t in ipairs(open) do
      for _, tag in ipairs(t.tags or {}) do
        if not seen[tag] then
          seen[tag] = true
          tags[#tags + 1] = tag
        end
      end
    end
    table.sort(tags)
    list_cache.tags = tags
  end
  return list_cache.tags or {}
end

---The ids of the finished tasks (`open` and `preview` take one too).
---@return string[]
local function done_ids()
  local root = vault.root()
  if
    done_cache.ids
    and done_cache.root == root
    and now_ms() - done_cache.at < COMPLETE_TTL * 1000
  then
    return done_cache.ids
  end
  local ids = {}
  if root then
    for _, a in ipairs(vault.areas(root)) do
      local ok, finished = pcall(scan.backlog, a.name, { root = root })
      for _, t in ipairs(ok and finished or {}) do
        ids[#ids + 1] = t.id
      end
    end
  end
  table.sort(ids)
  done_cache = { at = now_ms(), root = root, ids = ids }
  return ids
end

---Complete the item under the cursor of a comma list (`ui,do` -> `ui,docs`); what is before it stays, a leading
---`[` of a `blocked_by=[a, b]` value too.
---@param lead string
---@param candidates string[]
---@return string[]
local function complete_list(lead, candidates)
  local head = lead:match("^(.*[,%[])") or ""
  local item = vim.trim(lead:sub(#head + 1))
  local out = {}
  for _, c in ipairs(prefix_ci(candidates, item)) do
    out[#out + 1] = head .. c
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
    complete = function(arg_lead, spec)
      if spec and spec.allow_done then
        local both = vim.list_extend({}, open_ids())
        vim.list_extend(both, done_ids())
        table.sort(both)
        return prefix_ci(both, arg_lead)
      end
      return prefix_ci(open_ids(), arg_lead)
    end,
  })

  -- `--to=`: the target words, and after `file:` a path completed like a file name (the prefix stays).
  composer.register_type("TASK_TARGET", {
    validate = function(raw)
      -- Whether the target is usable is `view.parse_target`'s answer at run time.
      return true, raw, nil
    end,
    complete = function(arg_lead, spec)
      if arg_lead:sub(1, 5) == "file:" then
        local ok, found = pcall(vim.fn.getcompletion, arg_lead:sub(6), "file")
        local out = {}
        for _, p in ipairs(ok and found or {}) do
          out[#out + 1] = "file:" .. p
        end
        return out
      end
      local words = (spec and spec.values)
        or { "buffer", "clipboard", "qf", "file:", "echo", "mdview" }
      return prefix_ci(words, arg_lead)
    end,
  })

  composer.register_type("TASK_TAGS", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return complete_list(arg_lead, open_tags())
    end,
  })

  composer.register_type("TASK_IDS", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return complete_list(arg_lead, open_ids())
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
  { name = "value", type = "STRING", values = { "1", "2", "3", "4", "5", ">=4" } },
  { name = "actor", type = "STRING", values = { "cdx", "me", "pair", "none" } },
  { name = "tag", type = "TASK_TAGS" },
  { name = "stale", type = "STRING", values = { "7", "30", "90", "refs" } },
  { name = "blocked", bool = true },
  { name = "ready", bool = true },
  { name = "waiting", bool = true },
  { name = "unestimated", bool = true },
  { name = "sort", type = "STRING", enum = model.SORTS },
  {
    name = "to",
    type = "TASK_TARGET",
    values = { "buffer", "clipboard", "qf", "file:", "echo", "mdview" },
  },
  { name = "format", type = "STRING", enum = { "md", "csv" } },
  { name = "force", bool = true },
}

---The filter flags of `list`, for the commands that take the same filters (`plan`, `estimate`).
---@param extra table[]
---@return table[]
local function filter_flags(extra)
  local skip = { sort = true, to = true, format = true, force = true, ready = true, waiting = true }
  local out = {}
  for _, flag in ipairs(LIST_FLAGS) do
    if not skip[flag.name] then
      out[#out + 1] = flag
    end
  end
  vim.list_extend(out, extra)
  return out
end

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
    value = { "1", "2", "3", "4", "5" },
    actor = model.ACTORS,
  }
  local out = {}
  for _, key in ipairs(mutate.SETTABLE) do
    local kind = "STRING"
    if key == "tags" then
      kind = "TASK_TAGS"
    elseif key == "blocked_by" then
      kind = "TASK_IDS"
    end
    out[#out + 1] = { key = key, type = kind, values = hints[key] }
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
        { key = "tags", type = "TASK_TAGS" },
        { key = "category", type = "STRING", values = model.CATEGORIES },
        { key = "severity", type = "STRING", values = model.SEVERITIES },
        { key = "value", type = "STRING", values = { "1", "2", "3", "4", "5" } },
        { key = "actor", type = "STRING", values = model.ACTORS },
        { key = "after", type = "TASK_IDS" },
        { key = "order", type = "STRING" },
        { key = "status", type = "STRING", values = model.OPEN_STATUSES },
      },
      flags = { { name = "folder", bool = true } },
      range = true,
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
        { name = "to", type = "TASK_TARGET", values = { "clipboard", "buffer", "file:" } },
        { name = "force", bool = true },
        { name = "with-plan", bool = true },
      },
      desc = "Copy the task file template to the + register (--to=buffer|file:<path> for the other targets; --with-plan adds the optional ## Plan section)",
      run = function(ctx)
        cmd().task_template(ctx)
      end,
    },

    {
      path = { "task", "plan" },
      args = { { name = "area", type = "TASK_AREA", allow_all = true, optional = true } },
      flags = filter_flags({
        { name = "for", type = "TASK_ID" },
        { name = "ready", bool = true },
        { name = "with-steps", bool = true },
        { name = "format", type = "STRING", enum = { "md", "tsv", "ids" } },
        {
          name = "to",
          type = "TASK_TARGET",
          values = { "buffer", "clipboard", "file:", "echo", "mdview" },
        },
        { name = "force", bool = true },
      }),
      desc = "The plan of the open tasks of an area (default: all) or of one task and everything before it (--for=<id>): what is ready now, decisions by leverage, stages, critical path, an estimate line; filters like list; --ready shows only what can be started",
      run = function(ctx)
        cmd().plan(ctx)
      end,
    },

    {
      path = { "task", "next" },
      args = { { name = "area", type = "TASK_AREA", allow_all = true, optional = true } },
      flags = {
        { name = "n", type = "STRING", values = { "1", "2", "3", "5" } },
        { name = "actor", type = "STRING", values = { "cdx", "me", "pair", "none" } },
      },
      desc = "What to start next: the best ready task with the reason, and a dialog to jump into it; --actor=cdx asks for the AI queue instead of yours",
      run = function(ctx)
        cmd().next(ctx)
      end,
    },

    {
      path = { "task", "estimate" },
      args = { { name = "area", type = "TASK_AREA", allow_all = true, optional = true } },
      flags = filter_flags({
        { name = "for", type = "TASK_ID" },
        { name = "walk", bool = true },
      }),
      desc = "Sums of effort and value of an area (default: all) or of one task and everything before it, with what is missing; --walk goes through the tasks without effort or value and asks for them one by one",
      run = function(ctx)
        cmd().estimate(ctx)
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
        { name = "to", type = "TASK_TARGET", values = { "buffer", "clipboard", "file:", "echo" } },
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
