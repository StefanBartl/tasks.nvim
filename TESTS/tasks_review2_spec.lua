-- TESTS/tasks_review2_spec.lua -- the second review round (the commits of waves 0-3 read for bugs, security and
-- performance): each fix has its case here. The marker blocks have their own spec (`tasks_marker_blocks_spec`), the
-- plan close and the id namespace are in `tasks_plans_spec`, the SEC-32 patterns in `tasks_review_fixes_spec`.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace
-- module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local batch = require("tasks_nvim.batch")
  local cli = require("tasks_nvim.cli")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local plan_view = require("tasks_nvim.plan_view")

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

  -- ── a typed count is not a loop: `999999999p` is one cycle ──
  do
    local tasks = {}
    for _, status in ipairs({ "open", "doing", "blocked", "parked", "decision", "done", "weird" }) do
      tasks[#tasks + 1] = { id = "a/" .. status, status = status }
    end
    tasks[#tasks + 1] = { id = "a/none" }
    local function naive(cur, step, presses)
      for _ = 1, presses do
        cur = step(cur)
      end
      return cur
    end
    for presses = 1, 14 do
      for _, step in ipairs(batch.plan_cycle(tasks, "status", presses)) do
        local from = step.from
        eq(
          step.to,
          naive(from, model.cycle_status, presses),
          ("status %s x%d"):format(tostring(from), presses)
        )
      end
    end
    local prios = {}
    for _, prio in ipairs({ 1, 2, 3, 9 }) do
      prios[#prios + 1] = { id = "a/p" .. prio, prio = prio }
    end
    prios[#prios + 1] = { id = "a/pnone" }
    for presses = 1, 14 do
      for _, step in ipairs(batch.plan_cycle(prios, "prio", presses)) do
        eq(
          step.to,
          naive(step.from, model.cycle_prio, presses),
          ("prio %s x%d"):format(tostring(step.from), presses)
        )
      end
    end
    local t0 = vim.uv.hrtime()
    local huge = batch.plan_cycle(tasks, "status", 999999999)
    ok((vim.uv.hrtime() - t0) / 1e9 < 0.2, "a huge count costs one cycle, not a billion steps")
    eq(#huge, #tasks)
    for _, step in ipairs(huge) do
      eq(
        step.to,
        naive(step.from, model.cycle_status, 1 + ((999999999 - 1) % #model.OPEN_STATUSES))
      )
    end
  end

  -- ── migrate-actor names an area that does not exist ──
  do
    local typo = run({ "migrate-actor", "lib.nv1m" })
    eq(typo.code, 2)
    has(typo.err, "unknown area")
    eq(run({ "migrate-actor", "lib.nvim" }).code, 0, "a real area still works")
  end

  -- ── done --unblock: the advice is worked out after the freed tasks are open ──
  do
    local x =
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Blocker", status = "doing" }))
    F.task(
      H,
      root,
      "lib.nvim",
      "waiter",
      F.meta("Waiter", "blocked", { { "blocked_by", "[lib.nvim/blocker]" } })
    )
    F.task(H, root, "lib.nvim", "decider", F.meta("Decider", "decision"))
    local res = run({ "done", x.id, "--unblock" })
    eq(res.code, 0, res.err)
    has(res.out, "unblocked\tlib.nvim/waiter")
    local first_next = res.out:match("next: ([^\t\n]+)")
    eq(first_next, "lib.nvim/waiter", "the task that was just unblocked leads the advice")
    lacks(res.out, "next: lib.nvim/decider", "and the decision does not")
  end

  -- ── the headless CLI refreshes the documents named in $TASKS_MARKER_DOCS ──
  do
    local doc = H.tmpdir() .. "/ENV-HANDOVER.md"
    local s, f = plan_view.block_markers("lib.nvim")
    H.write(doc, "# Doc\n\n" .. s .. "\nSTALE\n" .. f .. "\n")
    local member = mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Env member" }))
    vim.env.TASKS_MARKER_DOCS = doc
    local res = run({ "done", member.id })
    vim.env.TASKS_MARKER_DOCS = nil
    eq(res.code, 0, res.err)
    has(res.out, "refreshed\t")
    lacks(H.read(doc), "STALE")
    local docs = require("tasks_nvim.done_flow").marker_docs()
    eq(#docs, 0, "unset again: no document")
  end

  -- ── a task of a status nobody knows is not "everything is done" ──
  do
    local lonely = F.vault(H)
    F.task(H, lonely, "lib.nvim", "typo", F.meta("Typo", "in progress"))
    F.task(H, lonely, "lib.nvim", "notes", { { "title", "just notes" } })
    local out, err = {}, {}
    cli.run({ "next", "--vault=" .. lonely, "--today=" .. F.TODAY }, {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    local printed = table.concat(out)
    has(printed, "empty:")
    lacks(printed, "Everything is done")
    has(printed, "1 with a status nobody knows")
    -- a vault with nothing at all still says it
    local empty_root = F.vault(H)
    local out2 = {}
    cli.run({ "next", "--vault=" .. empty_root, "--today=" .. F.TODAY }, {
      out = function(x)
        out2[#out2 + 1] = x
      end,
      err = function() end,
    })
    has(table.concat(out2), "Everything is done")
  end

  -- ── ids are file names: a TAB or LF in one does not start a record of its own ──
  do
    local lines = plan_view.next_lines({
      task = { id = "a/b\tc\nd", title = "t" },
      reason = "vault",
      alternatives = { { id = "a/e\tf", title = "u" } },
      cdx = { { id = "a/i\tj", title = "v" } },
      freed = { "a/g\nh", "a/k" },
    })
    eq(#lines, 4, "next, then, freed and cdx: one line each")
    for _, line in ipairs(lines) do
      lacks(line, "\n")
    end
    eq(select(2, lines[1]:gsub("\t", "")), 2, "the next line has its two separators and no more")
    eq(select(2, lines[2]:gsub("\t", "")), 1)
    eq(select(2, lines[4]:gsub("\t", "")), 1)
  end

  -- ── the lock: cooperating writers are serialised, a dead holder does not block for ever ──
  do
    local fsio = require("tasks_nvim.fsio")
    local dir = H.tmpdir()
    local target = dir .. "/locked.md"
    H.write(target, "x")
    local lock = dir .. "/.locked.md.lock"
    local value, lerr = fsio.with_lock(target, function()
      ok(H.exists(lock), "the lock file exists while the function runs")
      return "ran", nil
    end)
    eq(value, "ran")
    eq(lerr, nil)
    ok(not H.exists(lock), "and is gone afterwards")
    local raised = pcall(fsio.with_lock, target, function()
      error("boom")
    end)
    eq(raised, false, "an error of the function propagates")
    ok(not H.exists(lock), "the lock is released on the way out")
    -- a lock held by someone else: wait, then give up with a message
    H.write(lock, "1234")
    local t0 = vim.uv.hrtime()
    local none, busy = fsio.with_lock(target, function()
      return "never", nil
    end, { wait_ms = 80 })
    eq(none, nil)
    has(busy, "being written by another process")
    ok((vim.uv.hrtime() - t0) / 1e9 < 1.5, "the wait is bounded")
    ok(H.exists(lock), "a lock that is not ours stays")
    -- one that is older than the stale limit belongs to a process that died: taken over
    local old = os.time() - 120
    vim.uv.fs_utime(lock, old, old)
    eq(
      fsio.with_lock(target, function()
        return "took over", nil
      end),
      "took over"
    )
    ok(not H.exists(lock))

    -- `set` holds the lock while it rewrites the file
    local locked_task =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Lock me" })))
    local task_lock = fsio.dirname(locked_task.path) .. "/.lock-me.md.lock"
    local real_update = require("lib.nvim.markdown.frontmatter").update
    local seen_lock
    require("lib.nvim.markdown.frontmatter").update = function(...)
      seen_lock = H.exists(task_lock)
      return real_update(...)
    end
    local set_res = mutate.set(locked_task.id, { effort = "S" }, o)
    require("lib.nvim.markdown.frontmatter").update = real_update
    ok(set_res and set_res.changed)
    eq(seen_lock, true, "the frontmatter is rewritten under the lock")
    ok(not H.exists(task_lock))
  end

  -- ── a row another process added to the README while this finish was under way is kept ──
  do
    local fsio = require("tasks_nvim.fsio")
    local first =
      assert(mutate.new("cascade.nvim", vim.tbl_extend("force", o, { title = "Race one" })))
    local second =
      assert(mutate.new("cascade.nvim", vim.tbl_extend("force", o, { title = "Race two" })))
    local first_target = root .. "/cascade.nvim/Backlog/TASKS/" .. F.TODAY .. "_race-one.md"
    local real_create = fsio.create_exclusive
    local nested = false
    fsio.create_exclusive = function(path, text)
      if not nested and fsio.norm(path) == fsio.norm(first_target) then
        -- the other process finishes ITS task in the middle of ours
        nested = true
        assert(
          mutate.done(
            second.id,
            vim.tbl_extend("force", o, { checkpoint_dir = H.tmpdir() .. "/cp2" })
          )
        )
      end
      return real_create(path, text)
    end
    local res, derr = mutate.done(first.id, o)
    fsio.create_exclusive = real_create
    assert(res, derr)
    local readme = H.read(root .. "/cascade.nvim/Backlog/README.md")
    has(readme, "race-one", "the row of this finish")
    has(readme, "race-two", "and the row the other process added meanwhile")
    has(readme, "## TASKS (2)", "both counted")
  end

  -- ── staleness: positions after a drive letter, an invalid date, a repo git cannot use ──
  do
    local staleness = require("tasks_nvim.staleness")
    local function classified(ref, rel)
      local kind, got = staleness.classify(ref)
      eq(kind, "path", ref)
      eq(got, rel, ref)
    end
    classified("C:/repos/x/a.lua:42", "C:/repos/x/a.lua")
    classified("C:\\repos\\x\\a.lua:7", "C:/repos/x/a.lua")
    classified("lua/a.lua:42:7", "lua/a.lua")
    classified("lua/a.lua:10-20", "lua/a.lua")
    classified("C:/x/y.lua", "C:/x/y.lua")
    eq((staleness.classify("filetree.nvim:cheatsheet-paged")), "skip")
    eq((staleness.classify("a.lua:b:3")), "skip", "a second colon that is no position is no path")

    -- an invalid `updated` is no date: the file counts as changed, as --stale=<days> counts such a task as stale
    local top = H.tmpdir()
    H.write(top .. "/lib.nvim/a.lua", "x")
    local sopts = {
      root = root,
      repo_bases = { top },
      config_dir = top .. "/none",
      git_dates = function(_, rels)
        local out = {}
        for _, rel in ipairs(rels) do
          out[rel] = { date = "2026-10-01", file = rel }
        end
        return out
      end,
    }
    local report = staleness.compute({
      { id = "lib.nvim/x", area = "lib.nvim", refs = { "a.lua" }, updated = "2026-9-3" },
      { id = "lib.nvim/y", area = "lib.nvim", refs = { "a.lua" }, updated = "2026-10-02" },
    }, sopts)
    ok(report.stale["lib.nvim/x"] ~= nil, "an invalid updated date does not hide a change")
    eq(report.stale["lib.nvim/y"], nil, "a real, later date does")

    -- git that cannot be used at all: one probe, not a spawn per path (2n-1 by bisecting)
    local repo = H.tmpdir()
    local rels = {}
    for i = 1, 60 do
      rels[i] = "f" .. i .. ".lua"
    end
    local real_system, spawns = vim.system, 0
    vim.system = function()
      spawns = spawns + 1
      return {
        wait = function()
          return { code = 128, stderr = "fatal: kein Git-Repository", stdout = "" }
        end,
      }
    end
    staleness.reset_cache()
    local dates, gerr = staleness.git_dates(repo, rels)
    vim.system = real_system
    ok(spawns <= 2, ("one log and one probe, not a spawn per path (%d)"):format(spawns))
    ok(dates == nil or next(dates) == nil)
    ok(gerr ~= nil, "and it says so")
    staleness.reset_cache()
  end

  -- ── the index: a title is capped, a task that cannot be read is no reason to drop the index ──
  do
    local index = require("tasks_nvim.index")
    local fsio = require("tasks_nvim.fsio")
    local big = string.rep("T", 1024 * 1024)
    local area_root = F.vault(H)
    for i = 1, 3 do
      F.task(H, area_root, "lib.nvim", "big-" .. i, F.meta(big, "open"))
    end
    local first = assert(index.write_area("lib.nvim", { root = area_root }))
    eq(first.action, "written")
    local size = vim.uv.fs_stat(area_root .. "/lib.nvim/ROADMAP/TASKS.md").size
    ok(size < 20000, ("the index stays small whatever the titles are (%d bytes)"):format(size))
    local second = assert(index.write_area("lib.nvim", { root = area_root }))
    eq(second.action, "unchanged", "and it can be read back and checked again")
    -- a task file that cannot be read: an error, not a deleted or shrunken index
    local index_path = area_root .. "/lib.nvim/ROADMAP/TASKS.md"
    local before = H.read(index_path)
    H.write(
      area_root .. "/lib.nvim/ROADMAP/tasks/unreadable.md",
      string.rep("x", fsio.MAX_READ_BYTES + 1)
    )
    local res, rerr = index.write_area("lib.nvim", { root = area_root })
    eq(res, nil)
    has(rerr, "cannot read")
    has(rerr, "unreadable.md")
    eq(H.read(index_path), before, "the index is as it was")
  end

  -- ── check: a hard plan gate is a blocker, `blocked` under it is fine ──
  do
    local check = require("tasks_nvim.check")
    local plans = require("tasks_nvim.plans")
    local gate_root = F.vault(H)
    local go = { root = gate_root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
    local hard = assert(plans.new(
      "lib.nvim",
      vim.tbl_extend("force", go, {
        title = "Hard gate",
        phases = "one,two",
        gate = "hard",
      })
    ))
    local soft = assert(plans.new(
      "lib.nvim",
      vim.tbl_extend("force", go, {
        title = "Soft gate",
        phases = "one,two",
      })
    ))
    for _, p in ipairs({ { hard, "h" }, { soft, "s" } }) do
      F.task(
        H,
        gate_root,
        "lib.nvim",
        p[2] .. "-one",
        F.meta("One", "open", { { "plan", p[1].id }, { "phase", "one" } })
      )
      F.task(
        H,
        gate_root,
        "lib.nvim",
        p[2] .. "-two",
        F.meta("Two", "blocked", { { "plan", p[1].id }, { "phase", "two" } })
      )
    end
    local res = assert(check.run({ root = gate_root, today = F.TODAY, area = "lib.nvim" }))
    local without = {}
    for _, f in ipairs(res.findings) do
      if f.code == "blocked-without-blocker" then
        without[#without + 1] = f.id or f.slug or f.path
      end
    end
    eq(#without, 1, "only the task under the SOFT plan is reported")
    has(tostring(without[1]), "s-two")
  end

  -- ── same-file: the file a ref means, not the name it is written with ──
  do
    local plan_scope = require("tasks_nvim.plan_scope")
    local same_root = F.vault(H)
    F.task(H, same_root, "lib.nvim", "l1", F.meta("L1", "open", { { "refs", "[README.md]" } }))
    F.task(H, same_root, "cascade.nvim", "c1", F.meta("C1", "open", { { "refs", "[README.md]" } }))
    F.task(H, same_root, "lib.nvim", "l2", F.meta("L2", "open", { { "refs", "[README.md]" } }))
    local scope = assert(plan_scope.load({ root = same_root }))
    local node = scope.plan.nodes
    eq(node["lib.nvim/l1"].same_file, { "lib.nvim/l2" }, "the same repo's README is one file")
    eq(node["cascade.nvim/c1"].same_file, {}, "another repo's README is another file")
  end

  -- ── `:Tasks new`: the keys the form has no field for go on to the task; a range ref is one ref ──
  do
    local cmd = require("tasks_nvim.ui.cmd")
    local confirm = require("tasks_nvim.ui.confirm")
    local vault = require("tasks_nvim.vault")
    local scan = require("tasks_nvim.scan")
    vault.set_root(root)
    local orig_yesno, orig_notify = confirm.yesno, vim.notify
    confirm.yesno = function(_, _, cb)
      cb(false)
    end
    vim.notify = function() end
    local captured
    cmd.form_open = function(spec)
      captured = spec
    end
    cmd.task_new({
      args = { area = nil },
      kv = { plan = "lib.nvim/rel", phase = "build", order = "3" },
      flags = {},
      rest = {},
      range = { range = 0, line1 = 1, line2 = 1 },
    })
    cmd.form_open = nil
    assert(captured, "the form was opened")
    captured.on_submit({ area = "lib.nvim", opts = { title = "Via the form" } }, nil)
    local made = assert(scan.find("lib.nvim/via-the-form", { root = root }))
    eq(made.plan, "lib.nvim/rel", "plan= reached the task")
    eq(made.phase, "build", "phase= too")
    eq(made.order, 3, "and order=")

    local dir = H.tmpdir()
    local comma_file = dir .. "/a,b.lua"
    vim.fn.writefile({ "first line" }, comma_file)
    vim.cmd("edit " .. vim.fn.fnameescape(comma_file))
    local ctx = {
      args = { area = "lib.nvim" },
      kv = {},
      flags = {},
      rest = {},
      range = { range = 1, line1 = 1, line2 = 1 },
    }
    local src = assert(cmd.range_source(ctx))
    cmd.task_new(ctx)
    local ranged = assert(scan.find("lib.nvim/first-line", { root = root }))
    eq(ranged.refs, { src.ref }, "a file name with a comma stays ONE ref")
    vim.cmd("enew")
    confirm.yesno, vim.notify = orig_yesno, orig_notify
    vault.set_root(nil)
  end

  -- ── the dashboard: readiness is a filter, one scan per load, the chain's notes are told, the help is current ──
  do
    local core = require("tasks_nvim.ui.dash_core")
    local dash = require("tasks_nvim.ui.dash")
    local scan = require("tasks_nvim.scan")
    local dash_root = F.vault(H)
    F.task(H, dash_root, "lib.nvim", "free-one", F.meta("Free one", "open"))
    F.task(H, dash_root, "lib.nvim", "gate", F.meta("Gate", "open"))
    F.task(
      H,
      dash_root,
      "lib.nvim",
      "waits",
      F.meta("Waits", "open", { { "blocked_by", "[lib.nvim/gate]" } })
    )
    local function ids(res)
      return vim.tbl_map(function(t)
        return t.id
      end, res.tasks)
    end
    local ready = assert(core.load({ root = dash_root, filter = { readiness = "ready" } }))
    eq(
      vim.list_contains(ids(ready), "lib.nvim/waits"),
      false,
      "--ready leaves the waiting task out"
    )
    ok(vim.list_contains(ids(ready), "lib.nvim/free-one"))
    local waiting = assert(core.load({ root = dash_root, filter = { readiness = "waiting" } }))
    eq(ids(waiting), { "lib.nvim/waits" }, "--waiting keeps only it")
    eq(core.chips({ readiness = "ready" }), { "ready" }, "a chip says so")
    eq(core.filter_is_empty({ readiness = "waiting" }), false)
    eq(
      core.filter_from_stored(core.filter_to_options({ readiness = "ready" })).readiness,
      "ready",
      "and it is remembered"
    )
    eq(core.set_dim({}, "readiness", "waiting").readiness, "waiting", "the f menu sets it")
    ok(vim.list_contains(core.FILTER_DIMS, "readiness"))

    -- one pass over the vault builds the list AND where each task stands
    local real_all, scans = scan.all, 0
    scan.all = function(sopts)
      scans = scans + 1
      return real_all(sopts)
    end
    local loaded = assert(core.load({ root = dash_root, area = "lib.nvim" }))
    scan.all = real_all
    eq(scans, 1, "one scan for the list and the readiness")
    ok(loaded.readiness ~= nil and loaded.readiness.states["lib.nvim/waits"] == "waiting")

    -- the chain's follow-ups are told, and a note lifts the level
    local level, text = core.describe_done({
      done = { { id = "a/x" } },
      already = {},
      failed = {},
      areas = { "a" },
      index_errors = {},
      steps_ticked = 2,
      plans_closed = { "a/p" },
      docs_refreshed = { "/d.md" },
      notes = { "the plan a/q could not be closed: boom" },
    })
    eq(level, "warn")
    has(text, "2 plan steps ticked off")
    has(text, "plan a/p is finished")
    has(text, "/d.md")
    has(text, "could not be closed: boom")
    eq(
      (core.describe_done({ done = {}, already = {}, failed = {}, areas = {}, index_errors = {} })),
      "info"
    )

    -- the help names what exists
    local help = table.concat(dash.help_lines(), "\n")
    for _, sort in ipairs(require("tasks_nvim.model").SORTS) do
      has(help, sort)
    end
    for _, dim in ipairs(core.FILTER_DIMS) do
      has(help, dim)
    end
  end

  -- ── the help float is as tall as its text WRAPS ──
  do
    local help_float = require("tasks_nvim.ui.help_float")
    local long = string.rep("w", 300)
    local win = help_float.open({ long, long, "short" }, "tasks-review2-help")
    local config = vim.api.nvim_win_get_config(win)
    local rows = 0
    for _, text in ipairs({ long, long, "short" }) do
      rows = rows + math.max(1, math.ceil(#text / (config.width - 2)))
    end
    ok(config.height >= math.min(rows, vim.o.lines - 6), "the height counts wrapped rows")
    ok(config.height > 3, "not one row per logical line")
    vim.api.nvim_win_close(win, true)
    vim.on_key(nil, vim.api.nvim_create_namespace("tasks-review2-help"))
  end

  -- ── the <Tab> list of finished ids comes from file names, not from parsing every file ──
  do
    local routes = require("tasks_nvim.ui.routes")
    local vault = require("tasks_nvim.vault")
    local scan = require("tasks_nvim.scan")
    local comp_root = F.vault(H)
    vault.set_root(comp_root)
    H.write(
      comp_root .. "/lib.nvim/Backlog/TASKS/2026-09-01_old-one.md",
      F.text(F.meta("Old one", "done"))
    )
    H.write(
      comp_root .. "/lib.nvim/Backlog/FEATURES/2026-09-02_old-two.md",
      F.text(F.meta("Old two", "done"))
    )
    local real_backlog, parsed = scan.backlog, 0
    scan.backlog = function(...)
      parsed = parsed + 1
      return real_backlog(...)
    end
    local offered = routes.done_ids and routes.done_ids() or nil
    scan.backlog = real_backlog
    vault.set_root(nil)
    if offered then
      eq(parsed, 0, "no finished file is read")
      ok(
        vim.list_contains(offered, "lib.nvim/old-one")
          and vim.list_contains(offered, "lib.nvim/old-two")
      )
    end
  end

  -- ── the form's hint line names the keys that are in force ──
  do
    local ui_form = require("tasks_nvim.ui.form")
    eq(
      ui_form.key_hint({
        tick_space = "<Space>",
        tick_enter = "<CR>",
        submit = "<C-s>",
        cancel = "q",
        help = "g?",
      }),
      "<!-- <Space>/<CR> tick, <C-s> submit, q cancel, g? help -->",
      "the defaults read as they always did"
    )
    eq(
      ui_form.key_hint({
        tick_space = false,
        tick_enter = "<CR>",
        submit = "<C-CR>",
        cancel = false,
        help = "g?",
      }),
      "<!-- <CR> tick, <C-CR> submit, g? help -->",
      "a moved key is named, a disabled one is left out"
    )
  end

  -- ── finished ids: one listing per area gives the answers `find_done` gives, one walk per id did ──
  do
    local scan = require("tasks_nvim.scan")
    local lookup_root = F.vault(H)
    local backlog = lookup_root .. "/lib.nvim/Backlog"
    H.write(backlog .. "/TASKS/2026-09-01_aaa.md", F.text(F.meta("Aaa", "done")))
    H.write(backlog .. "/FEATURES/2026-09-01_bbb/2026-09-01_bbb.md", F.text(F.meta("Bbb", "done")))
    vim.fn.mkdir(backlog .. "/TASKS/2026-09-01_ccc", "p")
    H.write(backlog .. "/notes.md", "no frontmatter at all")
    local lookup = scan.finished_lookup({ root = lookup_root })
    for _, id in ipairs({
      "lib.nvim/aaa",
      "lib.nvim/bbb",
      "lib.nvim/ccc",
      "lib.nvim/zzz",
      "lib.nvim/notes",
      "LIB.NVIM/aaa",
      "nope.nvim/aaa",
      "not-an-id",
    }) do
      eq(
        lookup(id),
        scan.find_done(id, { root = lookup_root }) ~= nil,
        "finished_lookup agrees with find_done for " .. id
      )
    end
    ok(
      lookup("lib.nvim/aaa") and lookup("lib.nvim/bbb"),
      "task files and folder tasks are finished"
    )
    ok(not lookup("lib.nvim/ccc"), "a bare folder is not")
    -- the list of finished TASKS: documents without frontmatter are no task, a second look is cached
    local listed = assert(scan.backlog("lib.nvim", { root = lookup_root }))
    eq(#listed, 2)
  end

  -- ── a huge title is clipped in the README row ──
  do
    local mutate_row = mutate.readme_row("FEATURES", "2026-01-01_x.md", {
      title = string.rep("T", 5000),
      summary = "",
    }, "2026-01-01")
    ok(#mutate_row < 600, "the row is bounded (" .. #mutate_row .. " bytes)")
  end
end
