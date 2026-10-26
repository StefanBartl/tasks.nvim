-- TESTS/tasks/tasks_form_spec.lua -- tasks.form: template, parsing, validation and the tick rules of the
-- `:Tasks new` form, all on plain strings (no buffer, no vault).

---@diagnostic disable: param-type-mismatch
-- Why: a value that can be nil is bound and then asserted by the next ok()/eq() of the same body, so a nil fails the spec at that line; some specs feed wrong types or incomplete tables on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
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

  -- the folder's name is what is meant: a near miss says which areas come close
  local near = form.template({ area = "hover", title = "X" })
  local _, e_near = form.validate(form.parse(near), { "ALL", "hover.nvim", "lib.nvim" })
  has(e_near[1], "'hover' is not an area of the vault (did you mean: hover.nvim?)")
  local _, e_far = form.validate(form.parse(near), { "ALL", "lib.nvim" })
  ok(not e_far[1]:find("did you mean", 1, true), "no guess when nothing comes close")
  -- the ones that start with the name come first, case does not matter, three at most
  local pick = form.template({ area = "NVIM", title = "X" })
  local _, e_pick =
    form.validate(form.parse(pick), { "a.nvim", "nvim.one", "b.nvim", "nvim.two", "nvim.three" })
  has(e_pick[1], "(did you mean: nvim.one, nvim.two, nvim.three?)")
  -- the one helper the commands, the routes and the dashboard share
  local vault = require("tasks_nvim.vault")
  eq(vault.not_an_area_message("zzz", { "ALL", "lib.nvim" }), "'zzz' is not an area of the vault")
  has(vault.not_an_area_message("lib", { "ALL", "lib.nvim" }), "(did you mean: lib.nvim?)")
  local mix = form.template({ area = "nvim", title = "X" })
  local _, e_mix = form.validate(form.parse(mix), { "a.nvim", "nvim.one" })
  has(e_mix[1], "(did you mean: nvim.one, a.nvim?)")

  -- a vault without areas: no name can pass, so the report blames the vault, not the name, and says where it looked
  local right_name = form.template({ area = "hover.nvim", title = "X" })
  local v_none, e_none = form.validate(form.parse(right_name), {}, "E:/repos/old-vault")
  eq(v_none, nil)
  eq(#e_none, 1, "one report, not one per field")
  has(e_none[1], "The vault has no areas: E:/repos/old-vault")
  has(e_none[1], "restart Neovim")
  ok(not e_none[1]:find("is not an area", 1, true), "the typed name is not blamed")
  local _, e_none_bare = form.validate(form.parse(right_name), {})
  has(e_none_bare[1], "The vault has no areas (")
  eq(e_none_bare[1], form.no_areas_message(nil), "the report is the one text of the module")
  eq(form.no_areas_message(""), form.no_areas_message(nil), "an empty folder is no folder")
  has(form.no_areas_message("/x"), "$TASKS_VAULT", "every way the vault is named is mentioned")
  local _, e_none_blank = form.validate(form.parse(form.template({})), {}, "E:/repos/old-vault")
  lacks(
    table.concat(e_none_blank, "\n"),
    "Area is required",
    "an empty area line does not add a second area report"
  )
  has(table.concat(e_none_blank, "\n"), "Title is required", "the other fields are still checked")

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

  -- ── summary and the body sections are part of the form ─────────────────────
  local tb = form.template({ area = "ALL", title = "T", summary = "One line" })
  ok(find(tb, "Summary: One line"), "summary line")
  ok(find(tb, "## Kontext") and find(tb, "## Akzeptanz") and find(tb, "## Notizen"), "de headings")
  ok(find(form.template({ lang = "en" }), "## Acceptance"), "en headings on request")
  local filled = vim.deepcopy(tb)
  table.insert(filled, find(filled, "## Kontext") + 1, "Why: because")
  table.insert(filled, find(filled, "## Akzeptanz") + 1, "first check")
  table.insert(filled, find(filled, "## Akzeptanz") + 2, "- [x] done check")
  table.insert(filled, find(filled, "## Notizen") + 1, "Refs: not a field here")
  local pb = form.parse(filled)
  eq(pb.summary, "One line")
  eq(pb.sections.context, "Why: because", "a `Key:` line in a section is text, not a field")
  eq(pb.sections.notes, "Refs: not a field here")
  eq(pb.refs, "", "the Refs field is untouched by that text")
  local vb = assert(form.validate(pb, { "ALL" }))
  eq(vb.opts.summary, "One line")
  has(vb.opts.body, "## Kontext\n\nWhy: because")
  has(vb.opts.body, "## Akzeptanz\n\n- [ ] first check\n- [x] done check")
  has(vb.opts.body, "## Notizen\n\nRefs: not a field here")
  ok(vb.opts.body:find("<!--", 1, true) == nil, "no placeholder when every section has text")
  -- nothing typed: no body, the engine writes its own sections
  local plain = assert(form.validate(form.parse(tb), { "ALL" }))
  eq(plain.opts.body, nil)
  -- one section typed: the others keep the invisible placeholder
  local one = vim.deepcopy(tb)
  table.insert(one, find(one, "## Notizen") + 1, "n")
  local ov = assert(form.validate(form.parse(one), { "ALL" }))
  has(ov.opts.body, "## Kontext\n\n<!--")
  has(ov.opts.body, "## Notizen\n\nn")
  -- English headings are read as well, and the body follows the language asked for
  local en = form.template({ area = "ALL", title = "T", lang = "en" })
  table.insert(en, find(en, "## Context") + 1, "ctx")
  local ev = assert(form.validate(form.parse(en), { "ALL" }, nil, "en"))
  has(ev.opts.body, "## Context\n\nctx")
  has(ev.opts.body, "## Acceptance")

  -- ── the fields of the form are the fields `new` takes (the write door), minus the slug ──
  -- The capture dialog of tasks-desktop is held to the same list (`ui/src/lib/captureFields.test.ts` there): a field
  -- added to the engine's `new` has to be in both forms, or in the list of what a form leaves out on purpose.
  local FORM_FIELDS = {
    "actor",
    "category",
    "effort",
    "kind",
    "links",
    "prio",
    "refs",
    "severity",
    "status",
    "summary",
    "tags",
    "value",
  }
  local in_form = {}
  for _, f in ipairs(form.fields()) do
    in_form[#in_form + 1] = f.name
  end
  vim.list_extend(in_form, { "tags", "refs", "links", "summary" })
  table.sort(in_form)
  eq(in_form, FORM_FIELDS, "the fields of the :Tasks new form")
  local engine_new = {}
  for name in pairs(require("tasks_nvim.ops").NEW_FIELDS) do
    if name ~= "slug" then
      engine_new[#engine_new + 1] = name
    end
  end
  table.sort(engine_new)
  eq(
    engine_new,
    FORM_FIELDS,
    "a field of `new` that no form offers (add it to both forms, or leave it out here)"
  )

  -- ── Links: web addresses only, apart from Refs ─────────────────────────────
  local lk = form.template({ area = "ALL", title = "T", links = "https://a.org/x#y, http://b.io" })
  ok(find(lk, "Links: https://a.org/x#y, http://b.io"), "prefilled")
  local lv = assert(form.validate(form.parse(lk), { "ALL" }))
  eq(lv.opts.web_links, "https://a.org/x#y, http://b.io")
  eq(lv.opts.refs, nil, "links are not refs")
  local lbad =
    form.template({ area = "ALL", title = "T", links = "https://ok.org, ftp://no, lua/x.lua" })
  local _, le = form.validate(form.parse(lbad), { "ALL" })
  eq(#le, 2)
  has(le[1], "ftp://no")
  has(le[2], "lua/x.lua")
  eq(
    assert(form.validate(form.parse(form.template({ area = "ALL", title = "T" })), { "ALL" })).opts.web_links,
    nil
  )

  -- ── a heading inside a text is text, not the start of a section ────────────
  local hd = form.template({ area = "ALL", title = "T" })
  table.insert(hd, find(hd, "## Kontext") + 1, "## Notes about the thing")
  table.insert(hd, find(hd, "## Kontext") + 2, "kept")
  local hp = form.parse(hd)
  eq(hp.sections.context, "## Notes about the thing\nkept")
  eq(hp.sections.notes, "")

  -- ── the headings and hints of the body sections: the same text as the capture dialog of tasks-desktop ──
  -- `ui/src/lib/fields.test.ts` there pins the same two strings; change one side and the other names it.
  local sample = { context = "Why", acceptance = "works\n- [x] kept", notes = "" }
  eq(
    require("tasks_nvim.mutate").body_sections(sample, "en"),
    table.concat({
      "## Context",
      "",
      "Why",
      "",
      "## Acceptance",
      "",
      "- [ ] works",
      "- [x] kept",
      "",
      "## Notes",
      "",
      "<!-- Decisions, dead ends, references. -->",
      "",
    }, "\n")
  )
  eq(
    require("tasks_nvim.mutate").body_sections({ context = "", acceptance = "", notes = "n" }, "de"),
    table.concat({
      "## Kontext",
      "",
      "<!-- Warum, woher kam das. -->",
      "",
      "## Akzeptanz",
      "",
      "<!-- was am Ende wahr sein muss, als Checkliste -->",
      "",
      "## Notizen",
      "",
      "n",
      "",
    }, "\n")
  )

  -- ── a `!` line of a text is text; only the report at the top is stripped ────
  local img = form.template({ area = "ALL", title = "T" })
  table.insert(img, find(img, "## Kontext") + 1, "![shot](assets/a.png)")
  table.insert(img, find(img, "## Kontext") + 2, "!important: keep")
  local with_report = vim.list_extend(form.error_lines({ "boom" }), img)
  eq(form.strip_errors(with_report), img, "the report goes, the text stays")
  eq(form.parse(with_report).sections.context, "![shot](assets/a.png)\n!important: keep")
  eq(form.parse(form.strip_errors(img)).title, "T")

  -- ── several areas: one task each ───────────────────────────────────────────
  eq(form.split_areas(" a , b,,a "), { "a", "b" }, "trimmed, once each, in the order typed")
  local ma = form.template({ area = "ALL, lib.nvim", title = "T" })
  local mv = assert(form.validate(form.parse(ma), { "ALL", "lib.nvim" }))
  eq(mv.areas, { "ALL", "lib.nvim" })
  eq(mv.area, "ALL", "`area` stays the first one")
  local _, me = form.validate(form.parse(form.template({ area = "ALL, nope", title = "T" })), {
    "ALL",
  })
  eq(#me, 1)
  has(me[1], "nope")
  local _, me2 = form.validate(form.parse(form.template({ area = " , ", title = "T" })), { "ALL" })
  eq(me2, { "Area is required" })
end
