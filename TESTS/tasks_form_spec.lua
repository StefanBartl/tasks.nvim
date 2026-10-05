-- TESTS/tasks/tasks_form_spec.lua -- tasks.form: template, parsing, validation and the tick rules of the
-- `:Tasks new` form, all on plain strings (no buffer, no vault).

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local form = require("tasks_nvim.form")
  local model = require("tasks_nvim.model")

  ---@param lines string[]
  ---@param text string
  ---@return integer|nil
  local function find(lines, text)
    for i, l in ipairs(lines) do
      if l == text then
        return i
      end
    end
    return nil
  end

  -- ── template: the value sets come from the model ───────────────────────────
  local t = form.template({ areas = { "ALL", "lib.nvim" } })
  for _, kind in ipairs(model.KINDS) do
    ok(find(t, ("- [%s] %s"):format(kind == "task" and "x" or " ", kind)), "kind " .. kind)
  end
  for _, e in ipairs(model.EFFORTS) do
    ok(find(t, "- [ ] " .. e), "effort " .. e)
  end
  for _, c in ipairs(model.CATEGORIES) do
    ok(find(t, "- [ ] " .. c), "category " .. c)
  end
  for _, s in ipairs(model.SEVERITIES) do
    ok(find(t, "- [ ] " .. s), "severity " .. s)
  end
  for _, s in ipairs(model.OPEN_STATUSES) do
    ok(find(t, ("- [%s] %s"):format(s == "open" and "x" or " ", s)), "status " .. s)
  end
  ok(not find(t, "- [ ] done") and not find(t, "- [x] done"), "no done status in a new task form")
  has(table.concat(t, "\n"), "areas: ALL, lib.nvim")

  -- ── parse + validate: a filled-in form ─────────────────────────────────────
  local lines = form.template({ areas = { "ALL", "lib.nvim" } })
  lines[find(lines, "Area: ")] = "Area: lib.nvim"
  lines[find(lines, "Title: ")] = "Title: Fix: the thing"
  lines = form.toggle(lines, find(lines, "- [ ] bug")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] 2")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] S")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] docs")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] security")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] high")) --[[@as string[] ]]
  lines = form.toggle(lines, find(lines, "- [ ] doing")) --[[@as string[] ]]
  lines[find(lines, "Tags: ")] = "Tags: ui, perf"
  lines[find(lines, "Refs: ")] = "Refs: lua/x.lua"

  local values, errs = form.validate(form.parse(lines), { "ALL", "lib.nvim" })
  eq(errs, {})
  eq(values and values.area, "lib.nvim")
  eq(values and values.opts, {
    title = "Fix: the thing",
    kind = "bug",
    prio = "2",
    effort = "S",
    category = "security,docs",
    severity = "high",
    status = "doing",
    tags = "ui, perf",
    refs = "lua/x.lua",
  })

  -- ── single choice: ticking moves the tick, ticking again clears it ─────────
  ---@param ls string[]
  ---@param text string  the bullet line to flip (first match)
  ---@return string[]
  local function tog(ls, text)
    return assert(form.toggle(ls, assert(find(ls, text))))
  end
  local k = form.template({})
  local k2 = tog(k, "- [ ] idea")
  ok(find(k2, "- [x] idea") and find(k2, "- [ ] task"), "one tick moves")
  ok(find(tog(k2, "- [x] idea"), "- [ ] idea"), "ticking again clears")
  local k3 = tog(k, "- [x] task")
  ok(find(k3, "- [ ] task"), "untick the default")
  eq(form.parse(k3).ticks.kind, {}, "kind may stay empty: the engine default applies")
  ok(find(k2, "- [x] open"), "the neighbouring list keeps its tick")
  -- multi choice keeps both ticks
  local c = tog(tog(k, "- [ ] docs"), "- [ ] security")
  ok(find(c, "- [x] docs") and find(c, "- [x] security"), "category takes several")
  eq(form.parse(c).ticks.category, { "security", "docs" })

  -- not a choice bullet
  eq(form.toggle(k, find(k, "Area: ")), nil)
  eq(form.toggle(k, 999), nil)

  -- ── validate: errors, nothing silently dropped ─────────────────────────────
  local bad = form.template({})
  bad[find(bad, "Area: ")] = "Area: nowhere"
  local v2, e2 = form.validate(form.parse(bad), { "ALL" })
  eq(v2, nil)
  eq(#e2, 2, "unknown area and empty title")
  has(table.concat(e2, "\n"), "'nowhere' is not an area")
  has(table.concat(e2, "\n"), "Title is required")

  local many = form.template({ area = "ALL", title = "X" })
  many[find(many, "- [ ] idea")] = "- [x] idea" -- task is ticked as well: hand-edited
  local v3, e3 = form.validate(form.parse(many), { "ALL" })
  eq(v3, nil)
  has(table.concat(e3, "\n"), "kind: pick one")

  -- unknown choice typed by hand
  local odd = form.template({ area = "ALL", title = "X" })
  odd[#odd + 1] = ""
  table.insert(odd, find(odd, "- [ ] low"), "- [x] gigantic")
  local _, e4 = form.validate(form.parse(odd), { "ALL" })
  has(table.concat(e4, "\n"), "unknown choice: severity: gigantic")

  -- without an area list the area is only checked for being present
  local v5 = form.validate(form.parse(form.template({ area = "x", title = "y" })))
  ok(v5 and v5.area == "x")

  -- ── error report lines are not form content ────────────────────────────────
  local withrep =
    vim.list_extend(form.error_lines({ "boom" }), form.template({ area = "ALL", title = "T" }))
  eq(form.parse(withrep).title, "T")
  eq(form.strip_errors(withrep), form.template({ area = "ALL", title = "T" }))

  -- ── normalize: several ticks left by a foreign toggle collapse onto `keep` ──
  local n = form.template({})
  n[find(n, "- [ ] bug")] = "- [x] bug"
  local fixed = form.normalize(n, find(n, "- [x] bug"))
  ok(find(fixed, "- [x] bug") and find(fixed, "- [ ] task"), "bug kept, task cleared")

  -- ── pre-ticked values ──────────────────────────────────────────────────────
  local pre =
    form.template({ ticks = { kind = "bug", category = { "docs", "ruleset" } }, tags = "a" })
  ok(find(pre, "- [x] bug") and find(pre, "- [ ] task"))
  ok(find(pre, "- [x] docs") and find(pre, "- [x] ruleset"))
  ok(find(pre, "Tags: a"))
end
