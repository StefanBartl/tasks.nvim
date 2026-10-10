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
---@type { at: integer, root: string|nil, open: Tasks.Task[]|nil, ids: string[]|nil, tags: string[]|nil, plan_ids: string[]|nil, plans_root: string|nil, plans_at: integer|nil }
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

---The ids of the open plan files (`plan=` and `--plan=` complete them), read at most every few seconds.
---@return string[]
local function open_plan_ids()
  local root = vault.root()
  if
    list_cache.plan_ids
    and list_cache.plans_root == root
    and now_ms() - (list_cache.plans_at or 0) < COMPLETE_TTL * 1000
  then
    return list_cache.plan_ids
  end
  local ok, plans = pcall(require("tasks_nvim.plans").all, {})
  local ids = {}
  for _, plan in ipairs(ok and plans or {}) do
    ids[#ids + 1] = plan.id
  end
  table.sort(ids)
  list_cache.plan_ids, list_cache.plans_root, list_cache.plans_at = ids, root, now_ms()
  return ids
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
    -- From the file names: `scan.backlog` reads and parses every finished task, which a <Tab> must not do (a thousand
    -- files cost a second each time the cache runs out). `scan.find_done` matches by slug too, so these are the ids
    -- `open`/`done`/`preview` accept; a Backlog document that is no task has no valid slug and is not offered.
    for _, a in ipairs(vault.areas(root)) do
      local ok, slugs = pcall(scan.backlog_slugs, a.name, { root = root })
      for slug in pairs(ok and slugs or {}) do
        if vault.valid_slug(slug) then
          ids[#ids + 1] = a.name .. "/" .. slug
        end
      end
    end
  end
  table.sort(ids)
  done_cache = { at = now_ms(), root = root, ids = ids }
  return ids
end

---The ids `done_ids` offers (exported for the specs).
M.done_ids = done_ids

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
  -- `desc`: the line lib.nvim's option float shows for a positional argument of this type that has no text of its
  -- own. A route whose argument plays another role words its own (`TESTS/tasks_usrcmds_help_spec.lua` and
  -- `TESTS/tasks_usrcmds_help_style_spec.lua` check both).
  composer.register_type("TASK_AREA", {
    desc = "Area of the vault (a folder with ROADMAP/ or Backlog/)",
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
    desc = "Id of an open task, as area/slug",
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

  composer.register_type("TASK_PLAN", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return prefix_ci(open_plan_ids(), arg_lead)
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

  composer.register_type("TASK_LIST", {
    desc = "Name of a list (built in, saved, or from setup({ lists }))",
    validate = function(raw)
      local entry, err = require("tasks_nvim.lists").get(raw)
      if entry then
        return true, raw, nil
      end
      return false, nil, err
    end,
    complete = function(arg_lead)
      local names = {}
      for _, e in ipairs(require("tasks_nvim.lists").all()) do
        names[#names + 1] = e.name
      end
      return prefix_ci(names, arg_lead)
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

-- Every flag, `key=` and positional argument below carries a one-line `desc` (and, where the values are not
-- self-explanatory, an `enum_desc`; an argument may rely on the `desc` of its type instead): lib.nvim's option float
-- shows them next to the option, and `TESTS/tasks_usrcmds_help_spec.lua` (on a lib.nvim that can list the undescribed
-- options) and `TESTS/tasks_usrcmds_help_style_spec.lua` (on any) fail for one that has none. The same word
-- can mean something else on another route (`to`, `format`, `status`, `area`, ...): each route words its own.

---The `--force` of every route that can write a `--to=file:` target.
local FORCE_DESC = "Overwrite an existing --to=file: target"

---The `<id>` of the routes that also take a finished task (`allow_done`) and only read it.
local ANY_TASK_DESC = "Id of a task, open or finished, as area/slug"

---Who can do a task, with what each value means (`model.ACTORS`; `none` only filters).
---@type table<string, string>
local ACTOR_VALUES = {
  cdx = "an AI session alone",
  me = "only you",
  pair = "the AI drafts, you decide",
}

---What each status of an open task says.
---@type table<string, string>
local STATUS_VALUES = {
  doing = "being worked on now",
  decision = "waits for your decision",
  blocked = "waits on another task",
  open = "not started yet",
  parked = "set aside for now",
}

---`--for=<id>` of `plan` and `estimate`: one task and what has to happen before it.
---@type table
local FOR_FLAG = {
  name = "for",
  type = "TASK_ID",
  desc = "Only this task and everything that must finish before it",
}

---`--plan=<id>` of `plan` and `estimate`: the tasks that name a plan file.
---@type table
local PLAN_FLAG =
  { name = "plan", type = "TASK_PLAN", desc = "Only the tasks of this plan file (area/slug)" }

---@type table[]
local LIST_FLAGS = {
  {
    name = "status",
    type = "STRING",
    values = model.OPEN_STATUSES,
    desc = "Only tasks with one of these statuses",
  },
  {
    name = "prio",
    type = "STRING",
    values = { "1", "2", "3", "<=2" },
    desc = "Only these priorities, or <=N for N and more urgent",
  },
  {
    name = "effort",
    type = "STRING",
    values = { "XS", "S", "M", "L", "XL", "<=S", "<=M" },
    desc = "Only these efforts, or <=M for M and smaller",
  },
  { name = "kind", type = "STRING", values = model.KINDS, desc = "Only tasks of these kinds" },
  {
    name = "category",
    type = "STRING",
    values = model.CATEGORIES,
    desc = "Only tasks in these categories; kind bug counts as bug",
  },
  {
    name = "severity",
    type = "STRING",
    values = model.SEVERITIES,
    desc = "Only tasks with one of these severities",
  },
  {
    name = "value",
    type = "STRING",
    values = { "1", "2", "3", "4", "5", ">=4" },
    desc = "Only these values (1-5), or >=N for N and above",
  },
  {
    name = "actor",
    type = "STRING",
    values = { "cdx", "me", "pair", "none" },
    desc = "Only tasks for these actors; none = unclassified",
  },
  { name = "tag", type = "TASK_TAGS", desc = "Only tasks carrying one of these tags" },
  {
    name = "list",
    type = "TASK_LIST",
    desc = "Start from a named list; the options you give win",
  },
  {
    name = "stale",
    type = "STRING",
    values = { "7", "30", "90", "refs" },
    desc = "Only tasks untouched for N days; refs = a ref file changed",
  },
  {
    name = "blocked",
    bool = true,
    desc = "Only tasks with status blocked or a blocked_by list",
  },
  { name = "ready", bool = true, desc = "Only tasks that can start now (no open blocker)" },
  { name = "waiting", bool = true, desc = "Only tasks that wait on an open blocker" },
  { name = "unestimated", bool = true, desc = "Only tasks missing an effort or a value" },
  {
    name = "quick-win",
    bool = true,
    desc = "Only quick wins (value and effort at the quick_wins thresholds)",
  },
  {
    name = "sort",
    type = "STRING",
    enum = model.SORTS,
    desc = "How to order the list (default: status, prio, area, slug)",
    enum_desc = {
      default = "status, then prio, area, slug",
      ["prio-effort"] = "like default, small effort first within a prio",
      severity = "critical first, then high, medium, low",
      frecency = "most opened or changed in the dashboard first",
      roi = "highest value per effort first",
    },
  },
  {
    name = "to",
    type = "TASK_TARGET",
    values = { "buffer", "clipboard", "qf", "file:", "echo", "mdview" },
    desc = "Deliver the list here instead of the dashboard",
  },
  {
    name = "format",
    type = "STRING",
    enum = { "md", "csv" },
    desc = "Markdown table or CSV with extra columns; skips the dashboard",
    enum_desc = { md = "Markdown table", csv = "one row per task, more columns" },
  },
  { name = "force", bool = true, desc = FORCE_DESC },
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

---The texts of the task fields, for `task set` and (where the field is the same) `task new`. `status` and `title`
---differ between the two and are worded where they are used.
---@type table<string, string>
local FIELD_DESC = {
  kind = "What sort of work it is; picks the Backlog folder on done",
  prio = "Urgency from 1 (most urgent) to 3",
  effort = "Size: XS to XL, or days such as 0.5d",
  tags = "Free labels, comma-separated; filter with --tag",
  category = "Concerns the task serves; several allowed, comma list",
  severity = "How serious a bug or security task is",
  value = "Expected benefit from 1 (little) to 5 (a lot)",
  actor = "Who can take the task on: an AI session, you or both",
  after = "Tasks it should come after, without waiting (ids)",
  order = "Tie-breaker within a stage; 2.5 sorts between 2 and 3",
  plan = "Plan file this task belongs to (area/slug)",
  phase = "Stage of that plan the task belongs to",
}

---The values worth a word of their own in the option float, per `key=`.
---@type table<string, table<string, string>>
local FIELD_VALUES = { actor = ACTOR_VALUES, status = STATUS_VALUES }

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
  local descs = vim.tbl_extend("force", FIELD_DESC, {
    title = "New title (the file name stays)",
    status = "Move the task to this status (not done: use task done)",
    summary = "One-line summary shown in the index",
    blocked_by = "Tasks that must finish first (ids, comma-separated)",
    refs = "Files the task is about; --stale=refs watches them",
    rules = "Rule ids a ruleset task brings code in line with",
    done_in = "Commit(s) that delivered the task",
    created = "Creation date, YYYY-MM-DD",
  })
  local out = {}
  for _, key in ipairs(mutate.SETTABLE) do
    local kind = "STRING"
    if key == "tags" then
      kind = "TASK_TAGS"
    elseif key == "blocked_by" then
      kind = "TASK_IDS"
    end
    out[#out + 1] = {
      key = key,
      type = kind,
      values = hints[key],
      desc = descs[key],
      enum_desc = FIELD_VALUES[key],
    }
  end
  return out
end

---The routes in the nested grammar (a host config can mount them under its own verb) (`tasks`, `tasks index`, `task <verb>`, `open`).
---@return table[] routes
local function nested_routes()
  return {
    {
      path = { "tasks" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          allow_all = true,
          optional = true,
          desc = "Area to list, or all (default: all areas)",
        },
      },
      flags = LIST_FLAGS,
      desc = "List the open tasks of one area (default: all) as a Markdown table in a scratch buffer; filter with --status= --prio= --effort=S,M|<=M --kind= --category=bug|security|performance|docs|ruleset --severity=low|medium|high|critical --tag= --stale=<days>|refs (refs: a file named in refs: changed since updated) --blocked, order with --sort=default|prio-effort|severity|frecency, deliver with --to=buffer|clipboard|qf|file:<path>|mdview (a browser preview through mdview.nvim, Markdown only) and --format=md|csv",
      run = function(ctx)
        cmd().list(ctx)
      end,
    },

    {
      path = { "tasks", "index" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          optional = true,
          desc = "Area to index (default: every area)",
        },
      },
      flags = {
        {
          name = "check",
          bool = true,
          desc = "Only report rule findings and stale indexes, write nothing",
        },
        { name = "all", bool = true, desc = "Index every area (overrides a named area)" },
      },
      desc = "(Re)write ROADMAP/TASKS.md of one area (default: every area); --check writes nothing and reports rule findings and stale indexes",
      run = function(ctx)
        cmd().index(ctx)
      end,
    },

    {
      path = { "task", "new" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          optional = true,
          desc = "Area to create the task in (none: open the form)",
        },
      },
      kv = {
        { key = "kind", type = "STRING", values = model.KINDS, desc = FIELD_DESC.kind },
        { key = "prio", type = "STRING", values = { "1", "2", "3" }, desc = FIELD_DESC.prio },
        { key = "effort", type = "STRING", values = model.EFFORTS, desc = FIELD_DESC.effort },
        { key = "tags", type = "TASK_TAGS", desc = FIELD_DESC.tags },
        {
          key = "category",
          type = "STRING",
          values = model.CATEGORIES,
          desc = FIELD_DESC.category,
        },
        {
          key = "severity",
          type = "STRING",
          values = model.SEVERITIES,
          desc = FIELD_DESC.severity,
        },
        {
          key = "value",
          type = "STRING",
          values = { "1", "2", "3", "4", "5" },
          desc = FIELD_DESC.value,
        },
        {
          key = "actor",
          type = "STRING",
          values = model.ACTORS,
          desc = FIELD_DESC.actor,
          enum_desc = ACTOR_VALUES,
        },
        { key = "after", type = "TASK_IDS", desc = FIELD_DESC.after },
        { key = "order", type = "STRING", desc = FIELD_DESC.order },
        { key = "plan", type = "TASK_PLAN", desc = FIELD_DESC.plan },
        { key = "phase", type = "STRING", desc = FIELD_DESC.phase },
        {
          key = "status",
          type = "STRING",
          values = model.OPEN_STATUSES,
          desc = "Status to start in (default: open)",
          enum_desc = STATUS_VALUES,
        },
      },
      flags = {
        {
          name = "folder",
          bool = true,
          desc = "Create a folder task (<slug>/<slug>.md) that can hold assets",
        },
      },
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
      args = {
        {
          name = "id",
          type = "TASK_ID",
          allow_done = true,
          desc = "Id of the task to finish, as area/slug",
        },
      },
      kv = {
        {
          key = "done_in",
          type = "STRING",
          desc = "Commit(s) that delivered it, recorded in the finished file",
        },
        {
          key = "date",
          type = "STRING",
          desc = "Date prefix of the Backlog file (YYYY-MM-DD, default today)",
        },
      },
      flags = { { name = "yes", bool = true, desc = "Finish without asking for confirmation" } },
      desc = "Finish a task after confirmation: status done, moved to Backlog/FEATURES|TASKS with a date prefix, Backlog README and index updated; --yes skips the question",
      run = function(ctx)
        cmd().task_done(ctx)
      end,
    },

    {
      path = { "task", "attach" },
      args = {
        {
          name = "id",
          type = "TASK_ID",
          desc = "Id of the task to attach the file to, as area/slug",
        },
        { name = "file", type = "FILE", desc = "File to copy into the task's assets/ folder" },
      },
      kv = {
        {
          key = "name",
          type = "STRING",
          desc = "Name for the copy in assets/ (default: the file's name)",
        },
      },
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
        {
          name = "to",
          type = "TASK_TARGET",
          values = { "clipboard", "buffer", "file:" },
          desc = "Where the template goes (default: clipboard)",
        },
        { name = "force", bool = true, desc = FORCE_DESC },
        {
          name = "with-plan",
          bool = true,
          desc = "Add the optional ## Plan section with checkbox steps",
        },
      },
      desc = "Copy the task file template to the + register (--to=buffer|file:<path> for the other targets; --with-plan adds the optional ## Plan section)",
      run = function(ctx)
        cmd().task_template(ctx)
      end,
    },

    {
      path = { "task", "plan" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          allow_all = true,
          optional = true,
          desc = "Area to plan, or all (default: all areas)",
        },
      },
      flags = filter_flags({
        FOR_FLAG,
        PLAN_FLAG,
        { name = "ready", bool = true, desc = "Show only the part that can be started now" },
        {
          name = "with-steps",
          bool = true,
          desc = "Show each task's ## Plan steps and their progress",
        },
        {
          name = "write",
          type = "STRING",
          desc = "Replace the generated plan block in this Markdown file",
        },
        {
          name = "scope",
          type = "STRING",
          desc = "Block name for --write (default: derived from the scope)",
        },
        {
          name = "check",
          bool = true,
          desc = "With --write: only say whether the block is out of date",
        },
        {
          name = "format",
          type = "STRING",
          enum = { "md", "tsv", "ids" },
          desc = "How the plan is written: Markdown, tab-separated or ids",
          enum_desc = {
            md = "readable plan with stages",
            tsv = "one tab-separated row per task",
            ids = "task ids only, in plan order",
          },
        },
        {
          name = "to",
          type = "TASK_TARGET",
          values = { "buffer", "clipboard", "file:", "echo", "mdview" },
          desc = "Deliver the plan here (default: a scratch buffer)",
        },
        { name = "force", bool = true, desc = FORCE_DESC },
      }),
      desc = "The plan of the open tasks of an area (default: all) or of one task and everything before it (--for=<id>): what is ready now, decisions by leverage, stages, critical path, an estimate line; filters like list; --ready shows only what can be started",
      run = function(ctx)
        cmd().plan(ctx)
      end,
    },

    {
      path = { "task", "planfile" },
      args = {
        { name = "area", type = "TASK_AREA", desc = "Area to create the plan file in" },
      },
      flags = {
        {
          name = "areas",
          type = "STRING",
          desc = "Areas whose tasks may belong to the plan (comma list)",
        },
        {
          name = "target",
          type = "TASK_ID",
          desc = "The task that means the plan is done (area/slug)",
        },
        { name = "phases", type = "STRING", desc = "Names of the stages in order (comma list)" },
        {
          name = "gate",
          type = "STRING",
          enum = { "hard" },
          desc = "Make the stage order a hard rule instead of a hint",
          enum_desc = { hard = "a stage waits until the earlier ones are finished" },
        },
        {
          name = "status",
          type = "STRING",
          enum = { "planning", "doing", "parked" },
          desc = "Status the new plan starts in (default: planning)",
        },
      },
      desc = "Create a plan file ROADMAP/plans/<slug>.md in an area (the words after the area are the title): the undertaking that tasks join with plan=<id> phase=<word>; --areas=a,b lists the areas whose tasks belong, --phases=a,b,c names the stages in order, --gate=hard forbids starting a stage before the earlier ones are finished, --target=<task> is the task that means done",
      run = function(ctx)
        cmd().planfile(ctx)
      end,
    },

    {
      path = { "task", "next" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          allow_all = true,
          optional = true,
          desc = "Area to pick from, or all (default: all areas)",
        },
      },
      flags = {
        {
          name = "n",
          type = "STRING",
          values = { "1", "2", "3", "5" },
          desc = "How many ready tasks to show, best first (default 3)",
        },
        {
          name = "actor",
          type = "STRING",
          values = { "cdx", "me", "pair", "none" },
          desc = "Show the queue of this actor instead of yours",
        },
      },
      desc = "What to start next: the best ready task with the reason, and a dialog to jump into it; --actor=cdx asks for the AI queue instead of yours",
      run = function(ctx)
        cmd().next(ctx)
      end,
    },

    {
      path = { "task", "estimate" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          allow_all = true,
          optional = true,
          desc = "Area to total up, or all (default: all areas)",
        },
      },
      flags = filter_flags({
        FOR_FLAG,
        PLAN_FLAG,
        {
          name = "walk",
          bool = true,
          desc = "Ask for each missing effort or value, one task at a time",
        },
      }),
      desc = "Sums of effort and value of an area (default: all) or of one task and everything before it, with what is missing; --walk goes through the tasks without effort or value and asks for them one by one",
      run = function(ctx)
        cmd().estimate(ctx)
      end,
    },

    {
      path = { "task", "lists" },
      args = {},
      flags = {},
      desc = "Pick a named list (built in, saved, or from setup({ lists })) and open it as the task dashboard; save and delete lists with the dashboard key gl or `tasks lists`",
      run = function(ctx)
        cmd().lists(ctx)
      end,
    },

    {
      path = { "task", "quickwins" },
      args = {
        {
          name = "area",
          type = "TASK_AREA",
          allow_all = true,
          optional = true,
          desc = "Area to look at, or all (default: all areas)",
        },
      },
      flags = (function()
        -- `--quick-win`, `--value` and `--effort` ARE the definition here; `--status` defaults to what can be started.
        local skip = { ["quick-win"] = true, value = true, effort = true, sort = true }
        local out = {}
        for _, flag in ipairs(filter_flags({ PLAN_FLAG })) do
          if not skip[flag.name] then
            out[#out + 1] = flag
          end
        end
        vim.list_extend(out, {
          {
            name = "to",
            type = "TASK_TARGET",
            values = { "buffer", "clipboard", "qf", "file:", "echo", "mdview" },
            desc = "Deliver the report here (default: a scratch buffer)",
          },
          {
            name = "format",
            type = "STRING",
            values = { "md", "tsv", "ids" },
            desc = "Markdown report (default), tab-separated lines or ids",
          },
          {
            name = "by-actor",
            bool = true,
            desc = "Split the quick wins by who can do them",
          },
          {
            name = "paths",
            bool = true,
            desc = "Add the absolute path of each task file",
          },
          {
            name = "report",
            type = "STRING",
            desc = "Write the Markdown to this file (never replaces a hand-written one)",
          },
          { name = "force", bool = true, desc = "Replace an existing target of --to=file:" },
        })
        return out
      end)(),
      desc = "The quick wins (value 4+ and effort S or less by default, both written on the task), best return first, plus the small tasks that miss a value; --report=<file> writes the Markdown",
      run = function(ctx)
        cmd().quickwins(ctx)
      end,
    },

    {
      path = { "task", "open" },
      args = { { name = "id", type = "TASK_ID", allow_done = true, desc = ANY_TASK_DESC } },
      desc = "Open the file of a task (an open one, else its finished copy in Backlog/)",
      run = function(ctx)
        cmd().task_open(ctx)
      end,
    },

    {
      path = { "task", "preview" },
      args = { { name = "id", type = "TASK_ID", allow_done = true, desc = ANY_TASK_DESC } },
      desc = "Show the file of a task (an open one, else its finished copy in Backlog/) rendered in the browser through mdview.nvim; the file is opened as it is, nothing is written to the vault",
      run = function(ctx)
        cmd().task_preview(ctx)
      end,
    },

    {
      path = { "open" },
      args = {
        { name = "area", type = "TASK_AREA", desc = "Area whose files to pick from" },
        {
          name = "folder",
          type = "STRING",
          enum = { "tasks", "roadmap", "backlog", "handover", "notes", "all" },
          optional = true,
          desc = "Folder of the area to look in (default: all)",
          enum_desc = {
            tasks = "the open task files",
            roadmap = "the whole ROADMAP/ folder",
            backlog = "the finished tasks",
            all = "everything in the area",
          },
        },
      },
      flags = {
        {
          name = "action",
          type = "STRING",
          enum = { "files", "grep", "smart" },
          desc = "What the picker searches: file names, content or both",
          enum_desc = {
            files = "pick a file by name",
            grep = "search the content of the files",
            smart = "names and content in one live picker",
          },
        },
        { name = "list", bool = true, desc = "Print the file list instead of opening a picker" },
        {
          name = "to",
          type = "TASK_TARGET",
          values = { "buffer", "clipboard", "file:", "echo" },
          desc = "Deliver the file list to a target instead of a picker",
        },
        { name = "force", bool = true, desc = FORCE_DESC },
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
