---@module 'tasks_nvim'
---@brief tasks.nvim: the task engine, pure Lua, no UI, no notifications.
---@description
--- Open tasks live in the vault as one Markdown file each
--- (`<area>/ROADMAP/tasks/<slug>.md`); this namespace reads, ranks, indexes,
--- creates, changes, finishes and checks them. The editor commands and the
--- headless CLI (`scripts/tasks.lua`) are front ends over these modules --
--- nothing here depends on either.
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
---  - `cli`    the command-line front end
---
--- Not its job: prompts, pickers, notifications, key bindings.

local M = {}

---Options of `setup` (every key optional).
---@class Tasks.SetupOpts
---@field vault? string          # The vault folder (one folder per area); without it `$TASKS_VAULT` is read.
---@field extra_areas? string[]  # Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.

---Tell the engine where the vault is. Safe to call twice; the last call wins per key.
---@param opts? Tasks.SetupOpts
---@return nil
function M.setup(opts)
  require("tasks_nvim.vault").configure(opts)
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
