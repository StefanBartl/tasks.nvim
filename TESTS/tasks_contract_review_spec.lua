-- TESTS/tasks_contract_review_spec.lua -- the edges of `estimate`, `plan_for` and `check` that a review found: inputs the
-- documents must refuse by name, a graph with a repeated blocker or cut at the limit, the stale refs of a check, and
-- that the figures of a check agree with its list.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local contract = require("tasks_nvim.contract")
  local uv = vim.uv or vim.loop

  local root = F.vault(H)
  ---@param slug string
  ---@param extra? table[]
  local function add(slug, extra)
    local meta = F.meta(slug, "open")
    for _, pair in ipairs(extra or {}) do
      meta[#meta + 1] = pair
    end
    F.task(H, root, "lib.nvim", slug, meta)
  end

  -- ── estimate: what the engine refuses by name, and the order of the snapshot ──
  add("est-a")
  add("est-b")
  local function estimate(params)
    return contract.estimate(params, { root = root })
  end
  local function refused(params, needle)
    local doc, err = estimate(params)
    eq(doc, nil, vim.inspect(params))
    eq(err.code, "invalid_argument")
    has(err.message, needle)
  end
  local ids = { "lib.nvim/est-a", "lib.nvim/est-b" }
  refused({ ids = ids, assume = { { id = "lib.nvim/est-a" } } }, "needs an effort or a value")
  refused(
    { ids = ids, assume = { { id = "lib.nvim/est-a", effort = "1e3d" } } },
    "is not an effort"
  )
  refused(
    { ids = ids, assume = { { id = "lib.nvim/est-a", effort = "1" .. ("0"):rep(22) .. "d" } } },
    "is not an effort"
  )
  refused(
    { ids = ids, assume = { { id = "lib.nvim/est-a", effort = "1" .. ("0"):rep(320) .. "d" } } },
    "is not an effort"
  )
  refused({ ids = ids, assume = { { id = "lib.nvim/est-a", value = "3" } } }, "is not a value")
  refused({ ids = ids, assume = { { id = { "x" }, value = 3 } } }, "is not one of the tasks")
  local many = {}
  for i = 1, contract.ESTIMATE_MAX_ITEMS + 1 do
    many[i] = "lib.nvim/est-a"
  end
  refused({ ids = many }, "at most")
  local many_assume = {}
  for i = 1, contract.ESTIMATE_MAX_ITEMS + 1 do
    many_assume[i] = { id = "lib.nvim/est-a", value = 2 }
  end
  refused({ ids = ids, assume = many_assume }, "at most")
  -- duplicates are fine: the same task twice counts once, the later entry wins for a field both name
  local dup = estimate({
    ids = { "lib.nvim/est-a", "lib.nvim/est-a" },
    assume = {
      { id = "lib.nvim/est-a", effort = "S" },
      { id = "lib.nvim/est-a", effort = "M", value = 2 },
    },
  })
  eq({ dup.tasks, dup.assumed, dup.n_with_effort, dup.value }, { 1, 1, 1, 2 })
  eq(
    estimate({ ids = ids, assume = { { id = "lib.nvim/est-a", effort = "3650d" } } }).days,
    3650,
    "the limit itself is fine"
  )
  -- the whole vault: the lists of the document agree with the snapshot's estimate, in the same order
  local snap = contract.snapshot({ root = root })
  local all = estimate({})
  eq(all.unestimated, snap.estimate.unestimated, "the same tasks in the same order")
  eq(all.quick_wins, snap.estimate.quick_wins)
  eq(all.roi, snap.estimate.roi)

  -- ── an effort too large for a sum never gets in: not through a file, not through the write door ──
  local api = require("tasks_nvim.api")
  add("huge-file", { { "effort", "1" .. ("0"):rep(22) .. "d" } })
  add("huge-inf", { { "effort", "1" .. ("0"):rep(320) .. "d" } })
  local huge_snapshot = contract.snapshot({ root = root })
  ok(huge_snapshot ~= nil, "a task file with a huge effort does not take the snapshot down")
  ok(estimate({}) ~= nil, "nor the estimate")
  local huge_check = contract.check({}, { root = root })
  local bad_efforts = 0
  for _, f in ipairs(huge_check.findings) do
    if f.code == "bad-effort" and f.id:match("huge") then
      bad_efforts = bad_efforts + 1
    end
  end
  eq(bad_efforts, 2, "the check names both")
  local wrote_text = api.call(
    "ops",
    vim.json.encode({
      ops = {
        { op = "set", id = "lib.nvim/est-a", patch = { effort = "99999999999999999999999d" } },
      },
    }),
    { root = root, today = F.TODAY }
  )
  local wrote = vim.json.decode(wrote_text)
  eq(wrote.results[1].ok, false, "the write door refuses it: " .. vim.inspect(wrote))
  eq(require("tasks_nvim.model").is_effort("3650d"), true)
  eq(require("tasks_nvim.model").is_effort("3651d"), false)
  eq(require("tasks_nvim.model").is_effort("3650.5d"), false)
  eq(require("tasks_nvim.model").is_effort(".5d"), true)

  -- ── plan_for: a repeated blocker is one edge, the cut keeps a graph a client can follow ──
  add("pf-base")
  add("pf-mid", { { "blocked_by", "[lib.nvim/pf-base, lib.nvim/pf-base]" } })
  add("pf-top", { { "blocked_by", "[lib.nvim/pf-mid]" } })
  local function plan_for(params)
    return contract.plan_for(params, { root = root })
  end
  local top = plan_for({ id = "lib.nvim/pf-top" })
  eq(top.total, 3)
  eq(#top.edges, 2, "pf-base -> pf-mid once, pf-mid -> pf-top once: " .. vim.inspect(top.edges))
  local unlocks = plan_for({ id = "lib.nvim/pf-base", direction = "unlocks" })
  eq(
    vim.tbl_map(function(n)
      return { n.id, n.distance }
    end, unlocks.nodes),
    { { "lib.nvim/pf-base", 0 }, { "lib.nvim/pf-mid", 1 }, { "lib.nvim/pf-top", 2 } },
    "by distance from the task"
  )
  eq(#unlocks.edges, 2)
  -- cut at the limit: `total` is the whole, every edge has both ends among the nodes, a cut cycle is not named
  local limit = contract.PLAN_FOR_MAX_NODES
  contract.PLAN_FOR_MAX_NODES = 2
  local cut = plan_for({ id = "lib.nvim/pf-top" })
  contract.PLAN_FOR_MAX_NODES = limit
  eq({ cut.total, #cut.nodes, cut.truncated }, { 3, 2, true })
  local have = {}
  for _, n in ipairs(cut.nodes) do
    have[n.id] = true
  end
  for _, e in ipairs(cut.edges) do
    ok(have[e.from] and have[e.to], "an edge with both ends among the nodes: " .. vim.inspect(e))
  end
  add("pf-cyc-a", { { "blocked_by", "[lib.nvim/pf-cyc-b]" } })
  add("pf-cyc-b", { { "blocked_by", "[lib.nvim/pf-cyc-a]" } })
  add("pf-cyc-top", { { "blocked_by", "[lib.nvim/pf-cyc-a]" } })
  local cyc = plan_for({ id = "lib.nvim/pf-cyc-top" })
  eq(#cyc.cycles, 1)
  table.sort(cyc.cycles[1])
  eq(cyc.cycles[1], { "lib.nvim/pf-cyc-a", "lib.nvim/pf-cyc-b" })
  contract.PLAN_FOR_MAX_NODES = 2
  local cyc_cut = plan_for({ id = "lib.nvim/pf-cyc-top" })
  contract.PLAN_FOR_MAX_NODES = limit
  eq(cyc_cut.cycles, {}, "a cycle that is cut is not named: its ids would have no node")

  -- ── check: the figures agree with the list, the stale refs are found, and no path of this machine is told ──
  local top_dir = H.tmpdir()
  local repos = top_dir .. "/repos"
  H.write(repos .. "/lib.nvim/notes.txt", "n\n")
  H.write(repos .. "/lib.nvim/abs.txt", "n\n")
  local when = os.time({ year = 2026, month = 10, day = 5, hour = 12 })
  uv.fs_utime(repos .. "/lib.nvim/notes.txt", when, when)
  uv.fs_utime(repos .. "/lib.nvim/abs.txt", when, when)
  -- two tasks with an error each: the errors must come before the warning, and by file
  add("rbroken-b", { { "prio", "9" } })
  add("rbroken-a", { { "prio", "9" } })
  add("stale-demo", {
    { "created", "2026-09-15" },
    { "updated", "2026-09-15" },
    { "refs", "[notes.txt, " .. repos .. "/lib.nvim/abs.txt]" },
  })
  local plain = contract.check({}, { root = root })
  local with_refs = contract.check(
    { stale = "refs" },
    { root = root, ref_opts = { repo_bases = { repos } } }
  )
  eq(with_refs.stale, "refs")
  local stale_findings = {}
  for _, f in ipairs(with_refs.findings) do
    if f.code == "stale-refs" then
      stale_findings[#stale_findings + 1] = f
    end
  end
  eq(#stale_findings, 1, vim.inspect(stale_findings))
  eq(
    { stale_findings[1].id, stale_findings[1].severity, stale_findings[1].file },
    { "lib.nvim/stale-demo", "warn", "lib.nvim/ROADMAP/tasks/stale-demo.md" }
  )
  has(stale_findings[1].message, "notes.txt")
  has(
    stale_findings[1].message,
    "<external>/abs.txt",
    "an absolute ref is named by its last part only"
  )
  lacks(stale_findings[1].message, top_dir, "no path of this machine in the message")
  eq(with_refs.warnings, plain.warnings + 1, "the figures count the stale refs too")
  eq(with_refs.errors, plain.errors)
  eq(with_refs.total, plain.total + 1)
  local errors, warnings = 0, 0
  for _, f in ipairs(with_refs.findings) do
    if f.severity == "error" then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end
  eq(
    { errors, warnings },
    { with_refs.errors, with_refs.warnings },
    "the figures are those of the list"
  )
  local told = {}
  for _, note in ipairs(with_refs.notes) do
    ok(not told[note], "a note once: " .. note)
    told[note] = true
    lacks(note, top_dir, "no path of this machine in a note")
    lacks(note, repos, "no folder in a note")
  end
  -- errors first, then by file: a cut at the limit drops the least important
  local error_files = {}
  for _, f in ipairs(with_refs.findings) do
    if f.severity == "error" and f.code == "bad-prio" then
      error_files[#error_files + 1] = f.file
    end
  end
  eq(#error_files, 2, "two broken tasks to order")
  ok(error_files[1] < error_files[2], "by file inside the errors: " .. vim.inspect(error_files))
  local seen_warn = false
  for _, f in ipairs(with_refs.findings) do
    if f.severity == "warn" then
      seen_warn = true
    else
      ok(not seen_warn, "an error after a warning: " .. f.code)
    end
  end
end
