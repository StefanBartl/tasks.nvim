---@module 'tasks_nvim.bindings.usrcmds.vault'
---@brief Registers the `:TasksVault` user command (composer verb): the vault itself, not the tasks in it.
---@description
--- `:TasksVault <verb> [<area>] [<part>]` opens, copies, pastes and searches the Backlog (or another part) of an
--- area, makes notes in it and creates a vault (`create`). The routes live in `tasks_nvim.ui.vault_routes`, the
--- handlers in `tasks_nvim.ui.vault_cmd`; this file only registers them, once.
---
--- The command is registered even when no vault is set up: `create` is what makes one, and every other verb
--- then says so once instead of failing in a different way each time. `vim.g.tasks_nvim_no_vault_command = true`
--- keeps it out.

local M = {}

local registered = false
local warned = false

---Register `:TasksVault`. Safe to call twice; needs `lib.nvim` (the composer), otherwise it warns once and
---returns false.
---@return boolean ok
function M.register()
  if registered then
    return true
  end
  if vim.g.tasks_nvim_no_vault_command then
    return false
  end
  local ok, err = pcall(function()
    local composer = require("lib.nvim.bindings.usercmd.composer")
    local routes = require("tasks_nvim.ui.vault_routes")
    routes.register_types()
    composer.verb("TasksVault", {
      desc = "The task vault: open, copy, paste and search the Backlog of an area, make notes, create a vault",
      routes = routes.routes(),
      default = function(ctx)
        require("tasks_nvim.ui.vault_cmd").status(ctx)
      end,
    })
  end)
  if not ok then
    if not warned then
      warned = true
      vim.schedule(function()
        require("lib.nvim.notify")
          .create("[tasks]")
          .warn(":TasksVault is unavailable: " .. tostring(err))
      end)
    end
    return false
  end
  registered = true
  return true
end

return M
