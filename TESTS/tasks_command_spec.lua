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
  local scan = require("tasks_nvim.scan")
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

  -- ── NEW-23: `:'<,'>Tasks new` makes a task about the selected lines ──
  local cmd = require("tasks_nvim.ui.cmd")
  eq(cmd.range_source({ range = { range = 0, line1 = 1, line2 = 1 } }), nil, "no range: no source")
  local code_dir = H_.tmpdir() .. "/code"
  vim.fn.mkdir(code_dir, "p")
  local code_file = code_dir .. "/a.lua"
  vim.fn.writefile({ "", "   local   x   = 1  ", "local y = 2", "" }, code_file)
  vim.cmd("edit " .. vim.fn.fnameescape(code_file))
  local code_buf = vim.api.nvim_get_current_buf()
  local src = assert(cmd.range_source({ range = { range = 2, line1 = 1, line2 = 3 } }, code_buf))
  eq(src.text, "local x = 1", "the first non-blank selected line, whitespace squeezed")
  ok(src.ref and src.ref:find("a.lua:1$") ~= nil, "the ref is file:first-line")
  vim.fn.writefile({ string.rep("w", 200) }, code_file)
  vim.cmd("edit!")
  local long = assert(cmd.range_source({ range = { range = 1, line1 = 1, line2 = 99 } }, code_buf))
  eq(
    vim.fn.strchars(long.text),
    80,
    "the title candidate is cut; a line2 beyond the end is clamped"
  )
  vim.cmd("enew")
  local scratch = vim.api.nvim_get_current_buf()
  vim.bo[scratch].buftype = "nofile"
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "just text" })
  local plain = assert(cmd.range_source({ range = { range = 1, line1 = 1, line2 = 1 } }, scratch))
  eq(plain.ref, nil, "a scratch buffer names no file to point at")
  eq(plain.text, "just text")

  vault.set_root(root)
  vim.cmd("edit " .. vim.fn.fnameescape(code_file))
  vim.fn.writefile({ "alpha beta" }, code_file)
  vim.cmd("edit!")
  cmd.task_new({
    args = { area = "lib.nvim" },
    kv = {},
    flags = {},
    rest = {},
    range = { range = 1, line1 = 1, line2 = 1 },
  })
  local made =
    assert(scan.find("lib.nvim/alpha-beta", { root = root }), "the selected line became the title")
  eq(made.title, "alpha beta")
  ok(made.refs[1] and made.refs[1]:find("a.lua:1$") ~= nil, "and the task refers to the lines")
  vim.cmd("enew")
  vault.set_root(nil)
end
