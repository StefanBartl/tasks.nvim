---@module 'tasks_nvim.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately no vault: tasks.nvim has no opinion about where your vault lives. Without `vault` the engine
--- reads `$TASKS_VAULT` and otherwise reports "vault not found" instead of guessing a path.

---@class Tasks.DashboardConfig
---@field watch boolean        Refresh the dashboard when a task or Backlog file changes (file watchers).
---@field debounce_ms integer  Quiet period after a change before the list is rescanned.

---@class Tasks.StalenessConfig
---@field git_timeout_ms integer  One `git log` call is killed after this long (`--stale=refs`).
---@field budget_ms integer       All git calls of one `--stale=refs` run share this much time; the rest falls back to mtimes.
---@field repo_bases string[]     Folders that hold the repos by name (`<base>/<area>`); empty: derived from the vault and `$REPOS_DIR`.

---@class Tasks.NextConfig
---@field popup boolean     After finishing a task: offer the next one to open (a small dialog; headless sessions get a message).
---@field cdx_hint boolean  Name the ready tasks written `cdx` apart ("an AI session could take ..."), never as your next task.

---@class Tasks.StepsConfig
---@field ask_finish boolean  In a task buffer: when the LAST open step of `## Plan` is ticked, ask whether to finish the task (off by default: it adds an autocommand on task buffers).

---@class Tasks.ChainConfig
---@field marker_docs string[]  Documents whose `<!-- GENERATED:plan scope=... -->` blocks are refreshed after a task is finished. Only these files are ever touched (nothing is scanned); empty by default. The headless CLI has no `setup`: `$TASKS_MARKER_DOCS` (comma separated) names them there.

---@class Tasks.CiConfig
---@field lint_timeout_ms integer  The vault's `md_lint.lua` is killed after this long (`ci`).
---@field trust_vault_lint boolean  Allow `ci` to run `<vault>/TOOLS/scripts/md_lint.lua` (code from the vault itself).

---Key maps: an action name to a key, or `false` to switch that action's key off. An action that is not named
---keeps its default key.
---@alias Tasks.KeyMap table<string, string|false>

---@class Tasks.KeysConfig
---@field dashboard Tasks.KeyMap        Keys in the dashboard list window.
---@field dashboard_input Tasks.KeyMap  Keys in the dashboard input window (normal and insert mode).
---@field form Tasks.KeyMap             Buffer-local keys of the `:Tasks new` form.

---@class Tasks.Opts
---@field vault string|nil          Vault folder (one folder per area). `nil`: `$TASKS_VAULT` is read.
---@field extra_areas string[]      Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.
---@field dashboard Tasks.DashboardConfig
---@field staleness Tasks.StalenessConfig
---@field ci Tasks.CiConfig
---@field next Tasks.NextConfig
---@field chain Tasks.ChainConfig
---@field steps Tasks.StepsConfig
---@field keys Tasks.KeysConfig

---@type Tasks.Opts
return {
  vault = nil,
  extra_areas = {},
  dashboard = { watch = true, debounce_ms = 250 },
  staleness = { git_timeout_ms = 20000, budget_ms = 30000, repo_bases = {} },
  ci = { lint_timeout_ms = 120000, trust_vault_lint = false },
  next = { popup = true, cdx_hint = true },
  chain = { marker_docs = {} },
  steps = { ask_finish = false },
  keys = {
    dashboard = {
      status = "s",
      prio = "p",
      done = "D",
      filter = "f",
      sort = "o",
      export = "e",
      rescan = "r",
      backlog = "gb",
      roadmap = "gr",
      preview = "gp",
      help = "g?",
    },
    dashboard_input = {
      status = "<M-s>",
      prio = "<M-p>",
      done = "<M-d>",
      filter = "<M-f>",
      sort = "<M-o>",
      export = "<M-e>",
      rescan = "<M-r>",
      backlog = "<M-b>",
      roadmap = "<M-m>",
      preview = "<M-v>",
      help = "<M-?>",
    },
    form = {
      tick_space = "<Space>",
      tick_enter = "<CR>",
      submit = "<C-s>",
      cancel = "q",
      cancel_ctrl = "<C-q>",
      help = "g?",
    },
  },
}
