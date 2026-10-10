-- TESTS/tasks/tasks_cli_spec.lua -- tasks.cli (in-process) and scripts/tasks.lua (a real child Neovim).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")

  local root = F.vault(H)
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }

  --- Run one command line in-process.
  ---@param argv string[]
  ---@param with_common? boolean  append --vault/--today (default true)
  ---@return { code: integer, out: string, err: string }
  local function run(argv, with_common)
    local out, err = {}, {}
    local args = vim.deepcopy(argv)
    if with_common ~= false then
      vim.list_extend(args, common)
    end
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  --- Lines of a text without the trailing empty one.
  local function lines(text)
    return vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  end

  -- ── usage ───────────────────────────────────────────────────────────────
  local r = run({}, false)
  eq(r.code, 2, "no command is a usage error")
  has(r.out, "usage:")
  r = run({ "help" }, false)
  eq(r.code, 0)
  has(r.out, "commands:")
  r = run({ "list", "--help" }, false)
  eq(r.code, 0)
  has(r.out, "usage:")
  r = run({ "frobnicate" }, false)
  has(r.err, "unknown command")
  r = run({ "frobnicate" }, false)
  eq(r.code, 2)
  r = run({ "list", "--nope" })
  eq(r.code, 2)
  has(r.err, "unknown option")
  r = run({ "list", "--status" })
  eq(r.code, 2)
  has(r.err, "needs a value")
  r = run({ "list", "--status=wip" })
  eq(r.code, 2)
  has(r.err, "unknown status")
  r = run({ "list", "--prio=9" })
  eq(r.code, 2)
  r = run({ "list", "--stale=abc" })
  eq(r.code, 2)
  r = run({ "list", "--format=csv" })
  eq(r.code, 2, "an unknown format")
  r = run({ "list", "a", "b" })
  eq(r.code, 2)
  r = run({ "list", "--vault=" .. root .. "/missing" }, false)
  eq(r.code, 1, "a missing vault is an operational error")
  has(r.err, "not a directory")

  -- ── new ─────────────────────────────────────────────────────────────────
  r = run({
    "new",
    "lib.nvim",
    "Notify: unify channels",
    "--kind=feature",
    "--prio=2",
    "--effort=M",
    "--tags=ui,release",
    "--summary=One channel for all.",
  })
  eq(r.code, 0)
  local out_lines = lines(r.out)
  eq(
    out_lines[1],
    "created\tlib.nvim/notify-unify-channels\t"
      .. root
      .. "/lib.nvim/ROADMAP/tasks/notify-unify-channels.md"
  )
  eq(out_lines[2], "index\twritten\t" .. root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/notify-unify-channels.md"))

  r = run({ "new", "lib.nvim", "Second one", "--prio=1" })
  eq(r.code, 0)
  r = run({ "new", "cascade.nvim", "Blocked thing", "--status=blocked", "--kind=bug" })
  eq(r.code, 0)
  r = run({ "new", "ALL", "--title=Via option", "--no-index" })
  eq(r.code, 0)
  eq(
    lines(r.out),
    { "created\tALL/via-option\t" .. root .. "/ALL/ROADMAP/tasks/via-option.md" },
    "--no-index: no index line"
  )
  ok(not H.exists(root .. "/ALL/ROADMAP/TASKS.md"))

  r = run({ "new", "lib.nvim" })
  eq(r.code, 2, "title missing")
  r = run({ "new", "nope.nvim", "T" })
  eq(r.code, 1)
  has(r.err, "unknown area")
  r = run({ "new", "lib.nvim", "T", "--kind=epic" })
  eq(r.code, 1)
  has(r.err, "unknown kind")

  -- ── list ────────────────────────────────────────────────────────────────
  r = run({ "list" })
  eq(r.code, 0)
  eq(lines(r.out), {
    "cascade.nvim/blocked-thing\tblocked\t-\t-\tbug\t2026-10-03\tBlocked thing",
    "lib.nvim/second-one\topen\t1\t-\ttask\t2026-10-03\tSecond one",
    "lib.nvim/notify-unify-channels\topen\t2\tM\tfeature\t2026-10-03\tNotify: unify channels",
    "ALL/via-option\topen\t-\t-\ttask\t2026-10-03\tVia option",
  }, "sorted: status, prio, area, slug; one tab-separated line each")

  r = run({ "list", "lib.nvim", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/second-one", "lib.nvim/notify-unify-channels" })
  r = run({ "list", "nope.nvim" })
  eq(r.code, 1, "an unknown area is an error, not an empty list")
  has(r.err, "unknown area")
  r = run({ "list", "--status=blocked,decision", "--format=ids" })
  eq(lines(r.out), { "cascade.nvim/blocked-thing" })
  r = run({ "list", "--prio=<=1", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/second-one" })
  r = run({ "list", "--prio=1,2", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/second-one", "lib.nvim/notify-unify-channels" })
  r = run({ "list", "--kind=bug", "--format=ids" })
  eq(lines(r.out), { "cascade.nvim/blocked-thing" })
  r = run({ "list", "--tag=release", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/notify-unify-channels" })
  r = run({ "list", "--blocked", "--format=ids" })
  eq(lines(r.out), { "cascade.nvim/blocked-thing" })
  r = run({ "list", "--stale=1", "--format=ids" })
  eq(r.out, "", "nothing is a day old: all created today")
  eq(r.code, 0, "an empty result is still success")
  r = run({ "list", "--stale=0", "--format=ids" })
  eq(#lines(r.out), 4)

  -- a broken task is not listed, but not hidden either
  H.write(root .. "/lib.nvim/ROADMAP/tasks/broken.md", "no frontmatter\n")
  r = run({ "list", "lib.nvim", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/second-one", "lib.nvim/notify-unify-channels" })
  has(r.err, "1 task file(s) not listed")
  has(r.err, "check")
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/broken.md")

  -- ── set ─────────────────────────────────────────────────────────────────
  r = run({ "set", "lib.nvim/second-one", "status=doing", "prio=3", "tags=a,b" })
  eq(r.code, 0)
  eq(
    lines(r.out)[1],
    "set\tlib.nvim/second-one\tchanged\t" .. root .. "/lib.nvim/ROADMAP/tasks/second-one.md"
  )
  eq(lines(r.out)[2], "index\twritten\t" .. root .. "/lib.nvim/ROADMAP/TASKS.md")
  r = run({ "set", "lib.nvim/second-one", "status=doing" })
  eq(r.code, 0)
  eq(
    lines(r.out),
    { "set\tlib.nvim/second-one\tunchanged\t" .. root .. "/lib.nvim/ROADMAP/tasks/second-one.md" }
  )
  r = run({ "set", "lib.nvim/second-one", "prio=" })
  eq(r.code, 0)
  ok(
    not H.read(root .. "/lib.nvim/ROADMAP/tasks/second-one.md"):find("prio:", 1, true),
    "an empty value removes the key"
  )
  r = run({ "set", "lib.nvim/second-one", "status=done" })
  eq(r.code, 1)
  has(r.err, "finishing the task")
  r = run({ "set", "lib.nvim/second-one" })
  eq(r.code, 2)
  r = run({ "set", "lib.nvim/second-one", "no-equals" })
  eq(r.code, 2)
  r = run({ "set", "lib.nvim/ghost", "status=open" })
  eq(r.code, 1)
  has(r.err, "no such open task")

  -- ── index ───────────────────────────────────────────────────────────────
  H.write(
    root .. "/lib.nvim/ROADMAP/TASKS.md",
    "<!-- GENERATED by tasks.nvim (:Tasks index) -- stand-in -->\nstale\n"
  )
  r = run({ "index", "--check" })
  eq(r.code, 1, "--check fails on a stale index")
  has(r.out, "stale\tlib.nvim")
  has(r.out, "outdated")
  has(r.out, "index --check:")
  eq(
    H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
    "<!-- GENERATED by tasks.nvim (:Tasks index) -- stand-in -->\nstale\n",
    "--check wrote nothing"
  )
  r = run({ "index", "lib.nvim" })
  eq(r.code, 0)
  has(r.out, "written\tlib.nvim")
  r = run({ "index" })
  eq(r.code, 0)
  has(r.out, "written\tALL\t1 open")
  r = run({ "index", "--check" })
  eq(r.code, 0, "fresh after index")
  has(r.out, "0 stale")
  r = run({ "index" })
  eq(#lines(r.out), 1, "a second run only prints the summary: " .. r.out)
  has(r.out, "0 written")
  r = run({ "index", "nope.nvim" })
  eq(r.code, 1)
  has(r.err, "nope.nvim")

  -- ── check ───────────────────────────────────────────────────────────────
  r = run({ "check" })
  eq(r.code, 0, "no error: " .. r.out)
  -- the fixture's `blocked-thing` has status blocked and no blocker: a warning, never an error
  has(r.out, "warn blocked-without-blocker")
  has(r.out, "check: 1 finding(s) (0 error, 1 warning) in 5 area(s), 4 task file(s) read")
  F.task(H, root, "lib.nvim", "bad", F.meta("Bad", "wip"))
  r = run({ "check" })
  eq(r.code, 1)
  has(r.out, "lib.nvim/ROADMAP/tasks/bad.md  unknown-status")
  r = run({ "check", "cascade.nvim" })
  eq(r.code, 0, "findings elsewhere do not fail a single-area check")
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/bad.md")
  r = run({ "check", "nope.nvim" })
  eq(r.code, 1)
  has(r.err, "unknown area")

  -- ── done ────────────────────────────────────────────────────────────────
  r = run({ "done", "lib.nvim/notify-unify-channels", "--done-in=lib.nvim@abc1234" })
  eq(r.code, 0)
  eq(
    lines(r.out)[1],
    "done\tlib.nvim/notify-unify-channels\t"
      .. root
      .. "/lib.nvim/Backlog/FEATURES/2026-10-03_notify-unify-channels.md"
  )
  has(r.out, "index\twritten")
  has(H.read(root .. "/lib.nvim/Backlog/README.md"), "## FEATURES (1)")
  r = run({ "done", "lib.nvim/notify-unify-channels" })
  eq(r.code, 0)
  has(r.out, "already\tlib.nvim/notify-unify-channels")
  r = run({ "done", "cascade.nvim/blocked-thing", "--date=2026-10-01" })
  eq(r.code, 0)
  ok(H.exists(root .. "/cascade.nvim/Backlog/TASKS/2026-10-01_blocked-thing.md"))
  r = run({ "done", "lib.nvim/ghost" })
  eq(r.code, 1)
  has(r.err, "no such open task")
  r = run({ "done" })
  eq(r.code, 2)
  r = run({ "done", "lib.nvim/second-one", "--date=soon" })
  eq(r.code, 1)
  has(r.err, "YYYY-MM-DD")
  vim.fn.delete(root .. "/ALL/Backlog/README.md")
  r = run({ "done", "ALL/via-option" })
  eq(r.code, 0)
  has(r.err, "Backlog/README.md does not exist")

  -- ── template / areas / export ───────────────────────────────────────────
  r = run({ "template", "--title=Hello", "--kind=bug", "--prio=1", "--tags=a,b" })
  eq(r.code, 0)
  has(r.out, "title: Hello\nstatus: open\nkind: bug\nprio: 1\n")
  has(r.out, "tags: [a, b]")
  has(r.out, "created: 2026-10-03")
  r = run({ "template", "--lang=en" })
  eq(r.code, 0)
  has(r.out, "## Acceptance")
  eq(run({ "template", "--lang=fr" }).code, 2)

  eq(run({ "template", "--prio=7" }).code, 2)
  eq(run({ "template", "extra" }).code, 2)

  -- global options may also come before the command
  local lead_out = {}
  local lead_code = cli.run({ "--vault=" .. root, "--today=" .. F.TODAY, "areas" }, {
    out = function(t)
      lead_out[#lead_out + 1] = t
    end,
    err = function() end,
  })
  eq(lead_code, 0)
  eq(
    vim.split(table.concat(lead_out), "\n", { plain = true, trimempty = true }),
    { "ALL", "cascade.nvim", "lib.nvim", "migrate.nvim", "nvim-config" },
    "leading --vault"
  )

  r = run({ "areas" })
  eq(lines(r.out), { "ALL", "cascade.nvim", "lib.nvim", "migrate.nvim", "nvim-config" })

  r = run({ "export" })
  eq(r.code, 0)
  has(r.out, "# Offene Tasks — alle Bereiche (1 in 1 Bereichen)")
  has(r.out, "[lib.nvim](../lib.nvim/ROADMAP/TASKS.md)")
  has(
    r.out,
    "| [ALL](../ALL/ROADMAP/TASKS.md) | 0 | 0 |",
    "areas without open tasks are listed (one row per area)"
  )
  r = run({ "export", "--no-links", "--top=1" })
  lacks(r.out, "](")
  has(r.out, "## Top 1")
  r = run({ "export", "--top=x" })
  eq(r.code, 2)
  ok(not H.exists(root .. "/ALL/TASKS.md"), "export prints, never writes")

  -- ── the real script, in a child Neovim ──────────────────────────────────
  local script = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
    .. "/scripts/tasks.lua"
  ok(H.exists(script), "scripts/tasks.lua exists: " .. script)

  --- Run the script in a child Neovim.
  ---@param argv string[]
  ---@param bare? boolean  do not append --vault/--today
  ---@return { code: integer, stdout: string, stderr: string }
  local function child(argv, bare)
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }
    vim.list_extend(cmd, argv)
    if not bare then
      vim.list_extend(cmd, common)
    end
    return vim
      .system(cmd, {
        text = true,
        env = { NVIM = vim.NIL, NVIM_LISTEN_ADDRESS = vim.NIL, TASKS_EXTRA_AREAS = "migrate.nvim" },
      })
      :wait(60000)
  end

  local c1 = child({ "new", "migrate.nvim", "From a child process", "--prio=1" })
  eq(c1.code, 0, "child exit code; stderr: " .. tostring(c1.stderr))
  has(c1.stdout, "created\tmigrate.nvim/from-a-child-process\t")
  ok(
    H.exists(root .. "/migrate.nvim/ROADMAP/tasks/from-a-child-process.md"),
    "the child wrote the file"
  )
  ok(H.exists(root .. "/migrate.nvim/ROADMAP/TASKS.md"), "and the index")

  local c2 = child({ "list", "--format=ids" })
  eq(c2.code, 0)
  eq(
    (c2.stdout:gsub("\r", "")),
    "lib.nvim/second-one\nmigrate.nvim/from-a-child-process\n",
    "list from the child (windows CR stripped)"
  )

  local c3 = child({ "check" })
  eq(c3.code, 0, c3.stdout .. c3.stderr)
  has(c3.stdout, "check: 0 finding(s)")

  H.write(
    root .. "/migrate.nvim/ROADMAP/TASKS.md",
    "<!-- GENERATED by tasks.nvim (:Tasks index) -- stand-in -->\nstale\n"
  )
  local c4 = child({ "index", "--check" })
  eq(c4.code, 1, "exit code 1 when the index is stale")
  local c5 = child({ "set", "migrate.nvim/from-a-child-process", "status=wip" })
  eq(c5.code, 1)
  has(c5.stderr, "unknown status")
  local c6 = child({ "frobnicate" })
  eq(c6.code, 2, "usage error exits 2")
  local c7 = child({}, true)
  eq(c7.code, 2)
  has(c7.stdout, "usage:")

  -- new: --refs and --lang (last: it adds a task the counts above would see)
  r = run({ "new", "lib.nvim", "Refs and lang", "--refs=lua/a.lua,lib.nvim@abc1234", "--lang=en" })
  eq(r.code, 0, r.err)
  local refs_text = H.read(r.out:match("created\t[^\t]+\t([^\n]+)"))
  has(refs_text, "refs: [lua/a.lua, lib.nvim@abc1234]")
  has(refs_text, "## Context")
  eq(run({ "new", "lib.nvim", "Bad lang", "--lang=fr" }).code, 1)
end
