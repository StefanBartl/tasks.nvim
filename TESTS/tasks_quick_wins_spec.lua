-- TESTS/tasks_quick_wins_spec.lua -- the quick-win rule (thresholds, filter shorthand) and the report (`tasks quickwins`).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local config = require("tasks_nvim.config")
  local model = require("tasks_nvim.model")
  local estimate = require("tasks_nvim.estimate")
  local filter_opts = require("tasks_nvim.filter_opts")
  local quick_wins = require("tasks_nvim.quick_wins")
  local cli = require("tasks_nvim.cli")

  local before = vim.deepcopy(config.get())

  -- ── config: the `quick_wins` section is validated key by key ──
  eq(config.validate({ quick_wins = { min_value = 3, max_effort = "m" } }).quick_wins, {
    min_value = 3,
    max_effort = "M",
  }, "a size word is normalised to upper case")
  eq(
    config.validate({ quick_wins = { max_effort = "0.5D" } }).quick_wins.max_effort,
    "0.5d",
    "days are normalised to lower case"
  )
  eq(
    config.validate({ quick_wins = { min_value = 9 } }).quick_wins,
    {},
    "a value outside 1-5 is dropped"
  )
  eq(
    config.validate({ quick_wins = { min_value = 2.5 } }).quick_wins,
    {},
    "a fractional value is dropped"
  )
  eq(
    config.validate({ quick_wins = { max_effort = "huge" } }).quick_wins,
    {},
    "an unknown effort is dropped"
  )
  eq(config.validate({ quick_wins = 4 }).quick_wins, nil, "a non-table section is dropped")

  -- ── thresholds and the rule ──
  local th = estimate.thresholds()
  eq(
    { th.value, th.days, th.effort },
    { 4, 0.5, "S" },
    "the built-in definition: value >= 4, effort <= S"
  )

  ---@param slug string
  ---@param opts? { effort?: string, value?: string, actor?: string, status?: string, title?: string }
  ---@return Tasks.Task
  local function T(slug, opts)
    opts = opts or {}
    local lines =
      { "---", "title: " .. (opts.title or slug), "status: " .. (opts.status or "open") }
    for _, key in ipairs({ "effort", "value", "actor" }) do
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

  ok(estimate.is_quick_win(T("w1", { effort = "S", value = "4" })), "value 4, effort S")
  ok(estimate.is_quick_win(T("w2", { effort = "0.25d", value = "5" })), "days count too")
  ok(not estimate.is_quick_win(T("n1", { effort = "M", value = "5" })), "M is too big")
  ok(not estimate.is_quick_win(T("n2", { effort = "S", value = "3" })), "value 3 is too small")
  ok(
    not estimate.is_quick_win(T("n3", { effort = "XS" })),
    "a missing value is unestimated, not a win"
  )
  ok(
    not estimate.is_quick_win(T("n4", { value = "5" })),
    "a missing effort is unestimated, not a win"
  )

  config.merge({ quick_wins = { min_value = 3, max_effort = "M" } })
  th = estimate.thresholds()
  eq({ th.value, th.days, th.effort }, { 3, 1, "M" }, "the config moves both thresholds")
  ok(estimate.is_quick_win(T("c1", { effort = "M", value = "3" })), "now value 3 and M count")
  eq(
    estimate.rollup({
      T("c2", { effort = "M", value = "3" }),
      T("c3", { effort = "L", value = "5" }),
    }).quick_wins,
    { "a/c2" },
    "the rollup uses the same thresholds"
  )

  -- ── the --quick-win shorthand is a value and an effort bound ──
  local f = filter_opts.parse({ quick_win = true })
  eq({ f.value_min, f.effort_max }, { 3, "M" }, "the shorthand follows the configured thresholds")
  local _, err = filter_opts.parse({ quick_win = true, value = ">=2" })
  has(err, "do not combine", "an explicit --value beside it is refused, not dropped")
  _, err = filter_opts.parse({ quick_win = true, effort = "S" })
  has(err, "do not combine")
  config.merge(before)
  eq(estimate.thresholds().value, 4, "back to the defaults")

  -- ── the dashboard shows the two bounds as one chip ──
  local core = require("tasks_nvim.ui.dash_core")
  ok(vim.tbl_contains(core.FILTER_DIMS, "quick-win"), "the `f` menu offers it")
  eq(
    core.chips({ value_min = 4, effort_max = "S" }),
    { "quick-win" },
    "exactly the definition: one chip"
  )
  eq(
    core.chips({ value_min = 3, effort_max = "S" }),
    { "effort: <=S", "value: >=3" },
    "another bound is not the definition: two plain chips"
  )
  ok(
    not core.is_quick_win_filter({ value_min = 4, effort_max = "S", value = { 5 } }),
    "a value list beside it"
  )

  -- ── the report groups what the rule can and cannot see ──
  local hostile = "evil | cell `x` <b>bold</b>"
  local tasks = {
    T("win-b", { effort = "S", value = "4", actor = "cdx" }),
    T("win-a", { effort = "XS", value = "5", actor = "me", title = hostile }),
    T("big", { effort = "L", value = "5" }),
    T("small-unrated", { effort = "XS" }),
    T("valuable-unsized", { value = "5" }),
    T("plain", { effort = "S", value = "2" }),
  }
  local report = quick_wins.build(tasks)
  eq(
    vim.tbl_map(function(t)
      return t.id
    end, report.wins),
    { "a/win-a", "a/win-b" },
    "best return first"
  )
  eq(#report.small_unrated, 1, "a small task without a value is named apart")
  eq(report.small_unrated[1].id, "a/small-unrated")
  eq(#report.valuable_unsized, 1, "a high value without an effort is named apart")
  eq(report.valuable_unsized[1].id, "a/valuable-unsized")

  local tsv = quick_wins.tsv(report)
  eq(#tsv, 2)
  has(tsv[1], "a/win-a\t", "id first")
  has(tsv[1], "\tXS\t5\t20.0\tme\t", "effort, value, roi, actor")
  eq(quick_wins.ids(report), { "a/win-a", "a/win-b" })

  local md = quick_wins.markdown(report, { title = "all areas", paths = true })
  has(md, "<!-- GENERATED by `tasks quickwins` -- do not edit -->")
  has(md, "## Quick wins (2)")
  has(md, "## Small, but no value yet (1)")
  has(md, "## Valuable, but no effort yet (1)")
  has(md, "evil \\| cell", "a title cannot split the table cell")
  has(md, "`/v/a/ROADMAP/tasks/win-a.md`", "the file column carries the absolute path")
  lacks(md, "a/plain", "a task that misses the rule is not listed")
  local by_actor = quick_wins.markdown(report, { by_actor = true })
  has(by_actor, "### for me (1)")
  has(by_actor, "### for an AI session (1)")
  has(quick_wins.markdown(quick_wins.build({}), {}), "_none_", "no quick wins says so")

  -- ── tasks quickwins, in-process on a throw-away vault ──
  local root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "win",
    F.meta("A real win", "open", { { "prio", "1" }, { "effort", "S" }, { "value", "5" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "also",
    F.meta("Another one", "doing", { { "effort", "XS" }, { "value", "4" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "parked-win",
    F.meta("Parked, so not startable", "parked", { { "effort", "XS" }, { "value", "5" } })
  )
  F.task(
    H,
    root,
    "cascade.nvim",
    "unrated",
    F.meta("Small, no value", "open", { { "effort", "XS" } })
  )
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, errs = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end

  local r = run({ "quickwins" })
  eq(r.code, 0, r.err)
  local rows = vim.split((r.out:gsub("\n$", "")), "\n", { plain = true })
  eq(#rows, 2, "two startable quick wins; the parked one is not offered")
  has(rows[1], "lib.nvim/also", "XS beats S: best return first")
  has(rows[2], "lib.nvim/win")
  lacks(r.out, "parked-win")

  r = run({ "quickwins", "--status=parked" })
  has(r.out, "lib.nvim/parked-win", "an explicit --status overrides the default")

  r = run({ "quickwins", "--format=ids" })
  eq(r.out, "lib.nvim/also\nlib.nvim/win\n")
  r = run({ "quickwins", "--format=md", "--paths" })
  has(r.out, "## Small, but no value yet (1)")
  has(r.out, "cascade.nvim/unrated")
  has(r.out, "ROADMAP/tasks/win.md`")
  r = run({ "quickwins", "lib.nvim", "--min-value=5", "--max-effort=XS", "--format=ids" })
  eq(r.out, "", "stricter thresholds on the command line: nothing left")
  r = run({ "quickwins", "--min-value=9" })
  eq(r.code, 2)
  has(r.err, "--min-value")
  r = run({ "quickwins", "--max-effort=huge" })
  eq(r.code, 2)
  r = run({ "quickwins", "--format=xml" })
  eq(r.code, 2)
  r = run({ "quickwins", "--value=4" })
  eq(r.code, 2, "--value is the definition here, not a filter")
  has(r.err, "--value")

  -- the shorthand works in list, with the same set
  r = run({ "list", "--quick-win", "--sort=roi" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/also")
  lacks(r.out, "cascade.nvim/unrated")
  r = run({ "list", "--quick-win", "--value=4" })
  eq(r.code, 2)
  has(r.err, "do not combine")

  -- --report writes once, replaces its own output, and never overwrites a hand-written file
  local target = H.tmpdir() .. "/report.md"
  r = run({ "quickwins", "--report=" .. target })
  eq(r.code, 0, r.err)
  has(r.out, "wrote\t")
  has(H.read(target), "<!-- GENERATED by `tasks quickwins` -- do not edit -->")
  r = run({ "quickwins", "--report=" .. target, "--by-actor" })
  eq(r.code, 0, "an earlier generated file is replaced")
  local mine = H.tmpdir() .. "/mine.md"
  H.write(mine, "# my notes\n")
  r = run({ "quickwins", "--report=" .. mine })
  eq(r.code, 1)
  has(r.err, "refusing to overwrite")
  eq(H.read(mine), "# my notes\n", "the hand-written file is untouched")
end
