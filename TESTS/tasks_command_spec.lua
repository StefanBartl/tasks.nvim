-- TESTS/tasks_command_spec.lua -- the two route grammars of tasks_nvim.ui.routes and the `:Tasks` registration.

return function(H)
  local eq, ok = H.eq, H.ok
  local routes = require("tasks_nvim.ui.routes")

  ---@param list table[]
  ---@return string[]
  local function paths(list)
    local out = {}
    for _, r in ipairs(list) do
      out[#out + 1] = table.concat(r.path, " ")
    end
    table.sort(out)
    return out
  end

  eq(paths(routes.routes()), {
    "open",
    "task attach",
    "task done",
    "task folderize",
    "task new",
    "task open",
    "task preview",
    "task set",
    "task template",
    "tasks",
    "tasks index",
  }, "the nested grammar (`:MyPlugins`) is unchanged")
  eq(paths(routes.routes({ flat = true })), {
    "attach",
    "done",
    "folder",
    "folderize",
    "index",
    "list",
    "new",
    "open",
    "preview",
    "set",
    "template",
  }, "the flat grammar of `:Tasks`: no two routes share a path")
  eq(#routes.routes({ flat = true }), #routes.routes(), "same number of routes")

  -- a second call must not see the first call's paths changed
  eq(paths(routes.routes())[1], "open", "routes() builds a fresh list each time")

  local command = require("tasks_nvim.bindings.usrcmds")
  ok(command.register(), "register succeeds with lib.nvim on the runtimepath")
  ok(command.register(), "and a second time")
  eq(vim.fn.exists(":Tasks"), 2, ":Tasks exists")
end
