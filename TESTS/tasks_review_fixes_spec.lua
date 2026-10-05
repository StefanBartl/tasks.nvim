-- TESTS/tasks_review_fixes_spec.lua -- regressions of the SEC/ERR rule review of 2026-10-05: linear escaping of
-- table cells (a backslash run in front of `|` stays escaped), no quadratic parse of a file with many opaque
-- keys, `fsio.read` refuses what is not a small regular file, and C1 control characters never reach an asset name.

---@diagnostic disable: duplicate-set-field, need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace module functions with test doubles on purpose.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local fsio = require("tasks_nvim.fsio")
  local model = require("tasks_nvim.model")
  local index = require("tasks_nvim.index")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local BS = string.char(92)

  ---Seconds `f` takes.
  ---@param f fun()
  ---@return number
  local function timed(f)
    local t0 = vim.uv.hrtime()
    f()
    return (vim.uv.hrtime() - t0) / 1e9
  end

  -- ── md_cell / double_runs ───────────────────────────────────────────────
  eq(fsio.md_cell("a|b"), "a" .. BS .. "|b", "a pipe is escaped")
  eq(
    fsio.md_cell("a" .. BS .. "|b"),
    "a" .. BS .. BS .. BS .. "|b",
    "a backslash run in front of the pipe is doubled, so the pipe stays escaped"
  )
  eq(fsio.md_cell("a" .. BS .. "b"), "a" .. BS .. "b", "a backslash elsewhere is left alone")
  eq(fsio.md_cell("a\nb\27c"), "a b c", "line breaks and control characters become spaces")
  eq(
    fsio.double_runs("x" .. BS, "^[%]]", true),
    "x" .. BS .. BS,
    "a run at the very end is doubled on request"
  )
  eq(fsio.double_runs("x" .. BS, "^[%]]"), "x" .. BS, "and left alone otherwise")

  local task = model.parse_text(
    '---\ntitle: "a' .. BS .. BS .. '|b"\nstatus: open\n---\nbody',
    { path = "E:/v/a/ROADMAP/tasks/x.md", area = "a" }
  )
  local rendered = index.render("a", { task })
  -- `a\|b` (a backslash, a pipe) in the title: the row has exactly the six cell borders of five columns.
  local row
  for line in rendered:gmatch("[^\n]+") do
    if line:find("| open", 1, true) then
      row = line
    end
  end
  ok(row ~= nil, "the row is rendered")
  local unescaped = 0
  local i = 1
  while i <= #row do
    local c = row:sub(i, i)
    if c == BS then
      i = i + 2
    else
      if c == "|" then
        unescaped = unescaped + 1
      end
      i = i + 1
    end
  end
  eq(unescaped, 6, "no title character turns into a table border")

  local long = string.rep(BS, 30000) .. "a"
  ok(timed(function()
    fsio.md_cell(long)
  end) < 0.5, "md_cell is linear on a long backslash run")
  local long_task = model.parse_text(
    "---\ntitle: " .. long .. "\nstatus: open\n---\nbody",
    { path = "E:/v/a/ROADMAP/tasks/y.md", area = "a" }
  )
  ok(timed(function()
    index.render("a", { long_task })
  end) < 1, "index.render is linear on a title of 30 000 backslashes")

  -- ── many opaque keys ────────────────────────────────────────────────────
  local lines = { "---", "title: x", "status: open" }
  for n = 1, 6000 do
    lines[#lines + 1] = ("k%d: {a"):format(n)
  end
  lines[#lines + 1] = "---"
  lines[#lines + 1] = "body"
  local text = table.concat(lines, "\n")
  local parsed
  ok(timed(function()
    parsed = model.parse_text(text, { path = "E:/v/a/ROADMAP/tasks/z.md", area = "a" })
  end) < 1, "6000 unsupported frontmatter values parse in linear time")
  ok(not parsed.valid, "and the file is still reported as invalid")

  -- ── fsio.read ───────────────────────────────────────────────────────────
  local dir = H.tmpdir()
  H.write(dir .. "/small.md", "hello")
  eq(fsio.read(dir .. "/small.md"), "hello", "a small file reads")
  local none, err_dir = fsio.read(dir)
  eq(none, nil, "a directory does not read")
  has(err_dir, "not a regular file")
  local big = io.open(dir .. "/big.md", "wb")
  assert(big)
  big:write(string.rep("x", fsio.MAX_READ_BYTES + 1))
  big:close()
  local none2, err_big = fsio.read(dir .. "/big.md")
  eq(none2, nil, "a file past MAX_READ_BYTES does not read")
  has(err_big, "larger than")
  local none3 = fsio.read(dir .. "/missing.md")
  eq(none3, nil, "a missing file keeps answering nil, err")

  local bigtask = model.from_file(dir .. "/big.md", { area = "a" })
  ok(not bigtask.valid, "an oversized task file is an invalid task, not a stall")
  eq(bigtask.error_codes, { "unreadable" })

  -- ── asset names ─────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Asset names", folder = true }))
  )
  local src = dir .. "/src.txt"
  H.write(src, "x")
  local _, e1 = mutate.attach(made.id, src, vim.tbl_extend("force", o, { name = "a\194\155b.txt" }))
  has(e1, "asset name may only use", "a C1 control character (CSI) in the name is refused")
  local good = mutate.attach(made.id, src, vim.tbl_extend("force", o, { name = "gr\195\188n.txt" }))
  ok(good ~= nil, "a non-ASCII letter is still fine")

  -- ── done: the rollback never deletes a finished copy this run did not create ──
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Race task" })))
  local target = root .. "/lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_" .. plain.slug .. ".md"
  local orig_create = fsio.create_exclusive
  fsio.create_exclusive = function(path, body)
    -- Another process finished the same task between this run's snapshot and this call.
    H.write(path, body)
    return false, "exists"
  end
  local okc, dres, derr = pcall(mutate.done, plain.id, o)
  fsio.create_exclusive = orig_create
  assert(okc, dres)
  eq(dres, nil, "done reports the failure")
  has(derr, "exists")
  ok(H.exists(target), "the other process's finished copy survives the rollback")
  ok(H.exists(plain.path), "and the original is untouched")

  -- ── set: a missing patch is an answer, not a raise ──────────────────────
  local sres, serr = mutate.set(plain.id, nil, o)
  eq(sres, nil)
  has(serr, "patch must be a table")

  -- ── an unreadable Backlog README stops done instead of "missing" ────────
  local second =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Readme task" })))
  local readme = root .. "/lib.nvim/Backlog/README.md"
  local rf = assert(io.open(readme, "wb"))
  rf:write(string.rep("x", fsio.MAX_READ_BYTES + 1))
  rf:close()
  local rres, rerr = mutate.done(second.id, o)
  eq(rres, nil, "done refuses to guess about a README it cannot read")
  has(rerr, "cannot read")
  ok(H.exists(second.path), "and the task stays where it was")

  -- ── filter options: no value is not "matches nothing" ───────────────────
  for _, flag in ipairs({ "status", "kind", "tag", "category", "prio" }) do
    local f, ferr = model.filter_from_options({ [flag] = "" })
    eq(f, nil, "--" .. flag .. "= is an error")
    has(ferr, "--" .. flag .. " needs a value")
  end
  local _, terr = model.filter_from_options({ today = "garbage" })
  has(terr, "--today must be YYYY-MM-DD")

  -- ── retarget_buffers survives a window that refuses `:edit` ─────────────
  if vim.fn.exists("&winfixbuf") == 1 then
    local ui_cmd = require("tasks_nvim.ui.cmd")
    local from, to = dir .. "/old-task.md", dir .. "/new-task.md"
    H.write(from, "x")
    H.write(to, "x")
    vim.cmd("edit " .. vim.fn.fnameescape(from))
    vim.wo.winfixbuf = true
    local rok, rerr2 = pcall(ui_cmd.retarget_buffers, from, to)
    vim.wo.winfixbuf = false
    vim.cmd("enew")
    ok(rok, "no E1513 escapes retarget_buffers: " .. tostring(rerr2))
  end

  -- ── dashboard `s`: a step planned from a stale list does not overwrite a newer change ──
  local core = require("tasks_nvim.ui.dash_core")
  local shown = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Stale step" })))
  local snapshot = assert(scan.find(shown.id, { root = root }))
  eq(snapshot.status, "open")
  local plan = core.plan_cycle({ snapshot }, "status")
  -- Meanwhile another session blocks the task.
  assert(mutate.set(shown.id, { status = "blocked" }, o))
  local applied = core.apply_set(plan, { root = root, today = F.TODAY })
  eq(#applied.failed, 1, "the stale step is a failure")
  has(applied.failed[1].err, "changed since the list was read")
  eq(
    assert(scan.find(shown.id, { root = root })).status,
    "blocked",
    "the other session's change stays"
  )

  -- ── file exports never replace an existing file without --force ─────────
  local view = require("tasks_nvim.ui.view")
  local precious = dir .. "/precious.md"
  H.write(precious, "PRECIOUS")
  local export_target = { kind = "file", path = precious }
  has(view.overwrite_guard(export_target, false), "already exists")
  eq(view.overwrite_guard(export_target, true), nil, "--force lifts the guard")
  eq(
    view.overwrite_guard({ kind = "file", path = dir .. "/new-export.md" }, false),
    nil,
    "a new file is fine"
  )
  eq(view.overwrite_guard({ kind = "buffer" }, false), nil, "other targets are never blocked")
  local snap = assert(scan.find(shown.id, { root = root }))
  local dok, dwhy = view.deliver({ snap }, export_target, { format = "md" })
  eq(dok, false, "deliver refuses the existing file")
  has(dwhy, "--force")
  eq(H.read(precious), "PRECIOUS", "and leaves it as it was")
  local dok2 = view.deliver({ snap }, export_target, { format = "md", force = true })
  ok(dok2, "with force it writes")
  ok(H.read(precious) ~= "PRECIOUS", "and the file changed")

  -- ── confirm.shorten ─────────────────────────────────────────────────────
  local confirm = require("tasks_nvim.ui.confirm")
  eq(confirm.shorten("short", 10), "short")
  eq(
    vim.fn.strchars(confirm.shorten(string.rep("x", 400), 70)),
    70,
    "a long title is cut to the width"
  )
  ok(vim.endswith(confirm.shorten(string.rep("x", 400), 70), "…"), "and says so")

  -- ── a TASKS.md that is not a generated index is never overwritten or removed ──
  local own = root .. "/cascade.nvim/ROADMAP/TASKS.md"
  H.write(own, "my own notes, no marker")
  local wres, werr = index.write_area("cascade.nvim", { root = root })
  eq(wres, nil, "write_area refuses a foreign TASKS.md")
  has(werr, "not a generated index")
  eq(H.read(own), "my own notes, no marker", "and leaves it alone")
  local cres = index.write_area("cascade.nvim", { root = root, check = true })
  eq(cres, nil, "--check reports it as an error, not as stale")
  ok(index.is_generated(index.GENERATED_MARK .. "\nrest"), "the current marker is recognised")
  ok(
    index.is_generated("<!-- GENERATED by :MyPlugins tasks index -- do not edit -->\nrest"),
    "so is the marker an earlier version wrote"
  )
  ok(
    not index.is_generated("# my notes\n<!-- GENERATED -->"),
    "a marker below the first line is not one"
  )
  vim.fn.delete(own)

  -- ── odd input at the edges ──────────────────────────────────────────────
  local pf, pe = model.filter_from_options({ prio = "<=0" })
  eq(pf, nil, "--prio=<=0 is an error, not a filter that matches nothing")
  has(pe, "--prio must be")
  eq(select(1, model.filter_from_options({ prio = "<=9" })), nil, "and so is <=9")
  ok(model.filter_from_options({ prio = "<=2" }) ~= nil, "<=2 still works")
  ok(not tostring(mutate.slugify(nil)):find("null", 1, true), "slugify(nil) is not `v-null`")
  eq(model.split_commas(nil), {}, "split_commas(nil) is an empty list, not a raise")
  eq(
    select(1, model.filter_from_options({ status = true })),
    nil,
    "--status as a bare flag is an error"
  )

  -- ── --stale=refs fails open: a check that cannot run does not look like "nothing is stale" ──
  local staleness = require("tasks_nvim.staleness")
  local with_refs = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend("force", o, { title = "Has refs", refs = { "lua/x.lua" } })
    )
  )
  local without_refs =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "No refs" })))
  local pair = {
    assert(scan.find(with_refs.id, { root = root })),
    assert(scan.find(without_refs.id, { root = root })),
  }
  ---@type string|nil
  local refresh_error
  local real_compute = staleness.compute
  staleness.compute = function()
    error("boom")
  end
  local okf, kept, report = pcall(model.filter, pair, { stale_refs = true })
  staleness.compute = real_compute
  assert(okf, kept)
  eq(#kept, 1, "the task with refs stays, the one without is not a candidate")
  eq(kept[1].id, with_refs.id)
  has(report.notes[1], "refs could not be checked")
  has(report.notes[1], "unverified")

  -- ── a refresh that raises is counted and reported, the watcher survives ──
  local watcher = require("tasks_nvim.ui.dash_watch").new({
    root = root,
    on_refresh = function()
      error("refresh boom")
    end,
    on_error = function(e)
      refresh_error = tostring(e)
    end,
  })
  watcher.stopped = false -- as `start` leaves it; the handles are not needed to drive one refresh
  watcher:fire()
  eq(watcher.stats.errors, 1, "the failure is counted")
  has(refresh_error, "refresh boom")
  ok(not watcher.stopped, "and the watcher is still there")
  watcher:stop()

  -- ── an unreadable (here: oversized) index is an error, not "missing" ──
  local big_index = root .. "/lib.nvim/ROADMAP/TASKS.md"
  local bf = assert(io.open(big_index, "wb"))
  bf:write(string.rep("x", fsio.MAX_READ_BYTES + 1))
  bf:close()
  local ires, ierr = index.write_area("lib.nvim", { root = root })
  eq(ires, nil)
  has(ierr, "cannot read")
  vim.fn.delete(big_index)
end
