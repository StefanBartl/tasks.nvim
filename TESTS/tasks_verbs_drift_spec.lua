-- TESTS/tasks_verbs_drift_spec.lua -- the verbs of `:Tasks` (the composer routes of `ui/routes.lua`) and of the CLI
-- (`SPECS` of `cli.lua`) are two tables that name the same things. They differ on purpose in places (the editor delivers
-- to buffers, quickfix and files with `--to`, `--force` and asks with `--yes`; the CLI takes every field as an option
-- where the editor opens a form), and by accident in others; `--stale-refs` of the CLI is `--stale=refs` in the editor.
--
-- This spec pins the difference as it is. It turns red when it changes: a verb or an option that is added to one table
-- only. Then either add it to the other table, or - if the difference is meant - change the pinned table below in the
-- same commit and say why.

return function(H)
  local eq = H.eq
  local routes = require("tasks_nvim.ui.routes")
  routes.register_types()
  local specs = require("tasks_nvim.cli").specs()

  local ONLY_CLI = {
    "areas",
    "bootstrap",
    "call",
    "check",
    "ci",
    "export",
    "import",
    "init-vault",
    "migrate-actor",
    "plan-new",
    "plans",
    "show",
  }
  local ONLY_COMPOSER = { "folder", "open", "planfile", "preview" }
  local OPTIONS = {
    ["answer"] = { composer = {}, cli = { "no-index" } },
    ["attach"] = { composer = {}, cli = { "clipboard", "latest", "name", "no-index" } },
    ["done"] = {
      composer = { "yes" },
      cli = { "commits", "date", "done-in", "no-index", "no-next", "remind", "unblock" },
    },
    ["estimate"] = { composer = { "list", "walk" }, cli = { "stale-refs" } },
    ["folderize"] = { composer = {}, cli = { "no-index" } },
    ["list"] = {
      composer = { "force", "list", "to" },
      cli = { "all", "done", "limit", "offset", "stale-refs" },
    },
    ["lists"] = {
      composer = {},
      cli = {
        "actor",
        "area",
        "blocked",
        "category",
        "desc",
        "effort",
        "kind",
        "phase",
        "plan",
        "prio",
        "quick-win",
        "ready",
        "reminders",
        "severity",
        "sort",
        "stale",
        "stale-refs",
        "status",
        "tag",
        "unestimated",
        "value",
        "waiting",
      },
    },
    ["new"] = {
      composer = {},
      cli = {
        "actor",
        "after",
        "category",
        "effort",
        "kind",
        "lang",
        "links",
        "no-index",
        "order",
        "phase",
        "plan",
        "prio",
        "refs",
        "severity",
        "slug",
        "status",
        "summary",
        "tags",
        "title",
        "value",
      },
    },
    ["next"] = { composer = {}, cli = { "format" } },
    ["plan"] = { composer = { "force", "list", "to" }, cli = { "stale-refs" } },
    ["quickwins"] = {
      composer = { "force", "phase", "to" },
      cli = { "max-effort", "min-value", "stale-refs" },
    },
    ["set"] = { composer = {}, cli = { "no-index" } },
    ["template"] = {
      composer = { "force", "to" },
      cli = { "effort", "kind", "lang", "prio", "tags", "title" },
    },
  }

  -- the composer side: the first word of each flat route and the names of its options
  local composer, composer_flags = {}, {}
  for _, route in ipairs(routes.routes({ flat = true })) do
    local names, flags = {}, {}
    for _, flag in ipairs(route.flags or {}) do
      names[flag.name] = true
      flags[flag.name] = flag.bool and true or false
    end
    composer[route.path[1]] = names
    composer_flags[route.path[1]] = flags
  end

  ---@param set table<string, boolean>
  ---@return string[]
  local function sorted(set)
    local out = {}
    for name in pairs(set) do
      out[#out + 1] = name
    end
    table.sort(out)
    return out
  end

  local only_cli, only_composer = {}, {}
  for verb in pairs(specs) do
    if not composer[verb] then
      only_cli[verb] = true
    end
  end
  for verb in pairs(composer) do
    if not specs[verb] then
      only_composer[verb] = true
    end
  end
  eq(sorted(only_cli), ONLY_CLI, "verbs only the CLI has: add the route, or pin the difference")
  eq(sorted(only_composer), ONLY_COMPOSER, "verbs only :Tasks has: add the CLI verb, or pin it")

  -- the options of the verbs both have
  local seen = {}
  for verb, cli in pairs(specs) do
    if composer[verb] then
      local in_cli = {}
      for _, name in ipairs(cli.value) do
        in_cli[name] = true
      end
      for _, name in ipairs(cli.flag) do
        in_cli[name] = true
      end
      local composer_only, cli_only = {}, {}
      for name in pairs(composer[verb]) do
        if not in_cli[name] then
          composer_only[name] = true
        end
      end
      for name in pairs(in_cli) do
        if not composer[verb][name] then
          cli_only[name] = true
        end
      end
      if next(composer_only) or next(cli_only) then
        seen[verb] = { composer = sorted(composer_only), cli = sorted(cli_only) }
      end
    end
  end
  eq(
    seen,
    OPTIONS,
    "the options of a verb differ between :Tasks and the CLI in a way that is not pinned"
  )

  -- an option both have takes a value in both or in neither (`--blocked` is not `--blocked=x` in the editor)
  local arity = {}
  for verb, cli in pairs(specs) do
    if composer[verb] then
      local cli_flag, cli_value = {}, {}
      for _, name in ipairs(cli.flag) do
        cli_flag[name] = true
      end
      for _, name in ipairs(cli.value) do
        cli_value[name] = true
      end
      for name, is_flag in pairs(composer_flags[verb]) do
        if (is_flag and cli_value[name]) or (not is_flag and cli_flag[name]) then
          arity[#arity + 1] = ("%s --%s: %s in :Tasks, %s in the CLI"):format(
            verb,
            name,
            is_flag and "a flag" or "a value",
            is_flag and "a value" or "a flag"
          )
        end
      end
    end
  end
  table.sort(arity)
  eq(arity, {}, "an option is a flag in one table and takes a value in the other")
end
