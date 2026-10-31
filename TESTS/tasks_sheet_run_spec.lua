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
  local argv = sr.argv(
    "ui.nvim/x",
    "/t/scripts/testing.lua",
    { vault = vault, dry_run = true, tasks_cli = "/own/tasks.lua" }
  )
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
    "--tasks-cli",
    "/own/tasks.lua",
    "--dry-run",
  }, "testing sheets run --task <id> --tasks <vault> --tasks-cli <this engine>")
  eq(argv[1], vim.v.progpath, "with this editor's binary")
  local green = sr.result(0, "sheet a: pass\ntesting sheets: task x/y changed\n", "")
  eq({ green.code, green.summary }, { 0, "green" })
  eq(green.lines, { "sheet a: pass", "testing sheets: task x/y changed" }, "the lines it printed")
  local red = sr.result(
    1,
    "sheet a: fail: 80x24 step 1, keys x: E492\ntesting sheets: task x/y changed\n",
    ""
  )
  eq(red.summary, "red: sheet a: fail: 80x24 step 1, keys x: E492", "red names why")
  local refused =
    sr.result(2, "", "testing sheets: refused on the workstation (NVIM_MACHINE_ROLE=workstation)\n")
  has(refused.summary, "refused: testing sheets: refused on the workstation", "a refusal names why")
  -- review of d335128: every way of ending says its reason
  local unwritten = sr.result(
    1,
    "sheet a: pass\ntesting sheets: task x/y missing: not an open task of the vault\n",
    ""
  )
  eq(
    unwritten.summary,
    "the task was not written: testing sheets: task x/y missing: not an open task of the vault",
    "green sheets, but the task was not written: not called red"
  )
  local conflict =
    sr.result(1, "sheet a: pass\ntesting sheets: task x/y conflict: edited meanwhile\n", "")
  has(conflict.summary, "task x/y conflict", "a conflict names the task")
  local crashed = sr.result(3, "", "testing: lib.nvim not found\nstack traceback:\n  [C]: in ?\n")
  eq(
    crashed.summary,
    "testing.nvim failed (exit 3): testing: lib.nvim not found",
    "an error of the entry"
  )
  local stopped = sr.result(1, "sheet a: pass\n", "", 9)
  eq(stopped.code, 3, "a stopped process gives no verdict")
  has(stopped.summary, "was stopped (signal 9", "it says so")
  eq(
    sr.own_cli(),
    vim.fs.normalize(vim.fn.getcwd() .. "/scripts/tasks.lua"),
    "this plugin's own engine"
  )
  has(
    table.concat(sr.argv("a/b", "/t/testing.lua", { vault = vault }), " "),
    "--tasks-cli " .. sr.own_cli(),
    "handed on by default"
  )

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
  eq(seen.opts.timeout, sr.TIMEOUT_MS, "with a time limit")
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
  local area_only = run({ "sheet-run", "lib.nvim", "--testing-cli=" .. stand_in })
  eq(area_only.code, 2, "an area without a slug is bad usage")
  has(area_only.err, "usage: sheet-run", "said as usage, not as testing.nvim's refusal")

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

  -- review of d335128: an id that is none, the path compared as the file system does, a folder task's other files
  local function quiet(fn)
    told = {}
    vim.notify = function(msg, level)
      told[#told + 1] = { msg = msg, level = level }
    end
    local okq, e = pcall(fn)
    -- the result of a run that started comes back scheduled
    vim.wait(300, function()
      return #told >= 2
    end)
    vim.notify = orig_notify
    assert(okq, e)
  end
  seen = nil
  quiet(function()
    cmd.task_sheet_run({ args = { id = "lib.nvim" }, flags = {}, rest = {} }, fake(0, ""))
  end)
  has(told[1] and told[1].msg, "is no task id", "an area alone is refused")
  ok(seen == nil, "and nothing started")
  if require("lib.nvim.cross.platform.is_windows")() then
    seen = nil
    quiet(function()
      -- the vault named in another case than the file system spells it (the buffer gets its real case)
      vault_mod.set_root(root:upper())
      vim.cmd.edit(vim.fn.fnameescape(root .. "/lib.nvim/ROADMAP/tasks/live.md"))
      cmd.task_sheet_run({ args = {}, flags = {}, rest = {} }, fake(0, ""))
    end)
    vault_mod.set_root(root)
    eq(seen and seen.argv[10], "lib.nvim/live", "another case of the same path (Windows)")
    vim.cmd("enew!")
  end
  assert(require("tasks_nvim.mutate").folderize("lib.nvim/live", { root = root, index = false }))
  H.write(root .. "/lib.nvim/ROADMAP/tasks/live/notes.md", "notes")
  seen = nil
  quiet(function()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/lib.nvim/ROADMAP/tasks/live/notes.md"))
    cmd.task_sheet_run({ args = {}, flags = {}, rest = {} }, fake(0, ""))
  end)
  eq(seen and seen.argv[10], "lib.nvim/live", "a file in a folder task's folder")
  vim.cmd("enew!")

  -- ── sheet-ai: stage 0 of the AI link (hand-over, accept, bug) ──────────────
  eq(
    vim.list_slice(
      sr.ai_argv("draft", "a/b", "/t/testing.lua", { vault = vault, tasks_cli = "/own" }),
      7
    ),
    { "sheets", "prompt", "draft", "--from-task", "a/b", "--vault", vault, "--tasks-cli", "/own" },
    "draft: testing sheets prompt draft"
  )
  eq(
    vim.list_slice(
      sr.ai_argv("explain", "a/b", "/t/testing.lua", { vault = vault, tasks_cli = "/own" }),
      7
    ),
    { "sheets", "prompt", "explain", "--task", "a/b", "--tasks", vault, "--tasks-cli", "/own" },
    "explain: testing sheets prompt explain"
  )
  eq(
    vim.list_slice(
      sr.ai_argv("accept", "a/b", "/t/testing.lua", { vault = vault, from = "/x.md" }),
      7
    ),
    { "sheets", "accept", "--task", "a/b", "--from", "/x.md" },
    "accept: testing sheets accept"
  )
  eq(
    sr.task_block(
      "Cause: ...\n\n```task\ntitle: Float loses focus\nsummary: After :UI the float\nloses focus.\n```\n"
    ),
    { title = "Float loses focus", summary = "After :UI the float loses focus." },
    "the proposed bug task"
  )
  ok(sr.task_block("no block") == nil, "no block")
  ok(sr.task_block("```task\nsummary: s\n```") == nil, "a block without a title")

  -- the CLI verb, with a stand-in testing.lua that prints a document
  local doc_stand_in = H.tmpdir() .. "/scripts/testing.lua"
  H.write(
    doc_stand_in,
    "io.stdout:write('# Hand-over for ' .. table.concat(arg, ' ') .. '\\n')\nos.exit(0)"
  )
  local d = run({ "sheet-ai", "draft", "lib.nvim/live", "--testing-cli=" .. doc_stand_in })
  eq(d.code, 0, d.err)
  has(
    d.out,
    "# Hand-over for sheets prompt draft --from-task lib.nvim/live",
    "draft prints the document"
  )
  local answer_file = H.tmpdir() .. "/answer.md"
  H.write(
    answer_file,
    "It is a bug.\n\n```task\ntitle: Slots bar flickers\nsummary: The bar redraws twice.\n```\n\n```lua\nreturn {}\n```\n"
  )
  local dry_bug = run({ "sheet-ai", "bug", "lib.nvim/live", "--from=" .. answer_file })
  eq(dry_bug.code, 0, dry_bug.err)
  has(dry_bug.out, "would create\tlib.nvim\tbug\tSlots bar flickers", "without --yes: shown only")
  ok(
    vim.fn.filereadable(root .. "/lib.nvim/ROADMAP/tasks/slots-bar-flickers.md") == 0,
    "and nothing created"
  )
  local made = run({ "sheet-ai", "bug", "lib.nvim/live", "--from=" .. answer_file, "--yes" })
  eq(made.code, 0, made.err)
  has(made.out, "created\tlib.nvim/slots-bar-flickers", "with --yes: created")
  local bug_text = H.read(root .. "/lib.nvim/ROADMAP/tasks/slots-bar-flickers.md")
  has(bug_text, "kind: bug", "as a bug")
  has(bug_text, "Live-Check-Task `lib.nvim/live`", "naming the live check it came from")
  local dry_accept = run({
    "sheet-ai",
    "accept",
    "lib.nvim/live",
    "--from=" .. answer_file,
    "--testing-cli=" .. doc_stand_in,
  })
  has(dry_accept.out, "would write the sheet:\nreturn {}", "accept without --yes: the sheet shown")
  ok(not dry_accept.out:find("# Hand-over", 1, true), "testing.nvim not started")
  local yes_accept = run({
    "sheet-ai",
    "accept",
    "lib.nvim/live",
    "--from=" .. answer_file,
    "--testing-cli=" .. doc_stand_in,
    "--yes",
  })
  has(
    yes_accept.out,
    "sheets accept --task lib.nvim/live --from " .. answer_file,
    "with --yes: testing sheets accept"
  )
  eq(run({ "sheet-ai", "bug", "lib.nvim/live" }).code, 2, "bug needs --from")
  eq(run({ "sheet-ai", "colour", "lib.nvim/live" }).code, 2, "an unknown step")
  eq(run({ "sheet-ai", "draft", "lib.nvim" }).code, 2, "an id without a slug")

  -- the editor: the hand-over buffer, then accept and bug from it, each after the dialog
  local asked = {}
  local function answer_dialog(yes)
    return function(msg, _, cb)
      asked[#asked + 1] = msg
      cb(yes)
    end
  end
  quiet(function()
    cmd.task_sheet_ai(
      { args = { step = "draft", id = "lib.nvim/live" }, flags = {}, rest = {} },
      fake(0, "# Draft a test sheet\n\n```lua\nreturn { id = 'skeleton' }\n```\n")
    )
  end)
  eq(
    vim.api.nvim_buf_get_name(0),
    "tasks://sheet-ai/draft/lib.nvim/live",
    "a hand-over buffer of its own"
  )
  local hand = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  has(hand, "# Draft a test sheet", "with the document")
  has(
    hand,
    "Paste the AI's answer below this line, then :Tasks sheet-ai accept",
    "and what to do next"
  )
  has(vim.fn.getreg('"'), "# Draft a test sheet", "and the document in a register")
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "```lua", "return { id = 'x' }", "```" })
  seen = nil
  quiet(function()
    cmd.task_sheet_ai(
      { args = { step = "accept" }, flags = {}, rest = {} },
      fake(0, "testing sheets: wrote x\n"),
      answer_dialog(false)
    )
  end)
  has(
    asked[1],
    "Write this sheet for lib.nvim/live?",
    "asked first, with the task of the hand-over"
  )
  has(asked[1], "return { id = 'x' }", "showing the sheet")
  ok(
    not asked[1]:find("skeleton", 1, true),
    "the answer below the marker, not the hand-over's own block"
  )
  ok(seen == nil, "no: testing.nvim not started")
  quiet(function()
    cmd.task_sheet_ai(
      { args = { step = "accept" }, flags = {}, rest = {} },
      fake(0, "testing sheets: wrote x\n"),
      answer_dialog(true)
    )
  end)
  eq(
    seen and vim.list_slice(seen.argv, 7, 10),
    { "sheets", "accept", "--task", "lib.nvim/live" },
    "yes: accept"
  )
  has(told[#told] and told[#told].msg, "testing sheets: wrote x", "and its result")
  vim.api.nvim_buf_set_lines(
    0,
    -1,
    -1,
    false,
    { "```task", "title: Float keys swallowed", "summary: s", "```" }
  )
  asked = {}
  quiet(function()
    cmd.task_sheet_ai({ args = { step = "bug" }, flags = {}, rest = {} }, nil, answer_dialog(false))
  end)
  ok(
    vim.fn.filereadable(root .. "/lib.nvim/ROADMAP/tasks/float-keys-swallowed.md") == 0,
    "no: no bug task"
  )
  asked = {}
  quiet(function()
    cmd.task_sheet_ai({ args = { step = "bug" }, flags = {}, rest = {} }, nil, answer_dialog(true))
  end)
  has(asked[1], 'Create the bug task "Float keys swallowed" in lib.nvim?', "the bug asked first")
  ok(
    vim.fn.filereadable(root .. "/lib.nvim/ROADMAP/tasks/float-keys-swallowed.md") == 1,
    "then created"
  )
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "no answer here" })
  quiet(function()
    cmd.task_sheet_ai(
      { args = { step = "bug", id = "lib.nvim/live" }, flags = {}, rest = {} },
      nil,
      answer_dialog(true)
    )
  end)
  has(told[1] and told[1].msg, "no ```task block", "a buffer without a proposal")
  vim.cmd("enew!")
  require("tasks_nvim.config").merge({})
end
