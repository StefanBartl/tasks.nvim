-- TESTS/tasks_estimate_spec.lua -- tasks_nvim.estimate: the sums name what they are made of and what is missing.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local model = require("tasks_nvim.model")
  local estimate = require("tasks_nvim.estimate")

  ---@param slug string
  ---@param opts? { effort?: string, value?: string, actor?: string, status?: string, tags?: string }
  ---@return Tasks.Task
  local function T(slug, opts)
    opts = opts or {}
    local lines = { "---", "title: " .. slug, "status: " .. (opts.status or "open") }
    for _, key in ipairs({ "effort", "value", "actor", "tags" }) do
      if opts[key] then
        lines[#lines + 1] = key .. ": " .. opts[key]
      end
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = "text"
    return model.parse_text(
      table.concat(lines, "\n") .. "\n",
      { path = "/v/a/ROADMAP/tasks/" .. slug .. ".md", area = "a" }
    )
  end

  -- ── the sums say what is missing ──
  local tasks = {
    T("q1", { effort = "S", value = "5", actor = "cdx" }), -- quick win, roi 5 / 0.5 = 10
    T("q2", { effort = "XS", value = "4", actor = "me" }), -- quick win, roi 4 / 0.25 = 16
    T("big", { effort = "XL", value = "5", actor = "pair" }), -- 5 days, roi 1
    T("noval", { effort = "M" }),
    T("noeff", { value = "3" }),
    T("nothing"),
    T("decide", { status = "decision" }),
  }
  local r = estimate.rollup(tasks)
  eq(r.n, 7)
  eq(r.days, 0.5 + 0.25 + 5 + 1, "S + XS + XL + M on the scale")
  eq(r.n_with_effort, 4)
  eq(r.n_without_effort, 3)
  eq(r.value, 17)
  eq(r.n_with_value, 4)
  eq(r.n_without_value, 3)
  eq(r.n_roi, 3, "only tasks with BOTH numbers count for the roi")
  ok(math.abs(r.roi - (5 + 4 + 5) / (0.5 + 0.25 + 5)) < 1e-9, "roi = value / days over those three")
  eq(r.quick_wins, { "a/q2", "a/q1" }, "value >= 4 and effort <= S, best roi first")
  eq(
    r.unestimated,
    { "a/noval", "a/noeff", "a/nothing", "a/decide" },
    "missing the effort or the value"
  )

  -- the range: every size at its low and at its high end
  eq(r.range.low, 0.35 + 0.15 + 3 + 0.7)
  eq(r.range.high, 0.8 + 0.35 + 8 + 1.5)
  ok(r.range.low < r.days and r.days < r.range.high, "the plain scale sits inside the range")

  -- days written as numbers have no range
  local exact = estimate.rollup({ T("d1", { effort = "3d" }), T("d2", { effort = "0.5d" }) })
  eq(exact.days, 3.5)
  eq(exact.range, { low = 3.5, high = 3.5 })

  -- ── the split by actor ──
  eq(r.by_actor.cdx, { n = 1, days = 0.5, n_without_effort = 0 })
  eq(
    r.by_actor.me,
    { n = 2, days = 0.25, n_without_effort = 1 },
    "me: the written one and the derived decision"
  )
  eq(r.by_actor.pair.days, 5)
  eq(r.by_actor.none.n, 3, "nobody classified three of them")
  eq(r.by_actor.none.n_without_effort, 2)

  -- ── nothing at all: honest zeros and no roi ──
  local none = estimate.rollup({})
  eq(none.n, 0)
  eq(none.days, 0)
  eq(none.roi, nil)
  eq(none.quick_wins, {})
  local bare = estimate.rollup({ T("x"), T("y") })
  eq(bare.roi, nil, "no figure without both numbers, not 0")
  eq(bare.n_without_effort, 2)

  -- ── progress from the finished tasks of the same scope ──
  local done = { T("old1", { effort = "M", status = "done" }), T("old2", { status = "done" }) }
  local p = estimate.rollup(
    { T("open1", { effort = "M" }), T("open2", { effort = "M" }) },
    { done = done }
  )
  eq(p.progress.done_days, 1)
  eq(p.progress.total_days, 3)
  eq(p.progress.pct, 33)
  eq(p.progress.n_done, 2)
  eq(
    p.progress.n_done_without_effort,
    1,
    "a finished task without an effort is counted, not guessed"
  )
  eq(estimate.rollup({ T("o") }).progress, nil, "no finished list, no progress figure")

  -- ── the line ──
  eq(estimate.fmt_days(22), "22")
  eq(estimate.fmt_days(7.5), "7.5")
  eq(estimate.fmt_days(0.25), "0.25")
  local line = estimate.describe(r)
  has(line, "7 tasks")
  has(line, "6.75 d from 4 of 7")
  has(line, "range 4.2-10.65 d")
  has(line, "value 17 (4 of 7)")
  has(line, "roi 2.4")
  has(line, "me 0.25 d / cdx 0.5 d / pair 5 d / unclear 3")
  has(line, estimate.CAVEAT)
  has(estimate.describe(none), "0 tasks")
  has(estimate.describe(none), "no effort estimated")
  has(estimate.describe(p), "33% done (1 of 3 d)")
end
