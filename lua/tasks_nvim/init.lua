---@module 'tasks_nvim'
---@brief tasks.nvim: the task engine (pure Lua) and its front ends (`ui/`, `bindings/`).
---@description
--- Open tasks live in the vault as one Markdown file each
--- (`<area>/ROADMAP/tasks/<slug>.md`); this namespace reads, ranks, indexes,
--- creates, changes, finishes and checks them. The engine modules listed
--- below are UI-free (no notifications, no windows); the editor commands
--- (`ui/`, `bindings/`) and the headless CLI (`scripts/tasks.lua`) sit on top.
---
--- Submodules are loaded on first access:
---  - `vault`  root, areas, paths, id/slug validation
---  - `model`  the task record, enums, ranking, filters
---  - `scan`   collect task files
---  - `index`  render and write `ROADMAP/TASKS.md`, the global export text
---  - `mutate` template, new, set, done
---  - `check`  the rule checker
---  - `staleness`  `--stale=refs`: tasks whose referenced files changed since `updated`
---  - `frecency`  the visit score behind `--sort=frecency` (pure scoring, small state file)
---  - `ci`     the vault gate for pipelines (check + index --check + md_lint)
---  - `batch`  several `set` / `done` in one go, the index regenerated once per area
---  - `cli`    the command-line front end
---
--- Not its job: prompts, pickers, notifications, key bindings.

local M = {}

---Options of `setup` (every key optional).
---@class Tasks.SetupOpts
---@field vault? string          # The vault folder (one folder per area); without it `$TASKS_VAULT` is read.
---@field extra_areas? string[]  # Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.
---@field dashboard? { watch?: boolean, debounce_ms?: integer }
---@field staleness? { git_timeout_ms?: integer, budget_ms?: integer, repo_bases?: string[] }
---@field ci? { lint_timeout_ms?: integer }
-- Defaults and validation: `tasks_nvim.config`.

---Tell the engine where the vault is. Safe to call twice; the last call wins per key.
---@param opts? Tasks.SetupOpts
---@return nil
function M.setup(opts)
  local config = require("tasks_nvim.config")
  require("tasks_nvim.vault").configure(config.merge(opts))
  -- The entry point is where the user is told what was ignored (the config layer only collects it).
  local messages = config.take_unannounced()
  if #messages > 0 then
    vim.schedule(function()
      local notify = require("lib.nvim.notify").create("[tasks]")
      for _, msg in ipairs(messages) do
        notify.warn(msg)
      end
    end)
  end
  -- `:Tasks` is registered by `plugin/tasks_nvim.lua` (which a plugin manager sources when it loads the
  -- plugin); the engine facade does not reach into the front end.
end

local SUBMODULES = {
  vault = true,
  model = true,
  scan = true,
  index = true,
  mutate = true,
  check = true,
  staleness = true,
  frecency = true,
  ci = true,
  cli = true,
  batch = true,
}

return setmetatable(M, {
  __index = function(t, key)
    if SUBMODULES[key] then
      local mod = require("tasks_nvim." .. key)
      rawset(t, key, mod)
      return mod
    end
    return nil
  end,
})
