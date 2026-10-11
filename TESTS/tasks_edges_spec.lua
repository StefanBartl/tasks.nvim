-- TESTS/tasks_edges_spec.lua -- tasks.edges: a change of blocked_by / after / plan / phase is judged BEFORE it is
-- written, with the codes of `check`.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local edges = require("tasks_nvim.edges")
  local plans = require("tasks_nvim.plans")

  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "a", F.meta("A", "open"))
  F.task(H, root, "lib.nvim", "b", F.meta("B", "open", { { "blocked_by", "lib.nvim/a" } }))
  F.task(H, root, "lib.nvim", "c", F.meta("C", "open", { { "blocked_by", "lib.nvim/b" } }))
  F.task(H, root, "cascade.nvim", "d", F.meta("D", "open"))
  F.task(H, root, "lib.nvim", "loose", F.meta("Loose", "open"))
  -- a finished task: a blocker that is met
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-09-01_finished.md",
    F.text(F.meta("Finished", "done"))
  )

  ---@param id string
  ---@param proposal table
  ---@return Tasks.EdgeProblem[]
  local function validate(id, proposal)
    local problems, err = edges.validate(id, proposal, { root = root })
    ok(problems, "validate failed: " .. tostring(err))
    return problems
  end

  ---@param problems Tasks.EdgeProblem[]
  ---@return string[]
  local function codes(problems)
    local out = {}
    for _, p in ipairs(problems) do
      out[#out + 1] = p.code
    end
    table.sort(out)
    return out
  end

  -- ── nothing proposed, nothing wrong ──────────────────────────────────────────
  eq(validate("lib.nvim/a", {}), {})

  -- ── self and dangling, for both edge kinds ───────────────────────────────────
  eq(
    codes(validate("lib.nvim/loose", { blocked_by = { "lib.nvim/loose" } })),
    { "blocked-by-self" }
  )
  eq(codes(validate("lib.nvim/loose", { after = { "lib.nvim/loose" } })), { "after-self" })
  local dangling = validate("lib.nvim/loose", { blocked_by = { "lib.nvim/nowhere", "lib.nvim/a" } })
  eq(codes(dangling), { "blocked-by-dangling" })
  eq(dangling[1].target, "lib.nvim/nowhere", "the problem names the target")
  eq(dangling[1].key, "blocked_by")
  has(dangling[1].message, "does not exist")
  eq(codes(validate("lib.nvim/loose", { after = { "lib.nvim/nowhere" } })), { "after-dangling" })

  -- an edge to a task of another area, and to a finished one, is fine
  eq(validate("lib.nvim/loose", { blocked_by = { "cascade.nvim/d" } }), {})
  eq(
    validate("lib.nvim/loose", { blocked_by = { "lib.nvim/finished" } }),
    {},
    "a met blocker blocks nobody"
  )
  eq(validate("lib.nvim/loose", { after = { "lib.nvim/finished" } }), {})

  -- removing relations is always fine
  eq(validate("lib.nvim/b", { blocked_by = {} }), {})

  -- ── a cycle through the task ─────────────────────────────────────────────────
  local cyc = validate("lib.nvim/a", { blocked_by = { "lib.nvim/c" } })
  eq(codes(cyc), { "blocked-by-cycle" })
  eq(
    cyc[1].members,
    { "lib.nvim/a", "lib.nvim/b", "lib.nvim/c" },
    "the members of the circle (the order `check` names them in), the task first"
  )
  has(cyc[1].message, "lib.nvim/a -> lib.nvim/b -> lib.nvim/c")
  eq(cyc[1].key, "blocked_by")
  -- a longer line is no cycle
  eq(validate("lib.nvim/loose", { blocked_by = { "lib.nvim/c" } }), {})
  -- a soft edge that would close a circle is not an error (the plan drops it with a warning)
  eq(validate("lib.nvim/a", { after = { "lib.nvim/c" } }), {})

  -- ── plan and phase ───────────────────────────────────────────────────────────
  local made = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Ship",
    areas = "lib.nvim,cascade.nvim",
    phases = "clarify,build,ship",
  }))
  local other = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Other" }))
  eq(other.id, "lib.nvim/other")

  eq(codes(validate("lib.nvim/loose", { plan = "lib.nvim/no-such-plan" })), { "plan-unknown" })
  eq(validate("lib.nvim/loose", { plan = made.id }), {})
  eq(validate("lib.nvim/loose", { plan = made.id, phase = "build" }), {})
  local bad_phase = validate("lib.nvim/loose", { plan = made.id, phase = "invented" })
  eq(codes(bad_phase), { "plan-phase" })
  eq(bad_phase[1].key, "phase")
  eq(bad_phase[1].target, "invented")
  has(bad_phase[1].message, "clarify, build, ship")
  -- a plan without stages takes any phase
  eq(validate("lib.nvim/loose", { plan = other.id, phase = "anything" }), {})
  -- removing plan and phase
  eq(validate("lib.nvim/loose", { plan = false, phase = false }), {})

  -- the phase of the task is judged against a NEW plan too
  assert(
    require("tasks_nvim.mutate").set(
      "lib.nvim/loose",
      { plan = made.id, phase = "ship" },
      { root = root, today = F.TODAY, index = false }
    )
  )
  eq(
    codes(validate("lib.nvim/loose", { plan = other.id })),
    {},
    "the new plan lists no stages, so the old phase is fine there"
  )
  local narrow = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Narrow",
    phases = "one,two",
  }))
  eq(
    codes(validate("lib.nvim/loose", { plan = narrow.id })),
    { "plan-phase" },
    "moving to a plan that does not list the task's phase says so"
  )
  eq(validate("lib.nvim/loose", { plan = narrow.id, phase = "one" }), {})

  -- a gate between stages is a hard edge: a task of a later stage cannot be what an earlier one waits on
  local gated = assert(plans.new("cascade.nvim", {
    root = root,
    today = F.TODAY,
    title = "Gated",
    areas = "lib.nvim,cascade.nvim",
    phases = "first,second",
    gate = "hard",
  }))
  F.task(
    H,
    root,
    "lib.nvim",
    "early",
    F.meta("Early", "open", { { "plan", gated.id }, { "phase", "first" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "late",
    F.meta("Late", "open", { { "plan", gated.id }, { "phase", "second" } })
  )
  local gate = validate("lib.nvim/early", { blocked_by = { "lib.nvim/late" } })
  eq(
    codes(gate),
    { "blocked-by-cycle" },
    "the gate makes `late` wait on `early`, so `early` cannot wait on `late`"
  )

  -- ── an unknown task is an error, not a clean bill ────────────────────────────
  local none, err = edges.validate("lib.nvim/ghost", {}, { root = root })
  eq(none, nil)
  has(err, "no such open task")
end
