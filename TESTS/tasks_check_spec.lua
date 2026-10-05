-- TESTS/tasks/tasks_check_spec.lua -- tasks.check: every rule of concept section 9 has a finding.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")

  local root = F.vault(H)
  local opts = { root = root }

  F.task(
    H,
    root,
    "lib.nvim",
    "good",
    F.meta("Good", "open", { { "prio", "1" }, { "kind", "task" } })
  )
  F.task(H, root, "lib.nvim", "other", F.meta("Other", "doing", { { "prio", "2" } }))
  F.task(H, root, "cascade.nvim", "gamma", F.meta("Gamma", "decision"))
  assert(index.write_area("lib.nvim", opts))
  assert(index.write_area("cascade.nvim", opts))

  --- The codes (with severity prefix for warnings) of a check run, sorted.
  ---@param res table
  ---@return string[]
  local function codes(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      out[#out + 1] = (f.severity == "warn" and "warn:" or "") .. f.code
    end
    table.sort(out)
    return out
  end

  --- Run the check, assert it succeeded, return the result.
  ---@param extra? table
  local function run(extra)
    local res, err = check.run(vim.tbl_extend("force", opts, extra or {}))
    ok(res, "check.run failed: " .. tostring(err))
    return res
  end

  --- Regenerate the index of every area, so a fault that adds an open task is not
  --- also an `index-stale` finding.
  local function reindex()
    for _, a in ipairs({ "lib.nvim", "cascade.nvim", "nvim-config" }) do
      assert(index.write_area(a, opts))
    end
  end

  --- Apply `fault`, check the codes, then run `undo`. Unless `raw`, the indexes
  --- are regenerated after the fault and after the undo.
  ---@param name string
  ---@param fault fun()
  ---@param want string[]
  ---@param undo fun()
  ---@param raw? boolean
  local function expect(name, fault, want, undo, raw)
    fault()
    if not raw then
      reindex()
    end
    local res = run()
    eq(codes(res), want, name)
    undo()
    if not raw then
      reindex()
    end
  end

  -- ── a clean vault ───────────────────────────────────────────────────────
  local clean = run()
  eq(clean.findings, {}, "a clean vault has no findings")
  ok(clean.ok)
  eq(clean.errors, 0)
  eq(clean.warnings, 0)
  eq(clean.areas, 5)
  eq(clean.tasks, 3, "task files read")

  local tasks = root .. "/lib.nvim/ROADMAP/tasks/"
  local function remove(path)
    vim.fn.delete(path, "rf")
  end

  -- ── file problems ───────────────────────────────────────────────────────
  expect("no frontmatter", function()
    H.write(tasks .. "prose.md", "just text\n")
  end, { "frontmatter-missing" }, function()
    remove(tasks .. "prose.md")
  end)

  expect("unclosed frontmatter", function()
    H.write(tasks .. "open-block.md", "---\ntitle: T\nstatus: open\nbody\n")
  end, { "frontmatter-missing" }, function()
    remove(tasks .. "open-block.md")
  end)

  expect("unknown status", function()
    F.task(H, root, "lib.nvim", "bad-status", F.meta("Bad status", "wip"))
  end, { "unknown-status" }, function()
    remove(tasks .. "bad-status.md")
  end)

  expect("missing status and title", function()
    H.write(tasks .. "bare.md", "---\nprio: 1\n---\nbody\n")
  end, { "status-missing", "title-missing" }, function()
    remove(tasks .. "bare.md")
  end)

  expect("unknown kind", function()
    F.task(H, root, "lib.nvim", "bad-kind", F.meta("T", "parked", { { "kind", "epic" } }))
  end, { "unknown-kind" }, function()
    remove(tasks .. "bad-kind.md")
  end)
  expect("bad prio", function()
    F.task(H, root, "lib.nvim", "bad-prio", F.meta("T", "parked", { { "prio", "high" } }))
  end, { "bad-prio" }, function()
    remove(tasks .. "bad-prio.md")
  end)
  expect("bad effort", function()
    F.task(H, root, "lib.nvim", "bad-effort", F.meta("T", "parked", { { "effort", "big" } }))
  end, { "bad-effort" }, function()
    remove(tasks .. "bad-effort.md")
  end)
  expect("bad date", function()
    F.task(H, root, "lib.nvim", "bad-date", F.meta("T", "parked", { { "created", "2026-02-30" } }))
  end, { "bad-date" }, function()
    remove(tasks .. "bad-date.md")
  end)

  expect("unsupported frontmatter value", function()
    F.task(H, root, "lib.nvim", "nested", F.meta("T", "parked", { { "extra", "{a: 1}" } }))
  end, { "frontmatter-invalid" }, function()
    remove(tasks .. "nested.md")
  end)

  expect("a frontmatter line that is not key: value is only a warning", function()
    H.write(
      tasks .. "odd-line.md",
      "---\ntitle: T\nstatus: parked\nthis line has no colon\n---\nbody\n"
    )
  end, { "warn:frontmatter-warning" }, function()
    remove(tasks .. "odd-line.md")
  end)

  expect("a hand-written title with ' #' is reported as a warning", function()
    H.write(tasks .. "hash-title.md", "---\ntitle: Fix bug #12 now\nstatus: parked\n---\nbody\n")
  end, { "warn:title-comment" }, function()
    remove(tasks .. "hash-title.md")
  end)

  -- ── filename / slug ─────────────────────────────────────────────────────
  expect("bad slug in the filename", function()
    H.write(tasks .. "Bad_Slug.md", F.text(F.meta("T", "parked")))
  end, { "slug" }, function()
    remove(tasks .. "Bad_Slug.md")
  end)
  expect("nested task file", function()
    H.write(tasks .. "sub/deep.md", F.text(F.meta("T", "parked")))
  end, { "slug" }, function()
    remove(tasks .. "sub")
  end)

  -- ── status vs place ─────────────────────────────────────────────────────
  expect("done in ROADMAP/tasks", function()
    F.task(H, root, "lib.nvim", "already-done", F.meta("Done", "done"))
  end, { "done-in-roadmap" }, function()
    remove(tasks .. "already-done.md")
  end)

  local backlog = root .. "/lib.nvim/Backlog/TASKS/"
  expect("open task in Backlog", function()
    H.write(backlog .. "2026-01-01_misfiled.md", F.text(F.meta("Misfiled", "open")))
  end, { "open-in-backlog" }, function()
    remove(backlog .. "2026-01-01_misfiled.md")
  end)
  expect("a done task and free-form documents in Backlog are fine", function()
    H.write(backlog .. "2026-01-01_fine.md", F.text(F.meta("Fine", "done")))
    H.write(backlog .. "old-audit.md", "# prose, no frontmatter\n")
    H.write(backlog .. "jekyll.md", "---\nlayout: post\n---\n")
  end, {}, function()
    remove(backlog .. "2026-01-01_fine.md")
    remove(backlog .. "old-audit.md")
    remove(backlog .. "jekyll.md")
  end)

  expect("the same id open and finished", function()
    F.task(H, root, "lib.nvim", "twin", F.meta("Twin", "parked"))
    H.write(backlog .. "2026-01-01_twin.md", F.text(F.meta("Twin", "done")))
  end, { "duplicate-id" }, function()
    remove(tasks .. "twin.md")
    remove(backlog .. "2026-01-01_twin.md")
  end)

  -- ── blocked_by ──────────────────────────────────────────────────────────
  expect("blocked_by a task that does not exist", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "dangling",
      F.meta("T", "blocked", { { "blocked_by", "lib.nvim/not-there" } })
    )
  end, { "blocked-by-dangling" }, function()
    remove(tasks .. "dangling.md")
  end)
  expect("blocked_by an unknown area", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "dangling",
      F.meta("T", "blocked", { { "blocked_by", "nope.nvim/x" } })
    )
  end, { "blocked-by-dangling" }, function()
    remove(tasks .. "dangling.md")
  end)
  expect("blocked_by itself", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "selfish",
      F.meta("T", "blocked", { { "blocked_by", "lib.nvim/selfish" } })
    )
  end, { "blocked-by-self" }, function()
    remove(tasks .. "selfish.md")
  end)
  expect("a malformed blocker", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "malformed",
      F.meta("T", "blocked", { { "blocked_by", "no-slash" } })
    )
  end, { "bad-blocked-by" }, function()
    remove(tasks .. "malformed.md")
  end)
  expect("blocked_by an open task, in this or another area, is fine", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "waits",
      F.meta("T", "blocked", { { "blocked_by", "[lib.nvim/good, cascade.nvim/gamma]" } })
    )
  end, {}, function()
    remove(tasks .. "waits.md")
  end)
  expect("blocked_by a finished task warns", function()
    F.task(
      H,
      root,
      "lib.nvim",
      "waits",
      F.meta("T", "blocked", { { "blocked_by", "lib.nvim/was-blocker" } })
    )
    H.write(backlog .. "2026-02-02_was-blocker.md", F.text(F.meta("Was", "done")))
  end, { "warn:blocked-by-done" }, function()
    remove(tasks .. "waits.md")
    remove(backlog .. "2026-02-02_was-blocker.md")
  end)

  -- ── the generated index ─────────────────────────────────────────────────
  local index_path = root .. "/lib.nvim/ROADMAP/TASKS.md"
  local index_text = H.read(index_path)
  expect("index missing although tasks are open", function()
    remove(index_path)
  end, { "index-stale" }, function()
    H.write(index_path, index_text)
  end, true)
  expect("index out of date", function()
    H.write(index_path, index_text .. "\nextra\n")
  end, { "index-stale" }, function()
    H.write(index_path, index_text)
  end, true)
  expect("an index although no task is open", function()
    H.write(
      root .. "/nvim-config/ROADMAP/TASKS.md",
      "<!-- GENERATED by tasks.nvim (:Tasks index) -- stand-in -->\nleftover\n"
    )
  end, { "index-stale" }, function()
    remove(root .. "/nvim-config/ROADMAP/TASKS.md")
  end, true)
  expect("a new task without regenerating the index", function()
    F.task(H, root, "lib.nvim", "late", F.meta("Late", "open"))
  end, { "index-stale" }, function()
    remove(tasks .. "late.md")
  end, true)

  -- ── details of the report ───────────────────────────────────────────────
  F.task(H, root, "lib.nvim", "late", F.meta("Late", "open"))
  H.write(tasks .. "prose.md", "text\n")
  F.task(
    H,
    root,
    "cascade.nvim",
    "dangler",
    F.meta("T", "blocked", { { "blocked_by", "lib.nvim/gone" } })
  )
  local res = run()
  ok(not res.ok, "errors make the run fail")
  ok(res.errors >= 3)
  eq(res.warnings, 0)
  eq(res.errors + res.warnings, #res.findings)
  for i = 2, #res.findings do
    local a, b = res.findings[i - 1], res.findings[i]
    ok(
      a.area < b.area
        or (a.area == b.area and a.path < b.path)
        or (a.area == b.area and a.path == b.path and a.code <= b.code),
      "findings are sorted"
    )
  end
  for _, f in ipairs(res.findings) do
    ok(f.path and f.area and f.code and f.message and f.severity)
  end

  -- one area only; blockers are still resolved vault-wide
  local only_cascade = run({ area = "cascade.nvim" })
  eq(
    codes(only_cascade),
    { "blocked-by-dangling", "index-stale" },
    "only cascade.nvim findings, its index is stale too"
  )
  eq(only_cascade.areas, 1)
  F.task(
    H,
    root,
    "cascade.nvim",
    "points-over",
    F.meta("T", "blocked", { { "blocked_by", "lib.nvim/good" } })
  )
  local cross = run({ area = "cascade.nvim" })
  eq(#cross.findings, #only_cascade.findings, "a blocker in another area resolves")
  for _, f in ipairs(cross.findings) do
    ok(not f.message:find("lib.nvim/good", 1, true), "lib.nvim/good exists, so it is not dangling")
  end

  local unknown, unknown_err = check.run({ root = root, area = "nope.nvim" })
  eq(unknown, nil)
  ok(unknown_err:find("unknown area", 1, true))
  local no_vault, no_vault_err = check.run({ root = root .. "/missing" })
  eq(no_vault, nil)
  ok(no_vault_err)

  -- format: path relative to the vault, forward slashes
  local line = check.format({
    path = root .. "/lib.nvim/ROADMAP/tasks/x.md",
    code = "bad-prio",
    severity = "error",
    message = "msg",
    area = "lib.nvim",
  }, root)
  eq(line, "lib.nvim/ROADMAP/tasks/x.md  bad-prio  msg")
  local warn_line = check.format({
    path = root .. "/a.md",
    code = "blocked-by-done",
    severity = "warn",
    message = "m",
    area = "a",
  }, root)
  eq(warn_line, "a.md  warn blocked-by-done  m")
  -- text from a file (a status, a ref, a file name) cannot carry an escape sequence to the terminal
  local evil_line = check.format({
    path = root .. "/lib.nvim/ROADMAP/tasks/x\27[2J.md",
    code = "unknown-status",
    severity = "error",
    message = "unknown status 'a\27]52;c;AAAA\7b'",
    area = "lib.nvim",
  }, root)
  ok(not evil_line:find("%c"), "no control character in the printed line")
  eq(evil_line, "lib.nvim/ROADMAP/tasks/x [2J.md  unknown-status  unknown status 'a ]52;c;AAAA b'")

  -- CRLF task files raise no finding of their own
  remove(tasks .. "prose.md")
  remove(tasks .. "late.md")
  remove(root .. "/cascade.nvim/ROADMAP/tasks/dangler.md")
  remove(root .. "/cascade.nvim/ROADMAP/tasks/points-over.md")
  H.write(
    tasks .. "crlf.md",
    H.crlf(F.text(F.meta("Windows", "parked", { { "prio", "2" } }), "\nBody.\n"))
  )
  reindex()
  eq(codes(run()), {}, "a CRLF task file is fine")
end
