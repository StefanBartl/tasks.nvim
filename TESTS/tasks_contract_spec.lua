-- TESTS/tasks_contract_spec.lua -- the read contract `tasks-export/1`: documents, the dispatcher, golden files.
--
-- The golden files (TESTS/golden/tasks-export-1/*.json) are what a client of the contract can rely on byte for byte.
-- A change of a document is a change of the contract: look at the diff, then regenerate them on purpose with
--   nvim --headless -u NONE -l TESTS/golden/regenerate.lua

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local api = require("tasks_nvim.api")
  local contract = require("tasks_nvim.contract")
  local json = require("tasks_nvim.json")

  local root = fixture.build(H)
  local golden_files = dofile(here .. "/contract_golden.lua")

  -- A fixed clock and engine: the bytes are the same on every machine and run.
  local real_clock, real_engine = contract.clock, contract.engine_info
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  contract.engine_info = function()
    return { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" }
  end

  ---@param name string
  ---@param params? table
  ---@param opts? table
  ---@return table doc
  ---@return string text
  ---@return string|nil code
  local function call(name, params, opts)
    local text, code = api.call(
      name,
      params and vim.json.encode({ params = params }) or nil,
      vim.tbl_extend("force", { root = root }, opts or {})
    )
    return vim.json.decode(text), text, code
  end

  ---@param name string  # a case of `contract_golden.lua`
  local function golden(name)
    local path = golden_files.dir .. "/" .. name .. ".json"
    ok(H.exists(path), "golden file " .. name .. " exists (TESTS/golden/regenerate.lua writes it)")
    eq(
      golden_files.render(root, golden_files.case(name), function()
        return fixture.build(H)
      end),
      H.read(path),
      "golden " .. name
    )
  end

  -- ── hello: what the engine is and can do, without reading a task ──
  local hello, _, code = call("hello")
  eq(code, nil)
  eq({ hello.schema, hello.plugin, hello.kind }, { 1, "tasks.nvim", "tasks.hello" })
  eq(hello.schemas, { 1 })
  eq(hello.vault.id, "vault", "the vault is named by its folder, never by its path")
  eq(hello.engine, { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" })
  -- every method is a capability, plus the features that are no method of their own
  local expected_caps = api.methods()
  for _, feature in ipairs({
    "append_note",
    "eff_prio",
    "etag",
    "if_match",
    "move_area_preview",
    "plan_new",
    "reminders",
    "reopen",
    "reorder",
    "tick_step",
  }) do
    table.insert(expected_caps, feature)
  end
  table.sort(expected_caps)
  eq(
    hello.capabilities,
    expected_caps,
    "capabilities are the methods plus the features: one list, not two"
  )
  eq(hello.limits.list_items, 100)
  eq(hello.enums.status, { "doing", "decision", "blocked", "open", "parked" })
  eq(hello.enums.effort[#hello.enums.effort], "<n>d")
  ok(
    hello.rev == nil and hello.digest == nil,
    "a document that reads no task has no rev and no digest"
  )
  golden("hello")

  -- ── snapshot ──
  local snap, snap_text = call("snapshot")
  eq({ snap.kind, snap.schema }, { "tasks.snapshot", 1 })
  eq(snap.counts.listed, 14)
  eq(snap.counts.unlisted, 2)
  eq(snap.counts.by_status, { blocked = 2, decision = 1, doing = 1, open = 9, parked = 1 })
  eq(#snap.tasks, 14)
  ok(snap.rev:match("^rev:%x%x%x%x%x%x$"), "rev looks like rev:xxxxxx")
  ok(
    snap.digest:match("^sha256:%x+$") and #snap.digest == 7 + 16,
    "digest is sha256: and 16 hex digits"
  )

  ---@param id string
  ---@return table
  local function entry(id)
    for _, t in ipairs(snap.tasks) do
      if t.id == id then
        return t
      end
    end
    error("no task " .. id)
  end

  -- (the priority of a group is `readiness.eff_prio`: tasks_eff_prio_spec.lua holds the rule, cycles included)

  -- every readiness state of the fixture
  local states = {
    ["lib.nvim/alpha"] = "ready",
    ["lib.nvim/alpha-twin"] = "ready",
    ["lib.nvim/beta"] = "waiting",
    ["lib.nvim/gamma"] = "decision",
    ["lib.nvim/delta"] = "parked",
    ["lib.nvim/epsilon"] = "stuck",
    ["lib.nvim/cyc-a"] = "stuck",
    ["lib.nvim/cyc-b"] = "stuck",
    ["cascade.nvim/theta"] = "freed",
    ["cascade.nvim/iota"] = "waiting",
    ["cascade.nvim/zeta"] = "ready",
  }
  for id, state in pairs(states) do
    eq(entry(id).readiness.state, state, id .. " is " .. state)
  end
  eq(entry("lib.nvim/beta").readiness.open_blockers, { "lib.nvim/alpha" })
  ok(
    entry("lib.nvim/cyc-a").readiness.in_cycle and entry("lib.nvim/cyc-b").readiness.in_cycle,
    "cycle members say so"
  )
  eq(snap.plan.cycles, { { "lib.nvim/cyc-a", "lib.nvim/cyc-b" } })
  eq(
    snap.plan.conflict_groups,
    { { file = "docs/shared.md", ids = { "lib.nvim/alpha", "lib.nvim/alpha-twin" }, stage = 0 } }
  )
  eq(snap.plan.summary.tasks, 14)

  -- the tasks come in plan order, and rank says so
  for i, t in ipairs(snap.tasks) do
    eq(t.readiness.rank, i, "rank is the position in plan order")
  end

  -- the fields of one task, as the contract promises them
  local alpha = entry("lib.nvim/alpha")
  eq(alpha.file, "lib.nvim/ROADMAP/tasks/alpha.md", "a file is vault-relative")
  eq(
    { alpha.prio, alpha.effort, alpha.effort_days, alpha.value, alpha.roi },
    { 1, "S", 0.5, 5, 10 }
  )
  eq({ alpha.actor, alpha.actor_written, alpha.kind }, { "cdx", true, "feature" })
  eq(alpha.tags, { "ui", "docs" })
  eq(alpha.steps, { total = 2, ticked = 1, dropped = 1 }, "a dropped step is struck from the count")
  eq(
    alpha.title,
    'Alpha <script>alert(1)</script> & "quotes" \\ slash',
    "a title is data, kept as written"
  )
  ok(alpha.etag:match("^sha256:%x+$") and #alpha.etag == 7 + 16)
  eq(alpha.group, "open|1")
  eq(alpha.valid, true)
  eq(alpha.problems, {})

  -- missing means unknown, never 0
  local gamma = entry("lib.nvim/gamma")
  eq(
    { gamma.effort, gamma.effort_days, gamma.roi },
    { nil, nil, nil },
    "no effort: no days and no roi"
  )
  eq(gamma.value, 2)
  eq(entry("lib.nvim/order-a").order, 1.5, "a fraction of order survives")
  eq(entry("lib.nvim/order-a").title, "Größe 日本 \240\159\152\128", "non-ASCII is kept")

  -- a broken task is still there
  local broken = entry("lib.nvim/broken")
  eq(broken.valid, false)
  ok(#broken.problems >= 2, "the problems are listed")
  eq(
    vim.tbl_map(function(p)
      return p.code
    end, broken.problems),
    { "bad-prio", "bad-effort" }
  )
  eq(
    { broken.prio, broken.effort, broken.effort_days },
    {},
    "a value out of range is not passed on: it is a problem, not a field"
  )

  -- the unlisted
  eq(snap.unlisted, {
    { code = "done-in-roadmap", id = "lib.nvim/done-here", status = "done" },
    { code = "unknown-status", id = "lib.nvim/odd-status", status = "wip" },
  })

  -- the plan file and the finished blocker
  eq(#snap.plans, 1)
  eq(snap.plans[1].id, "lib.nvim/the-plan")
  eq(snap.plans[1].phase_order, { "build", "test" })
  ok(
    entry("cascade.nvim/zeta").plan == "lib.nvim/the-plan"
      and entry("cascade.nvim/zeta").phase == "build"
  )

  -- no path of this machine anywhere
  lacks(snap_text, root, "the vault root appears nowhere")
  lacks(snap_text, vim.fs.normalize(root), "...in either spelling")
  lacks(snap_text, (root:gsub("/", "\\")))
  lacks(snap_text, "/abs/outside", "an absolute refs entry is redacted")
  lacks(snap_text, "C:/Users/someone", "...also a drive path")
  eq(
    alpha.refs,
    { "docs/shared.md", "<external>/secret.md", "<external>/notes.md", "repo@abc1234" }
  )
  ok(not snap_text:find("%a:[/\\]", 1), "no drive path at all in the document")

  -- ── determinism ──
  local _, again = call("snapshot")
  eq(again, snap_text, "the same vault gives the same bytes")
  contract.clock = function()
    return "2030-05-05T05:05:05Z"
  end
  contract.engine_info = function()
    return { version = "9.9.9", git = "abcdef0", nvim = "1.2.3" }
  end
  local later = call("snapshot")
  eq(
    later.digest,
    snap.digest,
    "the digest does not depend on the time or on the build of the engine"
  )
  eq(later.rev, snap.rev)
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  contract.engine_info = function()
    return { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" }
  end

  -- a change of one task file changes its etag, the rev and the digest, and nothing else
  local path = root .. "/lib.nvim/ROADMAP/tasks/gamma.md"
  local original = H.read(path)
  H.write(path, original .. "\nOne more line.\n")
  local changed = call("snapshot")
  ok(changed.rev ~= snap.rev and changed.digest ~= snap.digest, "rev and digest follow the content")
  local etags = {}
  for _, t in ipairs(snap.tasks) do
    etags[t.id] = t.etag
  end
  for _, t in ipairs(changed.tasks) do
    if t.id == "lib.nvim/gamma" then
      ok(t.etag ~= etags[t.id], "the changed task has a new etag")
    else
      eq(t.etag, etags[t.id], t.id .. " keeps its etag")
    end
  end
  H.write(path, original)
  eq(call("snapshot").digest, snap.digest, "back to the old bytes, back to the old digest")

  golden("snapshot")

  -- ── list ──
  local page, _, lcode = call("list", { limit = 5 })
  eq(lcode, nil)
  eq(
    { page.kind, page.total, page.offset, page.limit, #page.items, page.next_offset },
    { "tasks.list", 14, 0, 5, 5, 5 }
  )
  eq(page.items[1].id, snap.tasks[1].id, "a list is in plan order")
  local last = call("list", { limit = 5, offset = 10 })
  eq({ #last.items, last.next_offset }, { 4, nil }, "the last page has no next_offset")
  local doing = call("list", { status = { "doing" } })
  eq({ doing.total, doing.items[1].id }, { 1, "lib.nvim/beta" })
  local in_area = call("list", { area = "cascade.nvim" })
  eq(in_area.total, 4)
  golden("list-page")

  -- ── task ──
  local one = call("task", { id = "lib.nvim/alpha" })
  eq(one.kind, "tasks.task")
  eq(one.task.id, "lib.nvim/alpha")
  has(one.body, "The body of alpha.")
  eq(one.body_truncated, false)
  eq(#one.steps, 3)
  eq(one.steps[1], { n = 1, text = "1. first", ticked = true, dropped = false })
  eq(one.steps[3].dropped, true)
  local limit = contract.LIMITS.body_bytes
  contract.LIMITS.body_bytes = 10
  local cut = call("task", { id = "lib.nvim/alpha" })
  contract.LIMITS.body_bytes = limit
  eq({ #cut.body, cut.body_truncated }, { 10, true }, "a long body is cut and says so")
  golden("task-alpha")

  -- ── bodies ──
  local bodies = call("bodies", { limit = 3, offset = 1 })
  eq(bodies.kind, "tasks.bodies")
  eq({ #bodies.items, bodies.next_offset, bodies.total }, { 3, 4, snap.counts.listed })
  eq(bodies.rev, snap.rev, "the rev of the snapshot: both documents are one state")
  local all_ids = {}
  for _, item in ipairs(call("bodies", { limit = 100 }).items) do
    all_ids[item.id] = item
  end
  has(all_ids["lib.nvim/alpha"].body, "The body of alpha.")
  eq(all_ids["lib.nvim/alpha"].etag, one.task.etag, "the etag is the one of the task")
  local named = call("bodies", { ids = { "lib.nvim/alpha", "nope.nvim/missing" } })
  eq({ #named.items, named.items[1].id, named.next_offset }, { 1, "lib.nvim/alpha", nil })
  local page_bytes = contract.BODIES_PAGE_BYTES
  contract.BODIES_PAGE_BYTES = 30
  local early = call("bodies", { limit = 100 })
  contract.BODIES_PAGE_BYTES = page_bytes
  eq(
    early.next_offset,
    #early.items,
    "a page that holds as many bytes as it may ends early and says where to go on"
  )
  eq(#early.items < early.total, true)
  eq(contract.bodies({ limit = 0 }, { root = root }), nil)
  eq(contract.bodies({ limit = contract.BODIES_MAX_ITEMS + 1 }, { root = root }), nil)
  eq(
    #call("bodies", { limit = contract.BODIES_MAX_ITEMS }).items,
    snap.counts.listed,
    "one page holds the fixture"
  )
  golden("bodies-page")

  -- ── estimate: the figures of some tasks, also with other values assumed (nothing is written) ──
  local all = call("estimate")
  eq(all.kind, "tasks.estimate")
  local from_snap = snap.estimate
  eq(
    { all.tasks, all.days, all.n_with_effort, all.n_without_effort, all.value, all.n_with_value },
    {
      from_snap.tasks,
      from_snap.days,
      from_snap.n_with_effort,
      from_snap.n_without_effort,
      from_snap.value,
      from_snap.n_with_value,
    },
    "without ids and assumptions it is the estimate of the snapshot"
  )
  eq(all.rev, snap.rev, "the rev of the snapshot: both documents are one state")
  ok(all.range.low <= all.days and all.days <= all.range.high, "the sum lies in its range")
  eq(all.assumed, 0)
  local files_before = H.read(root .. "/lib.nvim/ROADMAP/tasks/alpha.md")
  local ids = { "lib.nvim/alpha", "lib.nvim/beta" }
  local plain = call("estimate", { ids = ids })
  eq(plain.tasks, 2)
  local drafted = call("estimate", {
    ids = ids,
    assume = {
      { id = "lib.nvim/alpha", effort = "XL", value = 5 },
      { id = "lib.nvim/beta", effort = "3d" },
    },
  })
  eq(drafted.assumed, 2)
  ok(
    drafted.days > plain.days,
    "an XL and 3d raise the sum: " .. drafted.days .. " vs " .. plain.days
  )
  eq(drafted.n_without_effort, 0, "both have an effort once assumed")
  eq(H.read(root .. "/lib.nvim/ROADMAP/tasks/alpha.md"), files_before, "nothing is written")
  local function refused_estimate(params, needle)
    local doc, _, err_code = call("estimate", params)
    eq({ doc.kind, err_code }, { "tasks.error", "invalid_argument" }, vim.inspect(params))
    has(doc.message, needle)
  end
  refused_estimate({ ids = { "lib.nvim/nope" } }, "is no open task")
  refused_estimate(
    { ids = ids, assume = { { id = "lib.nvim/delta", value = 3 } } },
    "not one of the tasks"
  )
  refused_estimate(
    { ids = ids, assume = { { id = "lib.nvim/alpha", effort = "huge" } } },
    "is not an effort"
  )
  refused_estimate(
    { ids = ids, assume = { { id = "lib.nvim/alpha", value = 6 } } },
    "is not a value"
  )
  refused_estimate(
    { ids = ids, assume = { { id = "lib.nvim/alpha", value = 2.5 } } },
    "is not a value"
  )
  refused_estimate(
    { ids = ids, assume = { { id = "lib.nvim/alpha", colour = "red" } } },
    "unknown field"
  )
  golden("estimate")

  -- ── plan_for: what a task needs, and what waits for it ──
  local needs = call("plan_for", { id = "cascade.nvim/iota" })
  eq(
    { needs.kind, needs.direction, needs.total, needs.truncated },
    { "tasks.planfor", "needs", 2, false }
  )
  eq(needs.rev, snap.rev, "the rev of the snapshot: both documents are one state")
  eq(
    vim.tbl_map(function(n)
      return { n.id, n.distance }
    end, needs.nodes),
    { { "cascade.nvim/iota", 0 }, { "lib.nvim/alpha", 1 } },
    "the task itself first, then what it needs, by distance"
  )
  eq(needs.edges, { { from = "lib.nvim/alpha", to = "cascade.nvim/iota", kind = "blocked_by" } })
  eq(needs.nodes[2].state, "ready", "the state the plan gives the task")
  local unlocks = call("plan_for", { id = "lib.nvim/alpha", direction = "unlocks" })
  eq(unlocks.direction, "unlocks")
  local waiting = {}
  for _, n in ipairs(unlocks.nodes) do
    waiting[#waiting + 1] = n.id
  end
  ok(
    vim.tbl_contains(waiting, "cascade.nvim/iota"),
    "iota waits for alpha: " .. vim.inspect(waiting)
  )
  eq(unlocks.nodes[1].id, "lib.nvim/alpha")
  local alone = call("plan_for", { id = "lib.nvim/alpha-twin" })
  eq({ alone.total, #alone.edges }, { 1, 0 }, "a task that needs nothing is a graph of one")
  local cyc = call("plan_for", { id = "lib.nvim/cyc-a" })
  ok(#cyc.cycles >= 1, "the cycle the task is in is named")
  local function refused_plan_for(params, want, needle)
    local doc, _, got = call("plan_for", params)
    eq({ doc.kind, got }, { "tasks.error", want }, vim.inspect(params))
    has(doc.message, needle)
  end
  refused_plan_for({}, "invalid_argument", "needs the parameter id")
  refused_plan_for({ id = "lib.nvim/nope" }, "not_found", "no such open task")
  refused_plan_for(
    { id = "lib.nvim/alpha", direction = "sideways" },
    "invalid_argument",
    "needs or unlocks"
  )
  golden("planfor")

  -- ── check: the rule check as a document (a client runs it as a job) ──
  local chk = call("check")
  eq(chk.kind, "tasks.check")
  eq(chk.rev, snap.rev, "the rev of the snapshot: both documents are one state")
  local rule_check = require("tasks_nvim.check").run({ root = root })
  eq({ chk.errors, chk.warnings, chk.areas, chk.tasks, chk.total, chk.ok }, {
    rule_check.errors,
    rule_check.warnings,
    rule_check.areas,
    rule_check.tasks,
    #rule_check.findings,
    rule_check.ok,
  }, "the figures of `tasks check`")
  local by_code = {}
  for _, f in ipairs(chk.findings) do
    by_code[f.code .. "|" .. (f.id or "")] = f
    lacks(f.file, ":", "a path relative to the vault: " .. f.file)
    lacks(f.message, root, "no path of this machine in " .. f.code)
  end
  eq(by_code["bad-prio|lib.nvim/broken"].severity, "error")
  eq(by_code["doing-while-blocked|lib.nvim/beta"].severity, "warn")
  eq(by_code["doing-while-blocked|lib.nvim/beta"].file, "lib.nvim/ROADMAP/tasks/beta.md")
  local one_area = call("check", { area = "cascade.nvim" })
  ok(one_area.areas == 1 and one_area.total < chk.total, "one area is a part of the whole")
  local with_refs = call("check", { stale = "refs" })
  eq(with_refs.stale, "refs")
  eq(type(with_refs.notes), "table")
  ok(with_refs.total >= chk.total, "the stale refs only add findings")
  local function refused_check(params, want, needle)
    local doc, _, got = call("check", params)
    eq({ doc.kind, got }, { "tasks.error", want }, vim.inspect(params))
    has(doc.message, needle)
  end
  refused_check({ stale = "all" }, "invalid_argument", "stale must be refs")
  refused_check({ area = "nope.nvim" }, "not_found", "unknown area")
  golden("check")

  -- ── next ──
  local nxt = call("next", { n = 3 })
  eq(nxt.kind, "tasks.next")
  eq(
    nxt.task.id,
    "lib.nvim/alpha-twin",
    "the best ready task: open before decision, prio 1, the smaller effort"
  )
  eq(nxt.task.reason, "vault")
  ok(#nxt.alternatives <= 3)
  eq(
    nxt.ready.vault,
    6,
    "ready for you: twin, gamma, order-a, zeta, eta, broken (alpha is for an AI session)"
  )
  eq(
    nxt.cdx[1].id,
    "lib.nvim/alpha",
    "what an AI session could take is listed apart, not as your next task"
  )
  golden("next")

  -- ── areas ──
  local areas = call("areas")
  eq(areas.kind, "tasks.areas")
  local by_name = {}
  for _, a in ipairs(areas.areas) do
    by_name[a.name] = a
  end
  eq(by_name["lib.nvim"].open, 10)
  eq(by_name["cascade.nvim"].open, 4)
  eq(by_name["lib.nvim"].by_status, { blocked = 1, decision = 1, doing = 1, open = 6, parked = 1 })
  golden("areas")

  -- ── errors: a stable code, never a throw, never a path ──
  ---@param name string
  ---@param request? string
  ---@param expected string
  ---@param msg string
  local function refused(name, request, expected, msg)
    local text, c = api.call(name, request, { root = root })
    local doc = vim.json.decode(text)
    eq({ doc.kind, doc.code, c }, { "tasks.error", expected, expected }, msg)
    eq(doc.schema, 1)
    ok(type(doc.retryable) == "boolean")
    lacks(text, root, msg .. ": no path of this machine")
    return doc
  end
  refused("frobnicate", nil, "not_found", "unknown method")
  refused("list", "{nope", "invalid_argument", "bad JSON")
  refused("list", "[1,2]", "invalid_argument", "a request that is a list")
  refused("list", '{"schema":2}', "unsupported_schema", "a higher schema")
  refused("list", '{"schema":0}', "invalid_argument", "schema 0")
  refused("list", '{"extra":1}', "invalid_argument", "an unknown request field")
  refused("list", '{"params":{"colour":"red"}}', "invalid_argument", "an unknown parameter")
  refused("list", '{"params":{"limit":"5"}}', "invalid_argument", "a wrong type")
  refused("list", '{"params":{"limit":101}}', "invalid_argument", "limit above the contract's")
  refused("list", '{"params":{"limit":0}}', "invalid_argument", "limit 0")
  refused("list", '{"params":{"offset":-1}}', "invalid_argument", "a negative offset")
  refused("list", '{"params":{"area":"nope.nvim"}}', "not_found", "an unknown area")
  refused("task", nil, "invalid_argument", "task without an id")
  refused("task", '{"params":{"id":"lib.nvim/nope"}}', "not_found", "an unknown task")
  refused("task", '{"params":{"id":"../x"}}', "invalid_argument", "an id that is a path")
  refused("next", '{"params":{"actor":"robot"}}', "invalid_argument", "an unknown actor")
  refused("next", '{"params":{"n":99}}', "invalid_argument", "n out of range")
  refused("hello", '{"params":{"x":1}}', "invalid_argument", "hello takes no parameter")
  refused(
    "snapshot",
    string.rep(" ", 300 * 1024) .. "{}",
    "payload_too_large",
    "a request over 256 KiB"
  )
  local missing = api.call("snapshot", nil, { root = root .. "/no-such-folder" })
  eq(vim.json.decode(missing).code, "not_found", "no vault")
  lacks(missing, root, "...and its message does not name the path")
  eq(
    vim.json.decode((api.call("snapshot", "", { root = root }))).kind,
    "tasks.snapshot",
    "an empty request is an empty request"
  )
  eq(
    vim.json.decode((api.call("list", '{"schema":1,"params":{}}', { root = root }))).kind,
    "tasks.list"
  )
  golden("error-unsupported-schema")
  golden("error-unknown-parameter")

  -- a document over the limit is an error, not a cut-off document
  local max = contract.MAX_DOC_BYTES
  contract.MAX_DOC_BYTES = 200
  local big = vim.json.decode((api.call("snapshot", nil, { root = root })))
  contract.MAX_DOC_BYTES = max
  eq(big.code, "payload_too_large")
  has(big.message, "ask for a page or an area")

  -- ── what a file can do to a document ──
  H.write(
    root .. "/cascade.nvim/ROADMAP/tasks/nul-and-bad-utf8.md",
    "---\ntitle: bytes \255 here\nstatus: open\n---\n\nbody with a NUL \0 and \254 inside\n"
  )
  local hostile = call("snapshot")
  local nul = nil
  for _, t in ipairs(hostile.tasks) do
    if t.id == "cascade.nvim/nul-and-bad-utf8" then
      nul = t
    end
  end
  ok(nul ~= nil, "a file with a NUL and bad bytes is a task like any other")
  ok(nul.etag:match("^sha256:%x+$"), "...with an etag")
  has(nul.title, "\239\191\189", "a bad byte became U+FFFD")
  vim.fn.delete(root .. "/cascade.nvim/ROADMAP/tasks/nul-and-bad-utf8.md")

  -- ── a read scope does not outlive a call: a new area shows up in the next document ──
  local function area_names(doc)
    local names = {}
    for _, a in ipairs(doc.areas) do
      names[a.name or a.id or ""] = true
    end
    return names
  end
  ok(area_names(call("areas"))["late.nvim"] == nil, "no such area yet")
  call("snapshot")
  vim.fn.mkdir(root .. "/late.nvim/ROADMAP/tasks", "p")
  ok(area_names(call("areas"))["late.nvim"], "the area made after the last call is in the next one")
  ok(area_names(call("snapshot"))["late.nvim"], "...also in the snapshot")
  vim.fn.delete(root .. "/late.nvim", "rf")

  -- A view that fails leaves no scope behind.
  local scan = require("tasks_nvim.scan")
  local fsio = require("tasks_nvim.fsio")
  local real_all = scan.all
  local flag = root .. "/flag-after-failed-view.txt"
  scan.all = function()
    ok(not fsio.is_file(flag))
    H.write(flag, "x")
    error("scan failed")
  end
  local failed = pcall(contract.view, { root = root })
  scan.all = real_all
  eq(failed, false, "the failure reaches the caller")
  ok(fsio.is_file(flag), "the scope of the failed view is closed: the disk answers")
  vim.fn.delete(flag)

  -- ── the clock and the engine info are real when nobody overrides them ──
  contract.clock, contract.engine_info = real_clock, real_engine
  local now = call("hello")
  ok(
    now.generated_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
    "generated_at is UTC ISO 8601"
  )
  ok(now.engine.version ~= "" and now.engine.nvim ~= "")
  eq(json.encode(json.object({})), "{}")
end
