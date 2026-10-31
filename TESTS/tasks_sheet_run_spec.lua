-- TESTS/tasks_sheet_run_spec.lua -- `sheet-run` / `:Tasks sheet-run`: running the test sheets of a task through
-- testing.nvim's `testing sheets run` as a process. Where testing.nvim is found, the command line it gets, how its exit
-- code and output come back (green, red with the first failure line, refused), the CLI verb end to end with a stand-in
-- `scripts/testing.lua`, and the editor command (the id of the current buffer, the notification).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local sr = require("tasks_nvim.sheet_run")

  -- ── where testing.nvim is ──────────────────────────────────────────────────
  local base = H.tmpdir()
  local vault = base .. "/tasks-vault"
  vim.fn.mkdir(vault, "p")
  local function cli_at(dir)
    H.write(dir .. "/scripts/testing.lua", "-- stand-in")
    return vim.fs.normalize(dir .. "/scripts/testing.lua")
  end
  local env = {}
  local function getenv(name)
    return env[name]
  end
  local nothing = H.tmpdir()
  local _, err = sr.locate({ vault = vault, getenv = getenv, data_dir = nothing })
  has(err, "testing.nvim not found", "nothing anywhere")
  has(err, "TESTING_NVIM_DIR", "it says how to name it")
  local beside = cli_at(base .. "/testing.nvim")
  eq(sr.locate({ vault = vault, getenv = getenv, data_dir = nothing }), beside, "beside the vault")
  local repos = cli_at(H.tmpdir() .. "/testing.nvim")
  env.REPOS_DIR = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(repos)))
  eq(
    sr.locate({ vault = vault, getenv = getenv, data_dir = nothing }),
    repos,
    "REPOS_DIR before the vault"
  )
  local named = cli_at(H.tmpdir() .. "/own")
  env.TESTING_NVIM_DIR = vim.fs.dirname(vim.fs.dirname(named))
  eq(
    sr.locate({ vault = vault, getenv = getenv, data_dir = nothing }),
    named,
    "TESTING_NVIM_DIR first"
  )
  eq(sr.locate({ vault = vault, cli = beside, getenv = getenv }), beside, "an explicit path wins")
  local _, cerr = sr.locate({ vault = vault, cli = base .. "/nope.lua" })
  has(cerr, "is not readable", "an explicit path that is not there")

  -- ── the command line and the result ────────────────────────────────────────
  local argv = sr.argv("ui.nvim/x", "/t/scripts/testing.lua", { vault = vault, dry_run = true })
  eq(vim.list_slice(argv, 2), {
    "--headless",
    "-u",
    "NONE",
    "-l",
    "/t/scripts/testing.lua",
    "sheets",
    "run",
    "--task",
    "ui.nvim/x",
    "--tasks",
    vault,
    "--dry-run",
  }, "testing sheets run --task <id> --tasks <vault>")
  eq(argv[1], vim.v.progpath, "with this editor's binary")
  local green = sr.result(0, "sheet a: pass\ntesting sheets: task x/y changed\n", "")
  eq({ green.code, green.summary }, { 0, "green" })
  eq(green.lines, { "sheet a: pass", "testing sheets: task x/y changed" }, "the lines it printed")
  local red = sr.result(
    1,
    "sheet a: fail: 80x24 step 1, keys x: E492\ntesting sheets: task x/y changed\n",
    ""
  )
  eq(
    red.summary,
    "red (or the task was not written): sheet a: fail: 80x24 step 1, keys x: E492",
    "red names why"
  )
  local refused =
    sr.result(2, "", "testing sheets: refused on the workstation (NVIM_MACHINE_ROLE=workstation)\n")
  has(refused.summary, "refused: testing sheets: refused on the workstation", "a refusal names why")

  -- ── run, with a stand-in for vim.system ────────────────────────────────────
  local seen
  local function fake(code, stdout, stderr)
    return function(a, o, cb)
      seen = { argv = a, opts = o }
      local r = { code = code, stdout = stdout, stderr = stderr or "" }
      if cb then
        cb(r)
        return {}
      end
      return {
        wait = function()
          return r
        end,
      }
    end
  end
  local res = sr.run("ui.nvim/x", { vault = vault, cli = beside }, nil, fake(0, "sheet a: pass\n"))
  eq(res.code, 0, "a synchronous run")
  eq(seen.argv[6], beside, "with the testing.nvim found")
  eq(seen.opts.cwd, vault, "from the vault")
  local got
  sr.run("ui.nvim/x", { vault = vault, cli = beside }, function(r)
    got = r
  end, fake(1, "sheet a: fail: boom\n"))
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got and got.code, 1, "an asynchronous run calls back")
  local missing = sr.run("ui.nvim/x", { vault = vault, cli = base .. "/nope.lua" })
  eq(missing.code, 3, "testing.nvim not found: exit 3")
  has(missing.summary, "is not readable")
  local broken = sr.run("ui.nvim/x", { vault = vault, cli = beside }, nil, function()
    error("spawn failed")
  end)
  eq(broken.code, 3, "a spawn that raises: exit 3")
  has(broken.summary, "did not start")

  -- ── the CLI verb, end to end with a stand-in scripts/testing.lua ───────────
  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "live", F.meta("Live", "open", {}), "\nA live check.\n")
  local stand_in = H.tmpdir() .. "/scripts/testing.lua"
  H.write(
    stand_in,
    table.concat({
      "io.stdout:write('args: ' .. table.concat(arg, ' ') .. '\\n')",
      "io.stdout:write('sheet a: fail: 80x24 step 2, expect: the float is gone\\n')",
      "os.exit(1)",
    }, "\n")
  )
  local cli = require("tasks_nvim.cli")
  local function run(a)
    local out, errs = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(a), { "--vault=" .. root, "--today=" .. F.TODAY }), {
        out = function(x)
          out[#out + 1] = x
        end,
        err = function(x)
          errs[#errs + 1] = x
        end,
      })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end
  local r = run({ "sheet-run", "lib.nvim/live", "--testing-cli=" .. stand_in, "--dry-run" })
  eq(r.code, 1, "the exit code of testing sheets run")
  has(r.out, "args: sheets run --task lib.nvim/live --tasks ", "the command it got")
  has(r.out, "--dry-run", "with --dry-run")
  has(r.out, "sheet a: fail: 80x24 step 2", "its output")
  has(r.err, "sheet-run: red", "and the verdict")
  eq(run({ "sheet-run" }).code, 2, "usage: an id")
  eq(run({ "sheet-run", "noslash" }).code, 2, "usage: area/slug")
  eq(run({ "sheet-run", "a/b", "c/d" }).code, 2, "usage: one id")

  -- ── :Tasks sheet-run ───────────────────────────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local vault_mod = require("tasks_nvim.vault")
  vault_mod.set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    told[#told + 1] = { msg = msg, level = level }
  end
  require("tasks_nvim.config").merge({ sheet_run = { testing_cli = beside } })
  local ok_run = pcall(function()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/lib.nvim/ROADMAP/tasks/live.md"))
    seen = nil
    cmd.task_sheet_run({ args = {}, flags = {}, rest = {} }, fake(1, "sheet a: fail: boom\n"))
    vim.wait(1000, function()
      return #told >= 2
    end)
  end)
  vim.notify = orig_notify
  ok(ok_run, "the command ran")
  eq(seen and seen.argv[10], "lib.nvim/live", "the task of the current buffer")
  eq(seen and seen.argv[6], beside, "testing.nvim from setup()")
  has(told[1] and told[1].msg, "running its test sheets", "it says it started")
  has(told[2] and told[2].msg, "lib.nvim/live: red", "and how it ended")
  eq(told[2] and told[2].level, vim.log.levels.ERROR, "red is an error")
  vim.cmd("enew!")
  told = {}
  vim.notify = function(msg, level)
    told[#told + 1] = { msg = msg, level = level }
  end
  cmd.task_sheet_run({ args = {}, flags = {}, rest = {} }, fake(0, ""))
  vim.notify = orig_notify
  has(told[1] and told[1].msg, "name a task", "no task in an empty buffer")
  require("tasks_nvim.config").merge({})
end
