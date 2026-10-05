---@module 'tasks_nvim.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately no vault: tasks.nvim has no opinion about where your vault lives. Without `vault` the engine
--- reads `$TASKS_VAULT` and otherwise reports "vault not found" instead of guessing a path.

---@class Tasks.Opts
---@field vault string|nil          Vault folder (one folder per area). `nil`: `$TASKS_VAULT` is read.
---@field extra_areas string[]      Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.

---@type Tasks.Opts
return {
  vault = nil,
  extra_areas = {},
}
