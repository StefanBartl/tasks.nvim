-- TESTS/tasks_dash_spec.lua -- the pure half of the task dashboard (plugin_repos/tasks_dash_core.lua):
-- list lines, header and filter chips, the s/p cycles, batch planning, and the batch apply against a
-- fixture vault (one index regeneration per touched area, failures do not stop the batch).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local core = require("tasks_nvim.ui.dash_core")
  local index = require("tasks_nvim.index")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local TODAY = F.TODAY

  ---@param status string
  ---@param extra? table[]
  ---@return table[]
  local function meta(title, status, extra)
    local m = F.meta(title, status, extra)
    m[#m + 1] = { "created", "2026-09-01" }
    m[#m + 1] = { "updated", "2026-09-02" }
    return m
  end

  local root = F.vault(H)
  local function add(area, slug, title, status, extra)
    return F.task(H, root, area, slug, meta(title, status, extra))
  end

  -- ── cycles ──────────────────────────────────────────────────────────────
  eq(core.cycle_status("doing"), "decision")
  eq(core.cycle_status("decision"), "blocked")
  eq(core.cycle_status("blocked"), "open")
  eq(core.cycle_status("open"), "parked")
  eq(core.cycle_status("parked"), "doing", "the status cycle wraps around")
  eq(core.cycle_status(nil), "doing", "no status starts at the first")
  eq(core.cycle_status("wip"), "doing", "an unknown word starts at the first")
  eq(core.cycle_status("done"), "doing", "done is not part of the open cycle")
  for _, s in ipairs(model.OPEN_STATUSES) do
    ok(model.is_open_status(core.cycle_status(s)), "every step is an open status")
  end

  eq(core.cycle_prio(nil), 1)
  eq(core.cycle_prio(1), 2)
  eq(core.cycle_prio(2), 3)
  eq(core.cycle_prio(3), nil, "past prio 3 the key is removed")
  eq(core.cycle_prio(9), 1, "an out-of-range value restarts")

  -- ── list lines ──────────────────────────────────────────────────────────
  local function task(over)
    return vim.tbl_extend("force", {
      id = "lib.nvim/a",
      area = "lib.nvim",
      slug = "a",
      title = "A title",
      status = "open",
      tags = {},
      blocked_by = {},
    }, over)
  end
  local sample = {
    task({ prio = 1, status = "doing", effort = "M", title = "First" }),
    task({
      id = "cascade.nvim/b",
      area = "cascade.nvim",
      status = "blocked",
      blocked_by = { "lib.nvim/a" },
    }),
    task({
      id = "x/c",
      area = "x",
      status = "decision",
      effort = "0.5d",
      blocked_by = { "a/b", "a/c" },
    }),
  }
  local w = core.widths(sample)
  eq(w.area, 12, "the longest area name")
  eq(w.effort, 4, "the longest effort")
  eq(w.status, 8, "wide enough for 'decision'")
  eq(core.line(sample[1], w), "P1 doing    M    lib.nvim     First")
  eq(
    core.line(sample[2], w),
    "-- blocked  -    cascade.nvim A title  \226\134\144 lib.nvim/a",
    "no prio shows --, no effort shows -, the blocker is hinted"
  )
  has(core.line(sample[3], w), "\226\134\144 a/b (+1)", "more than one blocker is counted")
  local parts = core.parts(sample[1], w)
  eq(parts[1], { "P1", "DiagnosticError" })
  eq(parts[3][2], "DiagnosticInfo", "doing is highlighted")
  eq(core.parts(sample[2], w)[3][2], "DiagnosticError", "blocked is highlighted")
  eq(core.parts(sample[3], w)[3][2], "DiagnosticWarn", "decision is highlighted")
  eq(core.parts(task({ status = "open" }), w)[3][2], "Normal")
  eq(core.parts(task({ status = "parked" }), w)[3][2], "Comment")
  eq(core.parts(task({ prio = 2 }), w)[1][2], "DiagnosticWarn")
  eq(core.parts(task({}), w)[1], { "--", "Comment" })
  has(core.search_text(task({ prio = 2, tags = { "ui", "x" }, kind = "bug" })), "P2")
  has(core.search_text(task({ tags = { "ui", "x" } })), "ui x")
  has(core.search_text(task({})), "lib.nvim/a", "the id is searchable")

  -- ── header, chips, filter state ─────────────────────────────────────────
  eq(core.counts(sample), { open = 3, decision = 1, blocked = 2 })
  eq(core.header(sample, {}, nil), "Tasks \194\183 3 open \194\183 1 decision \194\183 2 blocked")
  eq(core.chips({}), {})
  eq(core.chips(nil), {})
  ok(core.filter_is_empty({}))
  ok(core.filter_is_empty({ today = "2026-10-03" }), "today is no chip")
  eq(
    core.chips({
      status = { "doing", "open" },
      prio_max = 2,
      kind = { "bug" },
      tag = { "ui" },
      stale = 30,
      blocked = true,
    }),
    { "status: doing,open", "prio: <=2", "kind: bug", "tag: ui", "stale: >=30d", "blocked" }
  )
  eq(core.chips({ prio = { 1, 3 } }), { "prio: 1,3" })
  eq(
    core.header(sample, { status = { "open" }, prio_max = 2 }, "lib.nvim"),
    "Tasks (lib.nvim) \194\183 3 open \194\183 1 decision \194\183 2 blocked  [status: open] [prio: <=2]"
  )

  local f0 = { prio_max = 2, today = "2026-10-03" }
  local f1 = core.set_dim(f0, "status", "doing")
  eq(f1.status, { "doing" })
  eq(f1.prio_max, 2, "other dimensions stay")
  eq(f0.status, nil, "the input filter is not mutated")
  eq(core.set_dim(f1, "status", nil).status, nil, "nil clears a dimension")
  local p = core.set_dim(f0, "prio", "3")
  eq(p.prio, { 3 })
  eq(p.prio_max, nil, "a plain prio replaces the <= form")
  local pm = core.set_dim(p, "prio", "<=1")
  eq(pm.prio_max, 1)
  eq(pm.prio, nil, "the <= form replaces a plain prio")
  eq(core.set_dim(pm, "prio", nil).prio_max, nil)
  eq(core.set_dim({}, "kind", "bug").kind, { "bug" })
  eq(core.set_dim({}, "tag", "ui").tag, { "ui" })
  eq(core.set_dim({}, "blocked", true).blocked, true)
  eq(core.set_dim({ blocked = true }, "blocked", nil).blocked, nil)
  eq(
    core.set_dim({ status = { "open" } }, "nonsense", "x"),
    { status = { "open" } },
    "unknown dim: unchanged"
  )

  eq(core.dim_choices("status", {}), model.OPEN_STATUSES)
  eq(core.dim_choices("prio", {}), { "1", "2", "3", "<=2" })
  eq(core.dim_choices("kind", {}), model.KINDS)
  eq(
    core.dim_choices("tag", { task({ tags = { "b", "a" } }), task({ tags = { "a", "c" } }) }),
    { "a", "b", "c" },
    "tags: distinct and sorted"
  )
  eq(core.dim_choices("blocked", {}), {})

  -- the stored form round-trips through the real filter parser
  local full = {
    status = { "doing", "open" },
    prio_max = 2,
    kind = { "bug" },
    tag = { "ui" },
    stale = 30,
    blocked = true,
  }
  local opts = core.filter_to_options(full)
  eq(
    opts,
    { status = "doing,open", prio = "<=2", kind = "bug", tag = "ui", stale = 30, blocked = true }
  )
  eq(vim.json.decode(vim.json.encode(opts)), opts, "the stored form survives JSON")
  local back = core.filter_from_stored(vim.json.decode(vim.json.encode(opts)))
  eq(core.chips(back), core.chips(full))
  eq(core.filter_from_stored({ prio = "1,3" }).prio, { 1, 3 })
  eq(
    core.filter_from_stored({ status = "nonsense" }),
    {},
    "a word that no longer parses gives an empty filter"
  )
  eq(core.filter_from_stored(nil), {})
  eq(core.filter_from_stored("x"), {})
  eq(core.filter_to_options({}), {})

  -- ── load (fixture) ──────────────────────────────────────────────────────
  add(
    "lib.nvim",
    "alpha",
    "Alpha",
    "open",
    { { "prio", "2" }, { "kind", "task" }, { "tags", "[ui]" } }
  )
  add("lib.nvim", "beta", "Beta", "doing", { { "prio", "1" }, { "kind", "feature" } })
  add("lib.nvim", "gamma", "Gamma", "parked", { { "kind", "bug" } })
  add("cascade.nvim", "delta", "Delta", "decision", { { "prio", "3" }, { "tags", "[ui, x]" } })
  add("cascade.nvim", "eps", "Eps", "wip") -- unknown status: not listed
  add("cascade.nvim", "old", "Old", "done") -- done in roadmap: not listed

  local all = assert(core.load({ root = root }))
  eq(
    vim.tbl_map(function(t)
      return t.id
    end, all.tasks),
    { "lib.nvim/beta", "cascade.nvim/delta", "lib.nvim/alpha", "lib.nvim/gamma" },
    "open tasks, sorted like :MyPlugins tasks"
  )
  eq(all.open, 4)
  eq(all.skipped, 2, "unknown and done are counted as skipped")
  local one = assert(core.load({ root = root, area = "cascade.nvim" }))
  eq(#one.tasks, 1)
  local filtered = assert(core.load({ root = root, filter = { tag = { "ui" } } }))
  eq(#filtered.tasks, 2)
  eq(filtered.open, 4, "open counts the tasks before the filter")
  local none, nerr = core.load({ root = root, area = "bad name" })
  eq(none, nil)
  ok(nerr, "an invalid area is an error, not a raise")

  -- ── plan_cycle ──────────────────────────────────────────────────────────
  local by_id = {}
  for _, t in ipairs(all.tasks) do
    by_id[t.id] = t
  end
  local plan = core.plan_cycle(
    { by_id["lib.nvim/beta"], by_id["lib.nvim/alpha"], by_id["lib.nvim/gamma"] },
    "status"
  )
  eq(#plan, 3)
  eq(plan[1], {
    id = "lib.nvim/beta",
    field = "status",
    from = "doing",
    to = "decision",
    patch = { status = "decision" },
  })
  eq(plan[2].to, "parked", "each task advances from its own value")
  eq(plan[3].to, "doing")
  local pplan = core.plan_cycle(
    { by_id["lib.nvim/beta"], by_id["lib.nvim/gamma"], by_id["cascade.nvim/delta"] },
    "prio"
  )
  eq(pplan[1].to, 2)
  eq(pplan[2].to, 1, "no prio -> 1")
  eq(pplan[2].patch, { prio = 1 })
  eq(pplan[3].to, nil, "prio 3 -> removed")
  eq(pplan[3].patch, { prio = mutate.REMOVE })
  eq(core.plan_cycle({}, "status"), {})

  -- ── apply_set: one batch, one index write per touched area ──────────────
  local calls = {}
  local orig_write_area = index.write_area
  index.write_area = function(area, o)
    calls[#calls + 1] = area
    return orig_write_area(area, o)
  end
  local function restore()
    index.write_area = orig_write_area
  end

  local ok_run, err = pcall(function()
    local batch = core.plan_cycle(
      { by_id["lib.nvim/beta"], by_id["lib.nvim/alpha"], by_id["cascade.nvim/delta"] },
      "status"
    )
    batch[#batch + 1] = { id = "lib.nvim/ghost", field = "status", patch = { status = "open" } }
    batch[#batch + 1] = { id = "lib.nvim/gamma", field = "status", patch = { status = "parked" } } -- already parked
    local res = core.apply_set(batch, { root = root, today = TODAY })
    eq(#res.changed, 3)
    eq(res.unchanged, { "lib.nvim/gamma" })
    eq(#res.failed, 1)
    eq(res.failed[1].id, "lib.nvim/ghost")
    has(res.failed[1].err, "no such")
    eq(res.areas, { "cascade.nvim", "lib.nvim" }, "touched areas, sorted, once each")
    eq(calls, { "cascade.nvim", "lib.nvim" }, "ONE index write per touched area, not one per task")
    eq(res.index_errors, {})

    local beta = scan.find("lib.nvim/beta", { root = root })
    eq(beta.status, "decision")
    eq(beta.updated, TODAY, "updated is set by the write")
    eq(scan.find("lib.nvim/alpha", { root = root }).status, "parked")
    eq(scan.find("cascade.nvim/delta", { root = root }).status, "blocked")
    eq(
      scan.find("lib.nvim/gamma", { root = root }).updated,
      "2026-09-02",
      "an unchanged task keeps its date"
    )
    ok(H.exists(root .. "/lib.nvim/ROADMAP/TASKS.md"))
    ok(H.exists(root .. "/cascade.nvim/ROADMAP/TASKS.md"))
    has(H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"), "Beta")

    local level, text = core.describe_set("status", res)
    eq(level, "warn", "a failure among successes is a warning")
    has(text, "status: 3 changed, 1 unchanged, 1 failed (2 indexes regenerated)")
    has(text, "lib.nvim/ghost")
    eq(
      select(
        1,
        core.describe_set("status", {
          changed = {},
          unchanged = {},
          failed = { { id = "x", err = "e" } },
          areas = {},
          index_errors = {},
        })
      ),
      "error"
    )
    eq(
      select(
        2,
        core.describe_set(
          "prio",
          { changed = { {} }, unchanged = {}, failed = {}, areas = { "a" }, index_errors = {} }
        )
      ),
      "prio: 1 changed, 0 unchanged, 0 failed (1 index regenerated)"
    )
    eq(
      select(
        1,
        core.describe_set(
          "prio",
          { changed = { {} }, unchanged = {}, failed = {}, areas = { "a" }, index_errors = {} }
        )
      ),
      "info"
    )

    -- prio: 3 -> key removed from the file, 1 -> set
    calls = {}
    local prio_res = core.apply_set(
      core.plan_cycle({
        scan.find("cascade.nvim/delta", { root = root }),
        scan.find("lib.nvim/gamma", { root = root }),
      }, "prio"),
      { root = root, today = TODAY }
    )
    eq(#prio_res.changed, 2)
    lacks(
      H.read(root .. "/cascade.nvim/ROADMAP/tasks/delta.md"),
      "prio:",
      "prio 3 -> the key is gone"
    )
    has(H.read(root .. "/lib.nvim/ROADMAP/tasks/gamma.md"), "prio: 1")
    eq(calls, { "cascade.nvim", "lib.nvim" })

    -- an empty batch writes nothing and calls nothing
    calls = {}
    local empty = core.apply_set({}, { root = root })
    eq(#empty.changed + #empty.failed + #empty.unchanged, 0)
    eq(calls, {})

    -- ── apply_done: batch over two tasks of one area, index once ──────────
    add("lib.nvim", "fin-one", "Fin one", "open", { { "kind", "task" } })
    add("lib.nvim", "fin-two", "Fin two", "doing", { { "kind", "feature" } })
    add("cascade.nvim", "fin-three", "Fin three", "open", { { "kind", "bug" } })
    calls = {}
    local done = core.apply_done(
      { "lib.nvim/fin-one", "lib.nvim/fin-two", "cascade.nvim/fin-three", "lib.nvim/nope" },
      { root = root, today = TODAY, date = TODAY }
    )
    eq(#done.done, 3)
    eq(#done.failed, 1)
    eq(done.failed[1].id, "lib.nvim/nope")
    eq(done.areas, { "cascade.nvim", "lib.nvim" })
    eq(calls, { "cascade.nvim", "lib.nvim" }, "ONE index write per area for a done batch")
    ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/fin-one.md"), "the file moved")
    ok(H.exists(root .. "/lib.nvim/Backlog/TASKS/" .. TODAY .. "_fin-one.md"))
    ok(H.exists(root .. "/lib.nvim/Backlog/FEATURES/" .. TODAY .. "_fin-two.md"))
    ok(H.exists(root .. "/cascade.nvim/Backlog/TASKS/" .. TODAY .. "_fin-three.md"))
    local readme = H.read(root .. "/lib.nvim/Backlog/README.md")
    has(readme, "fin-one")
    has(readme, "fin-two")
    lacks(
      H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
      "Fin one",
      "the index no longer lists finished tasks"
    )
    eq(done.done[1].from, root .. "/lib.nvim/ROADMAP/tasks/fin-one.md")
    eq(done.done[1].to, root .. "/lib.nvim/Backlog/TASKS/" .. TODAY .. "_fin-one.md")

    local again = core.apply_done(
      { "lib.nvim/fin-one" },
      { root = root, today = TODAY, date = TODAY }
    )
    eq(again.already, { "lib.nvim/fin-one" }, "a second run changes nothing")
    eq(#again.done, 0)
    eq(again.areas, {})

    local dlevel, dtext = core.describe_done(done)
    eq(dlevel, "warn")
    has(dtext, "done: 3 finished, 0 already finished, 1 failed (2 indexes regenerated)")
    has(dtext, "lib.nvim/nope")
    eq(select(1, core.describe_done(again)), "info")
    eq(
      select(
        1,
        core.describe_done({
          done = {},
          already = {},
          failed = { { id = "a", err = "b" } },
          areas = {},
          index_errors = {},
        })
      ),
      "error"
    )
  end)
  restore()
  if not ok_run then
    error(err, 0)
  end

  -- ── refresh: signature, finding the cursor and marks again ──────────────
  local sig_root = F.vault(H)
  local function sig_add(slug, status)
    return F.task(H, sig_root, "lib.nvim", slug, meta("Task " .. slug, status, {}))
  end
  local sig_a, sig_b = sig_add("a", "open"), sig_add("b", "doing")
  local function sig_load()
    return assert(core.load({ root = sig_root })).tasks
  end
  local sig1 = core.signature(sig_load())
  eq(core.signature(sig_load()), sig1, "the same files give the same signature")
  eq(core.signature({}), "", "an empty list has an empty signature")
  H.write(sig_b, (H.read(sig_b):gsub("status: doing", "status: open")))
  ok(core.signature(sig_load()) ~= sig1, "a status change changes it")
  sig1 = core.signature(sig_load())
  H.write(sig_a, H.read(sig_a) .. "\nA new line in the body.\n")
  vim.uv.fs_utime(sig_a, os.time() + 5, os.time() + 5) -- a clearly later mtime, whatever the clock resolution
  ok(
    core.signature(sig_load()) ~= sig1,
    "a body-only edit changes it too (the preview shows the body)"
  )
  sig1 = core.signature(sig_load())
  sig_add("c", "open")
  ok(core.signature(sig_load()) ~= sig1, "a new task changes it")
  sig1 = core.signature(sig_load())
  os.remove(sig_a)
  ok(core.signature(sig_load()) ~= sig1, "a deleted task changes it")

  local new_ids = { "x/new", "a/one", "b/two", "c/three" }
  eq(core.relocate(new_ids, "b/two", { "c/three", "a/one" }), { cursor = 3, marked = { 2, 4 } })
  eq(
    core.relocate(new_ids, "gone/task", { "a/one", "gone/too" }),
    { cursor = nil, marked = { 2 } },
    "a task that vanished is not restored, the rest is"
  )
  eq(core.relocate(new_ids, nil, {}), { cursor = nil, marked = {} }, "nothing to restore")
  eq(core.relocate({}, "a/one", { "a/one" }), { cursor = nil, marked = {} }, "an empty list")

  -- load: frecency scores order the list on request, `scores` is the test seam
  local fr_root = F.vault(H)
  for _, slug in ipairs({ "one", "two", "three" }) do
    F.task(H, fr_root, "lib.nvim", slug, meta("Task " .. slug, "open", {}))
  end
  local function loaded_ids(o)
    o.root = fr_root
    return vim.tbl_map(function(t)
      return t.id
    end, assert(core.load(o)).tasks)
  end
  eq(loaded_ids({}), { "lib.nvim/one", "lib.nvim/three", "lib.nvim/two" }, "default: by slug")
  eq(
    loaded_ids({ sort = "frecency", scores = { ["lib.nvim/two"] = 2, ["lib.nvim/three"] = 1 } }),
    { "lib.nvim/two", "lib.nvim/three", "lib.nvim/one" },
    "frecency: scored tasks first"
  )
  eq(loaded_ids({ sort = "frecency", scores = {} }), loaded_ids({}), "no scores: the default order")

  -- ── export targets ──────────────────────────────────────────────────────
  eq(#core.EXPORT_CHOICES, 7)
  local labels = {}
  for _, c in ipairs(core.EXPORT_CHOICES) do
    ok(not labels[c.label], "labels are unique")
    labels[c.label] = true
  end
  eq(core.export_target(core.EXPORT_CHOICES[1]), { kind = "buffer" })
  eq(core.export_target(core.EXPORT_CHOICES[3]), { kind = "qf" })
  eq(
    core.export_target(core.EXPORT_CHOICES[4], " /tmp/x.md "),
    { kind = "file", path = "/tmp/x.md" }
  )
  local no_path, perr = core.export_target(core.EXPORT_CHOICES[4], "  ")
  eq(no_path, nil)
  has(perr, "no file path")
  eq(core.EXPORT_CHOICES[5].format, "csv")
  eq(core.export_target(core.EXPORT_CHOICES[7]), { kind = "mdview" })
  eq(core.EXPORT_CHOICES[7].format, "md", "a browser preview is Markdown")
end
