-- TESTS/tasks_effort_severity_spec.lua -- the effort filter, the `prio-effort` / `severity` sort orders and the
-- `severity` field (concept section 12.5): model, check, mutate, CLI and the dashboard core.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local dash = require("tasks_nvim.ui.dash_core")

  local TODAY = F.TODAY

  ---@param meta table[]
  ---@param slug string
  ---@return Tasks.Task
  local function parse(meta, slug)
    return model.parse_text(
      F.text(meta),
      { path = "/v/a/ROADMAP/tasks/" .. (slug or "t") .. ".md", area = "a" }
    )
  end

  ---@param list Tasks.Task[]
  ---@return string[] ids in list order
  local function order(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = t.slug
    end
    return out
  end

  ---@param slug string
  ---@param extra table[]
  local function task(slug, extra)
    return parse(F.meta(slug, "open", extra), slug)
  end

  -- ── effort: the common scale ────────────────────────────────────────────
  eq(model.effort_days("XS"), 0.25)
  eq(model.effort_days("M"), 1)
  eq(model.effort_days("3d"), 3)
  eq(model.effort_days("0.75d"), 0.75)
  eq(model.effort_days("huge"), nil, "not an effort")
  eq(model.effort_days(nil), nil)
  ok(model.effort_days("XS") < model.effort_days("S"))
  ok(model.effort_days("S") < model.effort_days("M"))
  ok(model.effort_days("M") < model.effort_days("L"))
  ok(model.effort_days("L") < model.effort_days("XL"))

  -- ── effort filter ───────────────────────────────────────────────────────
  local e_none = task("e-none", {})
  local e_xs = task("e-xs", { { "effort", "XS" } })
  local e_s = task("e-s", { { "effort", "S" } })
  local e_m = task("e-m", { { "effort", "M" } })
  local e_l = task("e-l", { { "effort", "L" } })
  local e_d = task("e-d", { { "effort", "0.75d" } })
  local efforts = { e_none, e_xs, e_s, e_m, e_l, e_d }

  local f = assert(require("tasks_nvim.filter_opts").parse({ effort = "S, m" }))
  eq(f.effort, { "S", "M" }, "size words are case-insensitive, the list is trimmed")
  eq(order(model.filter(efforts, f)), { "e-s", "e-m" })

  f = assert(require("tasks_nvim.filter_opts").parse({ effort = "0.75d" }))
  eq(order(model.filter(efforts, f)), { "e-d" }, "day values match exactly")

  f = assert(require("tasks_nvim.filter_opts").parse({ effort = "<=M" }))
  eq(f.effort_max, "M")
  eq(
    order(model.filter(efforts, f)),
    { "e-xs", "e-s", "e-m", "e-d" },
    "<=M: this size or smaller, days on the same scale, no effort never matches"
  )
  f = assert(require("tasks_nvim.filter_opts").parse({ effort = "<=0.5d" }))
  eq(order(model.filter(efforts, f)), { "e-xs", "e-s" })

  for _, bad in ipairs({ "XXL", "<=big", "", "S,wat" }) do
    local nf, err = require("tasks_nvim.filter_opts").parse({ effort = bad })
    eq(nf, nil, "refused: '" .. bad .. "'")
    has(err, "--effort")
  end

  -- ── sort: prio, then effort ascending ───────────────────────────────────
  eq(model.SORTS, { "default", "prio-effort", "severity", "frecency", "roi" })
  eq(model.parse_sort(nil), "default")
  eq(model.parse_sort(""), "default")
  eq(model.parse_sort("prio-effort"), "prio-effort")
  local no_sort, sort_err = model.parse_sort("fastest")
  eq(no_sort, nil)
  has(sort_err, "unknown --sort 'fastest'")
  has(sort_err, "prio-effort")

  local function p(slug, prio, effort, status)
    local meta = {}
    if prio then
      meta[#meta + 1] = { "prio", tostring(prio) }
    end
    if effort then
      meta[#meta + 1] = { "effort", effort }
    end
    return parse(F.meta(slug, status or "open", meta), slug)
  end
  local mixed = {
    p("p2-s", 2, "S"),
    p("p1-none", 1, nil),
    p("p1-m", 1, "M"),
    p("p1-xs", 1, "XS"),
    p("p1-days", 1, "0.75d"),
    p("p3-xs", 3, "XS"),
    p("noprio-xs", nil, "XS"),
    p("noprio-none", nil, nil),
    p("p1-doing-l", 1, "L", "doing"),
  }
  eq(order(model.sort(vim.deepcopy(mixed), "prio-effort")), {
    "p1-doing-l",
    "p1-xs",
    "p1-days",
    "p1-m",
    "p1-none",
    "p2-s",
    "p3-xs",
    "noprio-xs",
    "noprio-none",
  }, "status first (as in the default), then prio, effort ascending, no effort last of its prio")
  eq(order(model.sort(vim.deepcopy(mixed))), {
    "p1-doing-l",
    "p1-days",
    "p1-m",
    "p1-none",
    "p1-xs",
    "p2-s",
    "p3-xs",
    "noprio-none",
    "noprio-xs",
  }, "the default order does not look at effort")
  eq(
    order(model.sort(vim.deepcopy(mixed), "default")),
    order(model.sort(vim.deepcopy(mixed))),
    "'default' is the default"
  )
  eq(
    order(model.sort(vim.deepcopy(mixed), "bogus")),
    order(model.sort(vim.deepcopy(mixed))),
    "an unknown order sorts like the default"
  )
  -- Reversed input gives the same result: the comparator is total.
  local rev = vim.deepcopy(mixed)
  for i = 1, math.floor(#rev / 2) do
    rev[i], rev[#rev - i + 1] = rev[#rev - i + 1], rev[i]
  end
  eq(order(model.sort(rev, "prio-effort")), order(model.sort(vim.deepcopy(mixed), "prio-effort")))

  -- ── severity: the field, check findings ─────────────────────────────────
  eq(model.SEVERITIES, { "low", "medium", "high", "critical" })
  ok(model.is_severity("critical"))
  ok(not model.is_severity("urgent"))
  ok(not model.is_severity(nil))

  local function has_hint(t, code)
    for _, h in ipairs(t.hints) do
      if h.code == code then
        return true
      end
    end
    return false
  end

  local bug = parse(F.meta("B", "open", { { "kind", "bug" }, { "severity", "high" } }))
  ok(bug.valid)
  eq(bug.severity, "high")
  ok(not has_hint(bug, "severity-without-bug-or-security"), "kind bug is fine")
  local sec = parse(F.meta("S", "open", { { "category", "[security]" }, { "severity", "low" } }))
  ok(sec.valid and not has_hint(sec, "severity-without-bug-or-security"), "category security")
  local tagged = parse(
    F.meta("T", "open", { { "kind", "task" }, { "tags", "[bug]" }, { "severity", "medium" } })
  )
  ok(not has_hint(tagged, "severity-without-bug-or-security"), "a tag spelled like the category")
  local none = parse(F.meta("N", "open", { { "kind", "bug" } }))
  eq(none.severity, nil, "severity is optional")
  ok(none.valid)

  local odd = parse(F.meta("O", "open", { { "kind", "task" }, { "severity", "high" } }))
  ok(odd.valid, "a misplaced severity is only a warning")
  ok(has_hint(odd, "severity-without-bug-or-security"))

  local wrong = parse(F.meta("W", "open", { { "kind", "bug" }, { "severity", "urgent" } }))
  ok(not wrong.valid, "an unknown severity is an error")
  eq(wrong.error_codes[1], "unknown-severity")
  has(wrong.errors[1], "unknown severity 'urgent'")
  has(wrong.errors[1], "low, medium, high, critical")
  ok(
    not has_hint(wrong, "severity-without-bug-or-security"),
    "no second finding for a word that is already an error"
  )
  local shouted = parse(F.meta("W", "open", { { "kind", "bug" }, { "severity", "High" } }))
  eq(shouted.error_codes[1], "unknown-severity", "the words are lower case")

  -- ── severity filter ─────────────────────────────────────────────────────
  local function s(slug, severity, prio, kind)
    local meta = { { "kind", kind or "bug" } }
    if severity then
      meta[#meta + 1] = { "severity", severity }
    end
    if prio then
      meta[#meta + 1] = { "prio", tostring(prio) }
    end
    return parse(F.meta(slug, "open", meta), slug)
  end
  local sevs = {
    s("s-crit", "critical", 3),
    s("s-high-p1", "high", 1),
    s("s-high-p2", "high", 2),
    s("s-low", "low", 1),
    s("s-none", nil, 1),
    s("s-med", "medium", 2),
  }
  f = assert(require("tasks_nvim.filter_opts").parse({ severity = "high,critical" }))
  eq(f.severity, { "high", "critical" })
  eq(
    order(model.filter(sevs, f)),
    { "s-crit", "s-high-p1", "s-high-p2" },
    "a task without severity never matches"
  )
  local sf, serr = require("tasks_nvim.filter_opts").parse({ severity = "urgent" })
  eq(sf, nil)
  has(serr, "unknown severity in --severity: urgent")

  -- ── sort: severity first (critical, high, medium, low, none), then default ──
  eq(
    order(model.sort(vim.deepcopy(sevs), "severity")),
    { "s-crit", "s-high-p1", "s-high-p2", "s-med", "s-low", "s-none" },
    "critical first, then the default order (prio) within a severity, none last"
  )
  eq(
    order(model.sort(vim.deepcopy(sevs))),
    { "s-high-p1", "s-low", "s-none", "s-high-p2", "s-med", "s-crit" },
    "the default order is unchanged"
  )

  -- ── mutate: new / set ───────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY }
  local made = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend("force", o, { title = "Crash on exit", kind = "bug", severity = "critical" })
    )
  )
  local read = scan.find(made.id, { root = root })
  eq(read.severity, "critical")
  ok(read.valid)
  has(H.read(made.path), "severity: critical")
  local _, nerr = mutate.new(
    "lib.nvim",
    vim.tbl_extend("force", o, { title = "X", kind = "bug", severity = "urgent" })
  )
  has(nerr, "unknown severity 'urgent'")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/x.md"), "nothing is created for a bad severity")

  assert(mutate.set(made.id, { severity = "low" }, o))
  eq(scan.find(made.id, { root = root }).severity, "low")
  local _, serr2 = mutate.set(made.id, { severity = "urgent" }, o)
  has(serr2, "unknown severity 'urgent'")
  assert(mutate.set(made.id, { severity = mutate.REMOVE }, o))
  eq(scan.find(made.id, { root = root }).severity, nil, "an empty value removes the key")
  ok(vim.tbl_contains(mutate.SETTABLE, "severity"))

  -- ── check ───────────────────────────────────────────────────────────────
  local function codes(r)
    local out = {}
    for _, fnd in ipairs(r.findings) do
      out[#out + 1] = (fnd.severity == "warn" and "warn:" or "") .. fnd.code
    end
    table.sort(out)
    return out
  end
  assert(mutate.set(made.id, { severity = "high" }, o))
  assert(index.write_area("lib.nvim", { root = root }))
  local res = assert(check.run({ root = root }))
  eq(codes(res), {}, "a bug with a severity checks clean")

  local misplaced =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Misplaced" })))
  assert(mutate.set(misplaced.id, { severity = "high" }, o))
  res = assert(check.run({ root = root }))
  eq(codes(res), { "warn:severity-without-bug-or-security" })
  ok(res.ok, "only a warning")
  has(res.findings[1].message, "bug or security")
  assert(mutate.set(misplaced.id, { category = "security" }, o))
  res = assert(check.run({ root = root }))
  eq(codes(res), {}, "a security category makes it fit")

  -- an unknown word written by hand is an error
  local fp = made.path
  H.write(fp, (H.read(fp):gsub("severity: high", "severity: urgent")))
  res = assert(check.run({ root = root }))
  eq(codes(res), { "unknown-severity" })
  ok(not res.ok)
  H.write(fp, (H.read(fp):gsub("severity: urgent", "severity: high")))

  -- the index is generated as before: no severity in it (format unchanged)
  local text = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(not text:find("severity", 1, true), "TASKS.md has no severity column")

  -- ── CLI ─────────────────────────────────────────────────────────────────
  root = F.vault(H)
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return code, table.concat(out), table.concat(err)
  end
  local function cmd(...)
    local argv = { ... }
    argv[#argv + 1] = "--vault=" .. root
    argv[#argv + 1] = "--today=" .. TODAY
    return run(argv)
  end

  local code = cmd("new", "lib.nvim", "Zero", "--prio=1", "--effort=L")
  eq(code, 0)
  cmd("new", "lib.nvim", "One", "--prio=1", "--effort=XS")
  cmd("new", "lib.nvim", "Two", "--prio=1")
  cmd("new", "cascade.nvim", "Three", "--prio=2", "--effort=S")
  cmd("new", "lib.nvim", "Hole", "--kind=bug", "--severity=low", "--prio=1", "--effort=M")
  cmd("new", "cascade.nvim", "Burn", "--kind=bug", "--severity=critical", "--prio=3")
  cmd("new", "ALL", "Leak", "--category=security", "--severity=high", "--prio=2", "--effort=XL")

  local out
  code, out = cmd("list", "--format=ids")
  eq(code, 0)
  eq(vim.split(vim.trim(out), "\n"), {
    "lib.nvim/hole",
    "lib.nvim/one",
    "lib.nvim/two",
    "lib.nvim/zero",
    "ALL/leak",
    "cascade.nvim/three",
    "cascade.nvim/burn",
  }, "default order untouched")
  _, out = cmd("list", "--format=ids", "--sort=prio-effort")
  eq(vim.split(vim.trim(out), "\n"), {
    "lib.nvim/one",
    "lib.nvim/hole",
    "lib.nvim/zero",
    "lib.nvim/two",
    "cascade.nvim/three",
    "ALL/leak",
    "cascade.nvim/burn",
  }, "--sort=prio-effort: small first within a prio")
  _, out = cmd("list", "--format=ids", "--sort=severity")
  eq(vim.split(vim.trim(out), "\n"), {
    "cascade.nvim/burn",
    "ALL/leak",
    "lib.nvim/hole",
    "lib.nvim/one",
    "lib.nvim/two",
    "lib.nvim/zero",
    "cascade.nvim/three",
  }, "--sort=severity: critical first, then the default order")

  _, out = cmd("list", "--format=ids", "--effort=<=S", "--sort=prio-effort")
  eq(vim.split(vim.trim(out), "\n"), { "lib.nvim/one", "cascade.nvim/three" })
  _, out = cmd("list", "--format=ids", "--effort=XL,L")
  eq(vim.split(vim.trim(out), "\n"), { "lib.nvim/zero", "ALL/leak" })
  _, out = cmd("list", "--format=ids", "--severity=high,critical", "--sort=severity")
  eq(vim.split(vim.trim(out), "\n"), { "cascade.nvim/burn", "ALL/leak" })
  _, out = cmd("list", "--format=ids", "--category=bug", "--severity=low")
  eq(vim.split(vim.trim(out), "\n"), { "lib.nvim/hole" }, "filters combine")

  local err
  code, _, err = cmd("list", "--sort=best")
  eq(code, 2)
  has(err, "unknown --sort 'best'")
  code, _, err = cmd("list", "--effort=huge")
  eq(code, 2)
  has(err, "unknown effort in --effort: huge")
  code, _, err = cmd("list", "--severity=urgent")
  eq(code, 2)
  has(err, "unknown severity in --severity")
  code, _, err = cmd("new", "lib.nvim", "Bad sev", "--kind=bug", "--severity=urgent")
  eq(code, 1)
  has(err, "unknown severity")

  code, out = cmd("set", "lib.nvim/hole", "severity=medium")
  eq(code, 0)
  has(out, "set\tlib.nvim/hole\tchanged")
  _, out = cmd("list", "--format=ids", "--severity=medium")
  eq(vim.trim(out), "lib.nvim/hole")
  code, _, err = cmd("set", "lib.nvim/hole", "severity=urgent")
  eq(code, 1)
  has(err, "unknown severity")

  code, out = cmd("check")
  eq(code, 0, out)
  cmd("set", "lib.nvim/two", "severity=high")
  code, out = cmd("check")
  eq(code, 0, "a misplaced severity is not an error")
  has(out, "warn severity-without-bug-or-security")

  code, out = cmd("help")
  eq(code, 0)
  has(out, "--effort=S,M|<=M")
  has(out, "--severity=high,critical")
  has(out, "--sort=default|prio-effort|severity")

  -- ── dashboard core ──────────────────────────────────────────────────────
  ok(vim.tbl_contains(dash.FILTER_DIMS, "effort"))
  ok(vim.tbl_contains(dash.FILTER_DIMS, "severity"))
  eq(dash.dim_choices("severity", {}), model.SEVERITIES)
  eq(dash.dim_choices("effort", {}), { "XS", "S", "M", "L", "XL", "<=S", "<=M" })
  for _, choice in ipairs(dash.dim_choices("effort", {})) do
    ok(
      require("tasks_nvim.filter_opts").parse({ effort = choice }),
      "every menu entry is a valid filter"
    )
  end

  local ef = dash.set_dim({}, "effort", "S")
  eq(ef.effort, { "S" })
  eq(dash.chips(ef), { "effort: S" })
  local emax = dash.set_dim(ef, "effort", "<=M")
  eq(emax.effort_max, "M")
  eq(emax.effort, nil, "the <= form replaces a plain effort")
  eq(dash.chips(emax), { "effort: <=M" })
  eq(dash.set_dim(emax, "effort", "L").effort_max, nil, "a plain effort replaces the <= form")
  eq(dash.set_dim(emax, "effort", nil).effort_max, nil)
  local sv = dash.set_dim({}, "severity", "critical")
  eq(sv.severity, { "critical" })
  eq(dash.chips(sv), { "severity: critical" })
  eq(dash.set_dim(sv, "severity", nil).severity, nil)
  ok(not dash.filter_is_empty(sv))
  eq(
    dash.chips({ prio_max = 2, effort_max = "S", kind = { "bug" }, severity = { "high" } }),
    { "prio: <=2", "effort: <=S", "kind: bug", "severity: high" },
    "chips keep a fixed order"
  )

  eq(dash.filter_to_options(emax).effort, "<=M")
  eq(dash.filter_to_options(ef).effort, "S")
  eq(dash.filter_to_options(sv).severity, "critical")
  eq(dash.filter_from_stored({ effort = "<=M" }).effort_max, "M")
  eq(dash.filter_from_stored({ effort = "S,M" }).effort, { "S", "M" })
  eq(dash.filter_from_stored({ severity = "high,low" }).severity, { "high", "low" })
  eq(
    dash.filter_from_stored({ effort = "huge" }),
    {},
    "a stored filter that no longer parses is empty"
  )
  eq(dash.filter_from_stored({ severity = "urgent" }), {})
  local stored = vim.json.decode(vim.json.encode(dash.filter_to_options({
    effort = { "XS" },
    severity = { "high" },
  })))
  eq(dash.chips(dash.filter_from_stored(stored)), { "effort: XS", "severity: high" })

  -- sort state: chip, cycle, stored word
  eq(dash.sort_chip(nil), nil)
  eq(dash.sort_chip("default"), nil, "the default order shows no chip")
  eq(dash.sort_chip("prio-effort"), "sort: prio-effort")
  eq(dash.sort_chip("severity"), "sort: severity")
  eq(dash.sort_chip("bogus"), nil)
  eq(dash.cycle_sort(nil), "prio-effort")
  eq(dash.cycle_sort("default"), "prio-effort")
  eq(dash.cycle_sort("prio-effort"), "severity")
  eq(dash.cycle_sort("severity"), "frecency")
  eq(dash.cycle_sort("frecency"), "roi")
  eq(dash.cycle_sort("roi"), "default", "the cycle wraps around")
  eq(dash.sort_chip("frecency"), "sort: frecency")
  eq(dash.sort_chip("roi"), "sort: roi")
  eq(dash.cycle_sort("bogus"), "prio-effort", "an unknown order restarts after the default")
  eq(dash.sort_from_stored("severity"), "severity")
  eq(dash.sort_from_stored("bogus"), "default")
  eq(dash.sort_from_stored(nil), "default")
  eq(dash.sort_from_stored(42), "default")

  local shown = { s("only", "high", 1) }
  has(
    dash.header(shown, {}, nil, "prio-effort"),
    "[sort: prio-effort]",
    "the header shows the sort"
  )
  eq(
    dash.header(shown, {}, nil, "default"),
    dash.header(shown, {}, nil),
    "the default order adds nothing to the header"
  )
  has(dash.header(shown, { effort = { "S" } }, nil, "severity"), "[effort: S] [sort: severity]")

  -- list line: the severity is shown after the title, and searchable
  local line_task = s("line", "critical", 1)
  local w = dash.widths({ line_task })
  local line = dash.line(line_task, w)
  has(line, "[critical]")
  ok(line:find("line", 1, true) < line:find("[critical]", 1, true), "severity follows the title")
  ok(not dash.line(s("line", nil, 1), w):find("[", 1, true), "no severity, no chunk")
  has(dash.search_text(line_task), "critical")
  local parts = dash.parts(line_task, w)
  local sev_part
  for _, part in ipairs(parts) do
    if part[1]:find("critical", 1, true) then
      sev_part = part
    end
  end
  eq(sev_part[2], "DiagnosticError", "critical is highlighted as an error")

  -- load: filter and sort together, against the vault of the CLI part
  local loaded = assert(dash.load({
    root = root,
    filter = assert(require("tasks_nvim.filter_opts").parse({ category = "bug,security" })),
    sort = "severity",
  }))
  eq(order(loaded.tasks), { "burn", "leak", "hole" }, "the dashboard sorts like the CLI")
  loaded = assert(dash.load({ root = root, sort = "prio-effort" }))
  eq(loaded.tasks[1].id, "lib.nvim/one")
  loaded = assert(dash.load({ root = root }))
  eq(loaded.tasks[1].id, "lib.nvim/hole", "no sort: the default order")
end
