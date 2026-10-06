-- TESTS/tasks_marker_blocks_spec.lua -- the generated blocks of hand-written documents (`<!-- GENERATED:plan scope=...
-- start -->`): what the marker records, which block a name stands for, fenced examples, repeated blocks, line endings,
-- the summary that must not split a block, a refresh that must not overwrite a concurrent edit, one scan per document.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace
-- module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local plans = require("tasks_nvim.plans")
  local plan_view = require("tasks_nvim.plan_view")
  local plan_scope = require("tasks_nvim.plan_scope")
  local scan = require("tasks_nvim.scan")
  local cli = require("tasks_nvim.cli")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local function run(argv)
    local out, err = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. F.TODAY }), {
        out = function(x)
          out[#out + 1] = x
        end,
        err = function(x)
          err[#err + 1] = x
        end,
      })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function new_plan(area, title, extra)
    return assert(plans.new(area, vim.tbl_extend("force", o, { title = title }, extra or {})))
  end

  -- ── the marker line: name and recorded attributes ──
  local start_line = plan_view.start_line("rel", { ready = "1", plan = "lib.nvim/rel" })
  eq(start_line, "<!-- GENERATED:plan scope=rel plan=lib.nvim/rel ready=1 start -->")
  local name, attrs = plan_view.parse_start(start_line .. "\r")
  eq(name, "rel")
  eq(attrs, { plan = "lib.nvim/rel", ready = "1" })
  eq(plan_view.parse_start("<!-- GENERATED:plan scope=a start -->"), "a")
  eq(plan_view.parse_start("<!-- GENERATED:plan scope= start -->"), nil)
  eq(
    plan_view.parse_start("  <!-- GENERATED:plan scope=a start -->"),
    nil,
    "a marker starts at column 0"
  )
  local s1, f1 = plan_view.block_markers("a")
  eq(s1, "<!-- GENERATED:plan scope=a start -->", "a plain marker stays what it was")
  eq(f1, "<!-- GENERATED:plan end -->")

  -- ── fenced examples are no markers; repeated blocks are all refreshed; every other line keeps its ending ──
  local s, f = plan_view.block_markers("x")
  local fenced = table.concat({
    "intro",
    "```",
    s,
    "EXAMPLE",
    f,
    "```",
    "~~~~md",
    s,
    "tilde example",
    f,
    "~~~~",
    s,
    "REAL ONE",
    f,
    s,
    "REAL TWO",
    f,
    "tail",
  }, "\n")
  eq(plan_view.block_scopes(fenced), { "x" }, "each scope once, the fenced examples do not count")
  local replaced, rerr, changed, scopes = plan_view.replace_blocks(fenced, function(block)
    if block.scope == "x" then
      return "NEW"
    end
  end)
  eq(rerr, nil)
  ok(changed)
  eq(scopes, { "x" })
  has(replaced, "EXAMPLE", "the fenced example is untouched")
  has(replaced, "tilde example")
  lacks(replaced, "REAL ONE")
  lacks(replaced, "REAL TWO")
  eq(select(2, replaced:gsub("NEW", "")), 2, "both real blocks were replaced")

  -- mixed endings: only the block changes, every other line keeps its own bytes
  local mixed = "head\r\n" .. s .. "\nOLD\n" .. f .. "\nlf line\ncr line\r\ntail"
  local mixed_new = assert(plan_view.replace_block(mixed, "x", "A\nB"))
  eq(mixed_new, "head\r\n" .. s .. "\nA\nB\n" .. f .. "\nlf line\ncr line\r\ntail")
  local crlf_block = "head\n" .. s .. "\r\nOLD\r\n" .. f .. "\ntail\n"
  eq(
    assert(plan_view.replace_block(crlf_block, "x", "A")),
    "head\n" .. s .. "\r\nA\r\n" .. f .. "\ntail\n",
    "the body takes the ending of its start marker"
  )

  -- a body with a marker line would split the block on the next read
  local bad, berr = plan_view.replace_block(mixed, "x", "ok\n" .. f .. "\nmore")
  eq(bad, nil)
  has(berr, "marker line")

  -- ── a plan summary that reads like a marker cannot split the block ──
  local evil = new_plan("lib.nvim", "Evil summary")
  local evil_text = H.read(evil.path)
    :gsub("\n%-%-%-\n", "\nsummary: <!-- GENERATED:plan end -->\n---\n", 1)
  H.write(evil.path, evil_text)
  F.task(H, root, "lib.nvim", "evil-member", F.meta("Evil member", "open", { { "plan", evil.id } }))
  local doc = H.tmpdir() .. "/EVIL.md"
  local es, ef = plan_view.block_markers("evil-summary")
  H.write(doc, "# Doc\n\n" .. es .. "\nSTALE\n" .. ef .. "\n\nend\n")
  local first = assert(plan_scope.refresh_document(doc, root))
  eq(first.refreshed, { "evil-summary" })
  local size = #H.read(doc)
  for _ = 1, 3 do
    assert(plan_scope.refresh_document(doc, root))
  end
  eq(#H.read(doc), size, "the document does not grow with every refresh")
  eq(#plan_view.block_scopes(H.read(doc)), 1, "no foreign block appeared")
  has(H.read(doc), "end\n", "the text after the block is still there")
  lacks(
    H.read(doc),
    "\n<!-- GENERATED:plan end -->\n\n> ",
    "the summary sits behind a quote, not on a line of its own"
  )

  -- ── a slug two plans share is ambiguous; the recorded target decides ──
  local lib_rel = new_plan("lib.nvim", "Release")
  local cas_rel = new_plan("cascade.nvim", "Release")
  F.task(H, root, "lib.nvim", "lib-work", F.meta("Lib work", "open", { { "plan", lib_rel.id } }))
  F.task(
    H,
    root,
    "cascade.nvim",
    "cas-work",
    F.meta("Cas work", "open", { { "plan", cas_rel.id } })
  )
  local rs = plan_view.block_markers("release")
  local ambiguous_doc = H.tmpdir() .. "/AMBIG.md"
  H.write(ambiguous_doc, rs .. "\nSTALE\n" .. ef .. "\n")
  local amb = assert(plan_scope.refresh_document(ambiguous_doc, root))
  eq(#amb.skipped, 1, "the block that two plans could mean is skipped, not guessed")
  has(amb.skipped[1].reason, "ambiguous")
  has(amb.skipped[1].reason, "lib.nvim/release")
  has(amb.skipped[1].reason, "cascade.nvim/release")
  eq(H.read(ambiguous_doc), rs .. "\nSTALE\n" .. ef .. "\n", "and left as it was")
  -- `plan --write` records the target: the refresh finds the right plan
  local wrote =
    run({ "plan", "--plan=" .. cas_rel.id, "--scope=release", "--write=" .. ambiguous_doc })
  eq(wrote.code, 0, wrote.err)
  local written = H.read(ambiguous_doc)
  has(written, "scope=release plan=cascade.nvim/release start -->", "the marker records the plan")
  has(written, "Cas work")
  lacks(written, "Lib work")
  assert(plan_scope.refresh_document(ambiguous_doc, root))
  has(H.read(ambiguous_doc), "Cas work", "a refresh keeps the recorded plan")
  lacks(H.read(ambiguous_doc), "Lib work")

  -- ── the view and the filters are recorded: refresh and --check agree with the write ──
  local view_doc = H.tmpdir() .. "/VIEW.md"
  H.write(view_doc, "# V\n\n" .. plan_view.block_markers("lib.nvim") .. "\nSTALE\n" .. ef .. "\n")
  F.task(H, root, "lib.nvim", "doing-one", F.meta("Doing one", "doing"))
  F.task(H, root, "lib.nvim", "open-one", F.meta("Open one", "open"))
  local view_args = { "plan", "lib.nvim", "--status=doing", "--ready", "--write=" .. view_doc }
  eq(run(view_args).code, 0)
  local with_view = H.read(view_doc)
  has(with_view, "ready=1")
  has(with_view, "status=doing")
  has(with_view, "Doing one")
  lacks(with_view, "Open one", "the filter narrowed the block")
  assert(plan_scope.refresh_document(view_doc, root))
  eq(H.read(view_doc), with_view, "the refresh after a finish builds the same block")
  local check_args = vim.list_extend(vim.deepcopy(view_args), { "--check" })
  eq(run(check_args).code, 0, "--check agrees: current")
  -- a value that cannot be recorded is refused, not dropped
  local unrecordable = run({ "plan", "lib.nvim", "--tag=a b", "--write=" .. view_doc })
  eq(unrecordable.code, 2)
  has(unrecordable.err, "cannot be recorded")

  -- ── the vault is read once for a document with many blocks ──
  local many = { "# Many" }
  for _ = 1, 5 do
    vim.list_extend(many, { plan_view.block_markers("lib.nvim"), "STALE", ef })
  end
  vim.list_extend(many, { plan_view.block_markers("cascade.nvim"), "STALE", ef })
  local many_doc = H.tmpdir() .. "/MANY.md"
  H.write(many_doc, table.concat(many, "\n") .. "\n")
  local real_all, scans = scan.all, 0
  scan.all = function(sopts)
    scans = scans + 1
    return real_all(sopts)
  end
  local many_res = assert(plan_scope.refresh_document(many_doc, root))
  scan.all = real_all
  ok(scans <= 1, "one scan for six blocks (" .. scans .. ")")
  eq(many_res.refreshed, { "lib.nvim", "cascade.nvim" })
  has(H.read(many_doc), "Lib work")
  lacks(H.read(many_doc), "STALE", "every repeated block was refreshed")

  -- ── an edit made while the blocks are being worked out is not overwritten ──
  local race_doc = H.tmpdir() .. "/RACE.md"
  H.write(race_doc, plan_view.block_markers("lib.nvim") .. "\nSTALE\n" .. ef .. "\n")
  local real_shared = plan_scope.shared
  plan_scope.shared = function(r, scanned)
    H.write(race_doc, H.read(race_doc) .. "WRITTEN BY SOMEONE ELSE\n")
    return real_shared(r, scanned)
  end
  local raced = assert(plan_scope.refresh_document(race_doc, root))
  plan_scope.shared = real_shared
  ok(raced.changed)
  has(H.read(race_doc), "WRITTEN BY SOMEONE ELSE", "the concurrent edit is kept")
  has(H.read(race_doc), "Lib work", "and the block was refreshed in the new text")
  -- one that keeps changing is given up on, nothing is written
  local busy_doc = H.tmpdir() .. "/BUSY.md"
  H.write(busy_doc, plan_view.block_markers("lib.nvim") .. "\nSTALE\n" .. ef .. "\n")
  local real_read = require("tasks_nvim.fsio").read
  require("tasks_nvim.fsio").read = function(path)
    local text = real_read(path)
    if text and path == busy_doc then
      -- every read finds the file as it was and changes it right after: the document is never at rest
      H.write(busy_doc, text .. "x\n")
    end
    return text
  end
  local busy, busy_err = plan_scope.refresh_document(busy_doc, root)
  require("tasks_nvim.fsio").read = real_read
  eq(busy, nil)
  has(busy_err, "changed while")

  -- ── a closed plan's text goes to the block that names that plan, not to a namesake ──
  local closed_doc = H.tmpdir() .. "/CLOSED.md"
  H.write(closed_doc, table.concat({
    plan_view.block_markers("done-one", { plan = "lib.nvim/done-one" }),
    "STALE A",
    ef,
    plan_view.block_markers("done-one", { plan = "cascade.nvim/done-one" }),
    "STALE B",
    ef,
  }, "\n") .. "\n")
  local summary = { tasks = 1, days = 1, n_without_effort = 0 }
  local closed_text = plan_view.plan_closed_text("lib.nvim/done-one", summary)
  local closed_res =
    assert(plan_scope.refresh_document(closed_doc, root, { ["lib.nvim/done-one"] = closed_text }))
  has(H.read(closed_doc), closed_text)
  has(
    H.read(closed_doc),
    "STALE B",
    "the block of the other plan is not given the closed plan's text"
  )
  ok(#closed_res.skipped >= 1, "and it says why it was not refreshed")

  -- ── the scope: the area history only fits an unfiltered area ──
  local whole = assert(plan_scope.load({ root = root, area = "lib.nvim" }))
  ok(whole.done ~= nil, "an unfiltered area scope carries the history")
  local narrowed = assert(plan_scope.load({
    root = root,
    area = "lib.nvim",
    filter = { status = { "doing" }, ref_opts = { root = root } },
  }))
  eq(narrowed.done, nil, "a narrowed list has no progress figure against the whole history")
  local by_plan = assert(plan_scope.load({ root = root, plan_id = lib_rel.id, area = "lib.nvim" }))
  eq(by_plan.done, nil, "nor a plan scope")

  -- ── a blocker that says `done` but still sits in ROADMAP/tasks blocks nobody ──
  local gate = F.task(H, root, "cascade.nvim", "was-done", F.meta("Was done", "done"))
  ok(H.exists(gate))
  local waiter = F.task(
    H,
    root,
    "cascade.nvim",
    "waits-on-it",
    F.meta("Waits on it", "open", { { "blocked_by", "[cascade.nvim/was-done]" } })
  )
  ok(H.exists(waiter))
  local shared = assert(plan_scope.shared(root))
  local waiting = scan.find("cascade.nvim/waits-on-it", { root = root })
  eq(
    require("tasks_nvim.plan").classify(waiting, shared.index),
    "ready",
    "a finished blocker (status done) does not hold the task back"
  )

  -- ── write_block refuses a scope that could not be read completely ──
  local degraded = vim.deepcopy(whole)
  degraded.errors = { "cannot list somewhere" }
  local before = H.read(view_doc)
  local refused, ref_err =
    plan_scope.write_block(view_doc, degraded, { key = "lib.nvim", attrs = { ready = "1" } })
  eq(refused, nil)
  has(ref_err, "could not be read")
  eq(H.read(view_doc), before, "nothing was written")
end
