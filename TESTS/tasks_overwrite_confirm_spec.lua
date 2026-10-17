-- TESTS/tasks_overwrite_confirm_spec.lua -- every `:Tasks` route that writes a `--to=file:` target asks before it
-- replaces an existing file (UI-05: a dialog instead of "pass --force"), keeps the file on a no and skips the
-- question with `--force`. Driven through the real command grammar against a fixture vault.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces `confirm.yesno` with a test double on purpose.

return function(H)
  local eq, has = H.eq, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local routes = require("tasks_nvim.ui.routes")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local mutate = require("tasks_nvim.mutate")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  routes.register_types()
  composer.verb("TaskOW", { routes = routes.routes() })
  local o = { root = root, today = F.TODAY }

  local orig_notify, orig_yesno = vim.notify, confirm.yesno
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local function restore()
    vim.notify = orig_notify
    confirm.yesno = orig_yesno
    cmd.dashboard = nil
    vault.set_root(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  ---@param line string
  local function run(line)
    notes = {}
    vim.cmd("TaskOW " .. line)
    vim.wait(30, function()
      return false
    end)
  end

  local good, failure = pcall(function()
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Ow one", effort = "S" })))
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Ow two", value = 4 })))
    cmd.dashboard = false
    local out = H.tmpdir() .. "/ow"
    vim.fn.mkdir(out, "p")

    ---@type { name: string, line: fun(path: string): string }[]
    local cases = {
      {
        name = "tasks (list)",
        line = function(p)
          return "tasks lib.nvim --to=file:" .. p
        end,
      },
      {
        name = "task plan",
        line = function(p)
          return "task plan lib.nvim --to=file:" .. p
        end,
      },
      {
        name = "task quickwins",
        line = function(p)
          return "task quickwins lib.nvim --to=file:" .. p
        end,
      },
      {
        name = "task template",
        line = function(p)
          return "task template --to=file:" .. p
        end,
      },
      {
        name = "open --list",
        line = function(p)
          return "open lib.nvim tasks --list --to=file:" .. p
        end,
      },
    }

    for i, case in ipairs(cases) do
      local path = ("%s/case%d.md"):format(out, i)
      local asked = {}
      local answer = false
      confirm.yesno = function(msg, _, cb)
        asked[#asked + 1] = msg
        cb(answer)
      end

      H.write(path, "MINE")
      run(case.line(path))
      eq(#asked, 1, case.name .. ": an existing file is a question, not an error to retype")
      has(asked[1], "already exists", case.name)
      has(asked[1], "Overwrite it?", case.name)
      eq(H.read(path), "MINE", case.name .. ": a no keeps the file")
      has(table.concat(notes, "\n"), "cancelled", case.name .. ": a no is reported")

      answer = true
      run(case.line(path))
      eq(#asked, 2, case.name)
      local replaced = assert(H.read(path))
      H.ok(replaced ~= "MINE", case.name .. ": a yes writes the file")

      H.write(path, "MINE")
      run(case.line(path) .. " --force")
      eq(#asked, 2, case.name .. ": --force asks nothing")
      H.ok(H.read(path) ~= "MINE", case.name .. ": --force writes the file")

      local fresh = ("%s/fresh%d.md"):format(out, i)
      run(case.line(fresh))
      eq(#asked, 2, case.name .. ": a new file asks nothing")
      H.ok(H.exists(fresh), case.name .. ": a new file is written")
    end
  end)
  restore()
  if not good then
    error(failure, 0)
  end
end
