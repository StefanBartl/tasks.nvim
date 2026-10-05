-- TESTS/tasks/tasks_boundary_safety_spec.lua -- hardening of what comes in and goes out: the CLI never
-- falls back to the default vault on an empty `--vault=`, never prints terminal control characters from
-- task files, the CI gate reports a killed or hung md_lint, the scripts find their own folder from
-- anywhere, and the editor's `task attach` takes a typed file name literally before it expands it.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local ci = require("tasks_nvim.ci")
  local cli = require("tasks_nvim.cli")
  local index = require("tasks_nvim.index")

  local TODAY = F.TODAY

  ---@param argv string[]
  ---@return integer code
  ---@return string out
  ---@return string err
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return code, table.concat(out), table.concat(err)
  end

  -- ── CLI: input ──────────────────────────────────────────────────────────
  local root = F.vault(H)
  local saved_vault = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = root -- what an empty --vault= would silently fall back to
  local okc, cerr = pcall(function()
    local code, _, err = run({ "new", "lib.nvim", "Stray", "--vault=", "--today=" .. TODAY })
    eq(code, 2, "an empty --vault= is a usage error, not the default vault")
    has(err, "--vault")
    ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/stray.md"), "nothing was written")
    local code2, _, err2 = run({ "list", "--today=", "--vault=" .. root })
    eq(code2, 2)
    has(err2, "--today")
    eq((run({ "--vault=", "areas" })), 2, "also in front of the command")
  end)
  vim.env.TASKS_VAULT = saved_vault
  if not okc then
    error(cerr, 0)
  end

  -- ── CLI: output ─────────────────────────────────────────────────────────
  root = F.vault(H)
  local esc = "\27"
  local c1 = "\194\155" -- U+009B, the 8-bit CSI
  F.task(
    H,
    root,
    "lib.nvim",
    "evil",
    F.meta("x" .. esc .. "[2Jy" .. esc .. "]0;pwned\7 z" .. c1 .. "31m", "open")
  )
  F.task(H, root, "lib.nvim", "plain", F.meta("Plain title with ä and 日本語", "open"))
  local base = { "--vault=" .. root, "--today=" .. TODAY }
  ---@param ... string
  ---@return integer code
  ---@return string out
  ---@return string err
  local function cmd(...)
    local argv = { ... }
    vim.list_extend(argv, base)
    return run(argv)
  end
  for _, argv in ipairs({
    { "list" },
    { "list", "--format=ids" },
    { "check" },
    { "export" },
    { "index", "--check" },
  }) do
    local _, out, err = cmd(unpack(argv))
    local all = out .. err
    lacks(all, esc, table.concat(argv, " ") .. ": no ESC reaches the terminal")
    lacks(all, "\7", "no BEL")
    lacks(all, c1, "no 8-bit CSI")
  end
  local _, out = cmd("list")
  has(out, "[2Jy", "the readable part of the title is kept")
  has(out, "Plain title with ä and 日本語", "plain UTF-8 passes through untouched")
  has(out, "\t", "tab separators stay")

  -- ── CI: a killed or hung md_lint fails the gate and says why ────────────
  local code, text, fatal = ci.interpret({ code = 0, signal = 9, stdout = "", stderr = "" }, 1500)
  eq(code, 1, "a child killed by a signal is not a pass")
  has(text, "signal 9")
  ok(fatal, "and the remaining chunks are not tried")
  code, text, fatal = ci.interpret({ code = 124, signal = 9, stdout = "", stderr = "" }, 1500)
  eq(code, 1)
  has(text, "timed out")
  ok(fatal)
  code, text, fatal = ci.interpret({ code = 0, signal = 0, stdout = "OK a\n", stderr = "" }, 1500)
  eq(code, 0)
  eq(text, "OK a\n")
  ok(not fatal)
  code, text, fatal = ci.interpret({ code = 3, signal = 0, stdout = "a", stderr = "b" }, 1500)
  eq(code, 3)
  eq(text, "ab")
  ok(not fatal, "an ordinary lint failure goes on with the next chunk")

  root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "alpha",
    F.meta("alpha", "open", { { "created", "2026-09-01" }, { "updated", "2026-09-02" } })
  )
  assert(index.write_all({ root = root }))
  H.write(root .. "/TOOLS/scripts/md_lint.lua", "vim.wait(60000)\nos.exit(0)\n")
  local t0 = vim.uv.hrtime()
  local res = ci.run({ root = root, timeout_ms = 1500, trust_vault_lint = true })
  local elapsed = (vim.uv.hrtime() - t0) / 1e9
  ok(
    elapsed < 30,
    ("the hung md_lint was stopped after the timeout, not 120 s (%.1f s)"):format(elapsed)
  )
  eq(res.code, 1)
  eq(res.failed, { "md_lint" })
  has(table.concat(res.lines, "\n"), "timed out")

  -- a fatal run stops the chunk loop: 45 indexes are two chunks, the hung linter is tried once
  local calls = 0
  local many = F.vault(H)
  for i = 1, 45 do
    local area = ("area%02d.nvim"):format(i)
    vim.fn.mkdir(many .. "/" .. area .. "/ROADMAP", "p")
    F.task(H, many, area, "t", F.meta("t", "open", { { "created", "2026-09-01" } }))
  end
  assert(index.write_all({ root = many }))
  H.write(many .. "/TOOLS/scripts/md_lint.lua", "os.exit(0)\n")
  res = ci.run({
    root = many,
    run_lint = function()
      calls = calls + 1
      return 1, "timed out after 120 s and was killed", true
    end,
  })
  eq(calls, 1, "the second chunk is not tried after a fatal run")
  eq(res.failed, { "md_lint" })
  has(table.concat(res.lines, "\n"), "of 45 file(s) linted")

  -- ── scripts/tasks.lua started from inside scripts/ ──────────────────────
  local lib = vim.env.LIB_NVIM_DIR
  if lib and lib ~= "" then
    local scripts_dir = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
      .. "/scripts"
    scripts_dir = vim.fn.fnamemodify(scripts_dir, ":p")
    -- an empty config dir: the only `tasks` module in reach is the one next to the script
    local empty_cfg = H.tmpdir()
    local r = vim
      .system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        "tasks.lua",
        "areas",
        "--vault=" .. root,
      }, {
        text = true,
        cwd = scripts_dir,
        env = {
          XDG_CONFIG_HOME = empty_cfg,
          LIB_NVIM_DIR = lib,
          NVIM = vim.NIL,
          NVIM_LISTEN_ADDRESS = vim.NIL,
        },
      })
      :wait(60000)
    eq(r.code, 0, "started from scripts/: " .. tostring(r.stderr))
    has(r.stdout, "lib.nvim")
  end
end
