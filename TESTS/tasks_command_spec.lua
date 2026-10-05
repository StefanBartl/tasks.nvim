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

  -- ── completion: targets, paths after file:, tags, blockers, finished tasks ──
  local H_ = H
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local mutate = require("tasks_nvim.mutate")
  local vault = require("tasks_nvim.vault")
  local root = F.vault(H_)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H_.tmpdir() .. "/cp" }
  local alpha = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Alpha", tags = { "ui", "docs" } }))
  )
  local beta = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Beta" })))
  assert(mutate.done(beta.id, o))
  vault.set_root(root)
  ---@param line string
  ---@return string[]
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end
  eq(complete("Tasks list --to=fi"), { "--to=file:" }, "the target words complete")
  local dir_lead = "Tasks list --to=file:" .. root:sub(1, #root - #vim.fs.basename(root) + 1)
  local found_paths = complete(dir_lead)
  ok(
    #found_paths >= 1 and found_paths[1]:find("^%-%-to=file:") ~= nil,
    "a path after file: is completed like a file name"
  )
  eq(complete("Tasks list --tag="), { "--tag=docs", "--tag=ui" }, "tags of the open tasks")
  eq(
    complete("Tasks set " .. alpha.id .. " tags=ui,d"),
    { "tags=ui,docs" },
    "the item after the comma is completed"
  )
  eq(
    complete("Tasks set " .. alpha.id .. " blocked_by=[lib.nvim/"),
    { "blocked_by=[" .. alpha.id },
    "blocked_by completes open task ids"
  )
  eq(
    complete("Tasks open lib.nvim/"),
    { alpha.id, beta.id },
    "open takes a finished task too and offers it"
  )
  eq(complete("Tasks set lib.nvim/"), { alpha.id }, "set only offers open tasks")
  vault.set_root(nil)
end
