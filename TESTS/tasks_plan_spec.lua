-- TESTS/tasks_plan_spec.lua -- tasks_nvim.plan: readiness, scopes, stages, leverage, effective prio, critical path
-- and cycles, on in-memory tasks (the engine reads no file here).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local model = require("tasks_nvim.model")
  local plan = require("tasks_nvim.plan")

  ---@param id string  `<area>/<slug>`
  ---@param opts? { status?: string, prio?: string, effort?: string, blocked_by?: string[] }
  ---@return Tasks.Task
  local function T(id, opts)
    opts = opts or {}
    local area, slug = id:match("^([^/]+)/(.+)$")
    local meta = { { "title", slug }, { "status", opts.status or "open" } }
    if opts.prio then
      meta[#meta + 1] = { "prio", opts.prio }
    end
    if opts.effort then
      meta[#meta + 1] = { "effort", opts.effort }
    end
    if opts.blocked_by then
      meta[#meta + 1] = { "blocked_by", "[" .. table.concat(opts.blocked_by, ", ") .. "]" }
    end
    local lines = { "---" }
    for _, kv in ipairs(meta) do
      lines[#lines + 1] = kv[1] .. ": " .. kv[2]
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = "text"
    return model.parse_text(
      table.concat(lines, "\n") .. "\n",
      { path = "/v/" .. area .. "/ROADMAP/tasks/" .. slug .. ".md", area = area }
    )
  end

  ---@param tasks Tasks.Task[]
  ---@param done? string[]
  ---@return Tasks.PlanIndex
  local function index_of(tasks, done)
    local set = {}
    for _, id in ipairs(done or {}) do
      set[id] = true
    end
    return plan.index(tasks, set)
  end

  -- ── readiness: the one definition ──
  local all = {
    T("a/free"),
    T("a/doing", { status = "doing" }),
    T("a/decide", { status = "decision" }),
    T("a/waits", { blocked_by = { "a/free" } }),
    T("a/freed", { status = "blocked" }),
    T("a/parked", { status = "parked" }),
    T("a/on-parked", { blocked_by = { "a/parked" } }),
    T("a/after-done", { blocked_by = { "a/gone-done" } }),
    T("a/after-ghost", { blocked_by = { "a/ghost" } }),
    T("a/cross", { blocked_by = { "b/other" } }),
    T("b/other"),
  }
  local idx = index_of(all, { "a/gone-done" })
  local function state(id)
    return (plan.classify(idx.open[id], idx))
  end
  eq(state("a/free"), "ready")
  eq(state("a/doing"), "ready")
  eq(state("a/decide"), "decision")
  eq(state("a/waits"), "waiting", "an open blocker")
  eq(state("a/freed"), "freed", "status blocked but nothing blocks it any more")
  eq(state("a/parked"), "parked")
  eq(state("a/on-parked"), "stuck", "a parked blocker waits without end")
  eq(state("a/after-done"), "ready", "a finished blocker counts as met")
  eq(state("a/after-ghost"), "stuck", "an unknown blocker is not met")
  eq(state("a/cross"), "waiting", "a blocker in another area counts")
  ok(plan.ready(idx.open["a/free"], idx))
  ok(
    plan.ready(idx.open["a/decide"], idx),
    "a decision is ready: it waits for the human, not for a task"
  )
  ok(not plan.ready(idx.open["a/waits"], idx))
  ok(not plan.ready(idx.open["a/freed"], idx))
  ok(not plan.ready(idx.open["a/parked"], idx))

  -- ── scope_for: the task and everything before it, across areas ──
  local chain = {
    T("x/c", { blocked_by = { "x/b", "y/z" } }),
    T("x/b", { blocked_by = { "x/a" } }),
    T("x/a"),
    T("y/z", { blocked_by = { "y/zz" } }),
    T("y/zz"),
    T("x/unrelated"),
  }
  local cidx = index_of(chain)
  local scope = plan.scope_for(cidx, "x/c")
  local ids = {}
  for _, t in ipairs(scope) do
    ids[#ids + 1] = t.id
  end
  table.sort(ids)
  eq(
    ids,
    { "x/a", "x/b", "x/c", "y/z", "y/zz" },
    "the transitive closure of the blockers, cross-area"
  )
  eq(plan.scope_for(cidx, "x/missing"), nil)

  -- ── stages, leverage, order: a diamond ──
  --   a -> b -> d        d waits on b and c, both wait on a
  --   a -> c -> d        e is free, f waits on e
  local diamond = {
    T("p/a", { effort = "S" }),
    T("p/b", { blocked_by = { "p/a" }, effort = "M" }),
    T("p/c", { blocked_by = { "p/a" }, effort = "S" }),
    T("p/d", { blocked_by = { "p/b", "p/c" }, effort = "L" }),
    T("p/e", { effort = "XS" }),
    T("p/f", { blocked_by = { "p/e" } }),
  }
  local p = plan.build(diamond, index_of(diamond))
  eq(p.stages[1], { "p/a", "p/e" }, "stage 0: nothing blocks them; a has more leverage than e")
  eq(
    p.stages[2],
    { "p/c", "p/b", "p/f" },
    "stage 1: leverage first, then the smaller effort (c before b)"
  )
  eq(p.stages[3], { "p/d" })
  eq(p.nodes["p/d"].stage, 2, "every task sits in the earliest possible stage")
  eq(p.nodes["p/a"].leverage, 3, "b, c and d depend on a")
  eq(p.nodes["p/e"].leverage, 1)
  eq(p.nodes["p/d"].leverage, 0)
  eq(p.ready, { "p/a", "p/e" }, "ready: nothing open blocks them")
  eq(p.cycles, {})
  eq(p.critical.path, { "p/a", "p/b", "p/d" }, "the longest weighted chain: a(0.5) + b(1) + d(3)")
  eq(p.critical.days, 4.5)
  eq(p.critical.unknown, 0)

  -- a task without effort counts as one day on the path and is reported
  local unknown_effort = {
    T("u/a"),
    T("u/b", { blocked_by = { "u/a" }, effort = "M" }),
  }
  local up = plan.build(unknown_effort, index_of(unknown_effort))
  eq(up.critical.days, 2, "unknown effort counts as one day")
  eq(up.critical.unknown, 1, "and is counted as unknown")

  -- ── effective prio: a prio 3 task that blocks a prio 1 task is prio 1 in the plan ──
  local inv = {
    T("i/low", { prio = "3" }),
    T("i/high", { prio = "1", blocked_by = { "i/low" } }),
    T("i/plain", { prio = "2" }),
    T("i/none"),
  }
  local ip = plan.build(inv, index_of(inv))
  eq(ip.nodes["i/low"].eff_prio, 1)
  eq(ip.nodes["i/low"].inversion, { from = 3, to = 1, because = "i/high" })
  eq(ip.nodes["i/high"].inversion, nil, "no inversion where nothing better depends on it")
  eq(ip.nodes["i/plain"].eff_prio, 2)
  eq(ip.nodes["i/none"].eff_prio, nil, "no prio anywhere: none")
  eq(ip.stages[1][1], "i/low", "the effective prio orders the stage")
  eq(inv[1].prio, 3, "the written prio is never touched")

  -- ── cycles: reported, taken out, the rest is still ordered ──
  local cyc = {
    T("c/one", { blocked_by = { "c/two" } }),
    T("c/two", { blocked_by = { "c/one" } }),
    T("c/behind", { blocked_by = { "c/two" } }),
    T("c/self", { blocked_by = { "c/self" } }),
    T("c/fine"),
    T("c/after-fine", { blocked_by = { "c/fine" } }),
  }
  local cp = plan.build(cyc, index_of(cyc))
  eq(
    cp.cycles,
    { { "c/one", "c/two" }, { "c/self" } },
    "members named; a task that blocks itself is a cycle"
  )
  ok(cp.nodes["c/one"].in_cycle)
  eq(cp.nodes["c/one"].state, "stuck")
  eq(cp.nodes["c/behind"].state, "stuck", "behind a cycle: waits without end")
  ok(cp.nodes["c/behind"].behind_cycle)
  eq(cp.nodes["c/behind"].stage, nil, "and has no stage of its own")
  eq(cp.nodes["c/fine"].state, "ready")
  eq(cp.stages[1], { "c/fine" }, "the rest is still ordered")
  eq(cp.stages[2], { "c/after-fine" })
  eq(cp.nodes["c/one"].stage, nil, "a cycle member is in no stage")
  local codes = {}
  for _, w in ipairs(cp.warnings) do
    codes[#codes + 1] = w.code
  end
  ok(vim.tbl_contains(codes, "blocked-by-cycle"))
  has(cp.warnings[1].msg, "c/one -> c/two")

  -- ── external blockers: outside the scope but still open ──
  local scope_part = { diamond[2], diamond[3] } -- b and c, without a
  local ep = plan.build(scope_part, index_of(diamond))
  eq(ep.nodes["p/b"].external, { "p/a" }, "an open blocker outside the scope is external")
  eq(ep.nodes["p/b"].state, "waiting", "and still keeps the task from being ready")
  eq(ep.nodes["p/b"].stage, 0, "it takes no part in the stages of the scope")
  eq(ep.ready, {})

  -- ── parked and unknown blockers are warned about ──
  local pk = {
    T("k/parked", { status = "parked" }),
    T("k/waits", { blocked_by = { "k/parked" } }),
    T("k/ghost", { blocked_by = { "k/nowhere" } }),
  }
  local kp = plan.build(pk, index_of(pk))
  local kinds = {}
  for _, w in ipairs(kp.warnings) do
    kinds[w.code] = (kinds[w.code] or 0) + 1
  end
  eq(kinds["blocked-by-parked"], 1)
  eq(kinds["unknown-blocker"], 1)

  -- ── decisions by leverage ──
  local dec = {
    T("d/small", { status = "decision" }),
    T("d/big", { status = "decision" }),
    T("d/w1", { blocked_by = { "d/big" } }),
    T("d/w2", { blocked_by = { "d/big" } }),
    T("d/w3", { blocked_by = { "d/small" } }),
  }
  local dp = plan.build(dec, index_of(dec))
  eq(dp.decisions, { "d/big", "d/small" }, "the decision that unlocks most comes first")
  eq(dp.nodes["d/big"].leverage, 2)

  -- ── a long chain must not overflow the stack ──
  local long = {}
  local n = 5000
  for i = 1, n do
    long[#long + 1] = T("l/t" .. i, { blocked_by = i > 1 and { "l/t" .. (i - 1) } or nil })
  end
  local lp = plan.build(long, index_of(long))
  eq(#lp.stages, n, "one stage per link")
  eq(lp.nodes["l/t1"].leverage, n - 1)
  eq(#lp.critical.path, n)
  -- and a long ring is one cycle, not a crash
  long[1] = T("l/t1", { blocked_by = { "l/t" .. n } })
  lp = plan.build(long, index_of(long))
  eq(#lp.cycles, 1)
  eq(#lp.cycles[1], n)

  -- ── an empty scope ──
  local empty = plan.build({}, index_of({}))
  eq(empty.ids, {})
  eq(empty.critical.days, 0)
end
