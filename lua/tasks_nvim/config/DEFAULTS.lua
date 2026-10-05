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

---@class Tasks.CiConfig
---@field lint_timeout_ms integer  The vault's `md_lint.lua` is killed after this long (`ci`).

---@class Tasks.Opts
---@field vault string|nil          Vault folder (one folder per area). `nil`: `$TASKS_VAULT` is read.
---@field extra_areas string[]      Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.
---@field dashboard Tasks.DashboardConfig
---@field staleness Tasks.StalenessConfig
---@field ci Tasks.CiConfig

---@type Tasks.Opts
return {
  vault = nil,
  extra_areas = {},
  dashboard = { watch = true, debounce_ms = 250 },
  staleness = { git_timeout_ms = 20000, budget_ms = 30000, repo_bases = {} },
  ci = { lint_timeout_ms = 120000 },
}
