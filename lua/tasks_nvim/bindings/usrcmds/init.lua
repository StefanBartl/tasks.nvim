---@module 'tasks_nvim.bindings.usrcmds'
---@brief Registers the `:Tasks` user command (composer verb) with the flat route grammar.
---@description
--- `:Tasks <verb>`: `list`, `index`, `new`, `set`, `done`, `attach`, `folderize`, `template`, `open <id>`,
--- `preview <id>` and `folder <area> ...`. The routes, the argument types and the handlers live in
--- `tasks_nvim.ui.routes` / `tasks_nvim.ui.cmd`; this file only registers them, once. A config that wants a
--- different command name or grammar calls `routes.routes()` itself and registers its own verb.

local M = {}

local registered = false

---Register `:Tasks`. Safe to call twice; needs `lib.nvim` (the composer), otherwise it warns once and returns false.
---@return boolean ok
function M.register()
  if registered then
    return true
  end
  local ok, err = pcall(function()
    local composer = require("lib.nvim.bindings.usercmd.composer")
    local routes = require("tasks_nvim.ui.routes")
    routes.register_types()
    composer.verb("Tasks", {
      desc = "Tasks of a Markdown task vault: list, create, change, finish, open",
      routes = routes.routes({ flat = true }),
    })
  end)
  if not ok then
    vim.schedule(function()
      vim.notify("[tasks.nvim] :Tasks is unavailable: " .. tostring(err), vim.log.levels.WARN)
    end)
    return false
  end
  registered = true
  return true
end

return M
