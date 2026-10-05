-- TESTS/tasks/tasks_mutate_spec.lua -- tasks.mutate: template, new, set, done, the Backlog README.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local fsio = require("tasks_nvim.fsio")

  --- Make every write of a `TASKS.md` fail until the returned function is called.
  ---@return fun() restore
  local function fail_index_writes()
    local orig = fsio.write_atomic
    fsio.write_atomic = function(path, content)
      if path:match("TASKS%.md$") then
        return false, "stubbed write failure"
      end
      return orig(path, content)
    end
    return function()
      fsio.write_atomic = orig
    end
  end

  local TODAY = F.TODAY
  local cpdir = H.tmpdir() .. "/checkpoints"

  --- A fresh vault; returns it and a table of default engine options.
  local function setup()
    local root = F.vault(H)
    return root, { root = root, today = TODAY, checkpoint_dir = cpdir }
  end

  --- Options for `new`/`set`/`done` plus extras.
  local function with(base, extra)
    return vim.tbl_extend("force", base, extra or {})
  end

  --- Number of entries (files and directories) directly in `dir`.
  local function count_entries(dir)
    local n = 0
    for _ in vim.fs.dir(dir) do
      n = n + 1
    end
    return n
  end

  -- ── slugify ─────────────────────────────────────────────────────────────
  local slugs = {
    ["Picker-Items als eigene Quelle"] = "picker-items-als-eigene-quelle",
    ["Größe ändern: Über/Unter"] = "groesse-aendern-ueber-unter",
    ["Café Crème Brûlée"] = "cafe-creme-brulee",
    ["ALL CAPS Title"] = "all-caps-title",
    ["a__b  c"] = "a-b-c",
    ["  --  "] = "task",
    [""] = "task",
    ["日本語 test"] = "test",
    ["Fix #12: it breaks!"] = "fix-12-it-breaks",
    ["v2.0 release"] = "v2-0-release",
  }
  for title, want in pairs(slugs) do
    eq(mutate.slugify(title), want, "slugify " .. title)
  end
  local long = mutate.slugify(("word "):rep(40))
  ok(#long <= mutate.MAX_SLUG, "slug length is capped: " .. #long)
  ok(require("tasks_nvim.vault").valid_slug(long), "a capped slug is still a slug: " .. long)
  for title in pairs(slugs) do
    ok(require("tasks_nvim.vault").valid_slug(mutate.slugify(title)), "valid slug for " .. title)
  end

  -- ── template ────────────────────────────────────────────────────────────
  local tpl = mutate.template({ today = TODAY })
  eq(
    tpl,
    table.concat({
      "---",
      "title: Titel",
      "status: open",
      "kind: task",
      "prio: 2",
      "effort: M",
      "tags: []",
      "created: 2026-10-03",
      "updated: 2026-10-03",
      "---",
      "",
      "Eine Zeile Zusammenfassung — sie landet im Index.",
      "",
      "## Kontext",
      "",
      "Warum, woher kam das.",
      "",
      "## Akzeptanz",
      "",
      "- [ ] was am Ende wahr sein muss",
      "",
      "## Notizen",
      "",
      "Entscheidungen, Sackgassen, Verweise.",
      "",
    }, "\n"),
    "template text"
  )
  local tpl_task = model.parse_text(tpl, { path = "/v/x/ROADMAP/tasks/t.md", area = "x" })
  ok(tpl_task.valid, "the template is itself a valid task: " .. vim.inspect(tpl_task.errors))
  local tpl2 = mutate.template({
    today = TODAY,
    title = "Mein Task",
    kind = "bug",
    prio = 1,
    effort = "2d",
    tags = { "a", "b" },
  })
  has(tpl2, "title: Mein Task")
  has(tpl2, "kind: bug")
  has(tpl2, "prio: 1")
  has(tpl2, "effort: 2d")
  has(tpl2, "tags: [a, b]")

  -- ── new ─────────────────────────────────────────────────────────────────
  local root, o = setup()

  local res =
    assert(mutate.new("lib.nvim", with(o, { title = "Picker items as their own source" })))
  eq(res.id, "lib.nvim/picker-items-as-their-own-source")
  eq(res.slug, "picker-items-as-their-own-source")
  eq(res.path, root .. "/lib.nvim/ROADMAP/tasks/picker-items-as-their-own-source.md")
  local text = H.read(res.path)
  ok(
    text:find(
      "^%-%-%-\ntitle: Picker items as their own source\nstatus: open\nkind: task\ncreated: 2026%-10%-03\nupdated: 2026%-10%-03\n%-%-%-\n"
    ),
    "frontmatter: " .. text
  )
  ok(not text:find("\r", 1, true), "LF")
  local parsed = scan.find(res.id, { root = root })
  ok(parsed.valid, vim.inspect(parsed.errors))
  eq(parsed.status, "open")
  eq(parsed.kind, "task")
  eq(parsed.created, TODAY)
  eq(parsed.updated, TODAY)
  eq(parsed.prio, nil, "prio is only written when given")
  eq(parsed.summary, "", "no placeholder sentence leaks into the summary")
  eq(res.index.action, "written", "the area index is regenerated")
  local idx = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  has(idx, "[Picker items as their own source](tasks/picker-items-as-their-own-source.md)")

  -- all options
  local full = assert(mutate.new(
    "cascade.nvim",
    with(o, {
      title = 'Cycle: Count #2 "quoted"',
      kind = "feature",
      prio = 1,
      effort = "0.5d",
      tags = { "ui", "needs-live-test" },
      status = "doing",
      summary = "Count support for the cycle verb.",
    })
  ))
  local f = scan.find(full.id, { root = root })
  ok(f.valid, vim.inspect(f.errors))
  eq(f.title, 'Cycle: Count #2 "quoted"', "a title with : # and quotes round-trips")
  eq(f.kind, "feature")
  eq(f.prio, 1)
  eq(f.effort, "0.5d")
  eq(f.tags, { "ui", "needs-live-test" })
  eq(f.status, "doing")
  eq(f.summary, "Count support for the cycle verb.", "summary becomes the first paragraph")
  eq(full.slug, "cycle-count-2-quoted")

  -- tags as a comma string (what the CLI passes)
  local csv = assert(mutate.new("cascade.nvim", with(o, { title = "Csv tags", tags = "a, b ,c" })))
  eq(scan.find(csv.id, { root = root }).tags, { "a", "b", "c" })

  -- refs: a comma string or a list, written after `updated`
  local with_refs = assert(
    mutate.new(
      "cascade.nvim",
      with(o, { title = "With refs", refs = "lua/x.lua, lib.nvim@abc1234" })
    )
  )
  eq(
    scan.find(with_refs.id, { root = root }).refs,
    { "lua/x.lua", "lib.nvim@abc1234" },
    "refs given to new"
  )
  local bad_refs = mutate.new("cascade.nvim", with(o, { title = "Bad refs", refs = 5 }))
  eq(bad_refs, nil, "refs must be a list or a string")

  -- lang: English headings on request, German by default, anything else is refused
  local en = assert(mutate.new("cascade.nvim", with(o, { title = "English body", lang = "en" })))
  local en_text = H.read(en.path)
  has(en_text, "## Context")
  has(en_text, "## Acceptance")
  has(en_text, "## Notes")
  ok(not en_text:find("Kontext", 1, true), "no German heading in an English body")
  has(H.read(csv.path), "## Kontext", "German stays the default")
  local bad_lang =
    select(2, mutate.new("cascade.nvim", with(o, { title = "Bad lang", lang = "fr" })))
  has(bad_lang, "unknown lang", "an unknown lang is refused")
  has(mutate.template({ today = TODAY, lang = "en" }), "## Acceptance", "template in English")
  has(mutate.template({ today = TODAY }), "## Akzeptanz", "template in German by default")

  -- slug collisions: -2, -3 ...; an existing file is never overwritten
  local first = assert(mutate.new("lib.nvim", with(o, { title = "Same title" })))
  H.write(first.path, H.read(first.path) .. "\nMARKER-first\n")
  local second = assert(mutate.new("lib.nvim", with(o, { title = "Same title" })))
  local third = assert(mutate.new("lib.nvim", with(o, { title = "Same title" })))
  eq(first.slug, "same-title")
  eq(second.slug, "same-title-2")
  eq(third.slug, "same-title-3")
  has(H.read(first.path), "MARKER-first", "the first file was not touched by the later ones")
  ok(not H.read(second.path):find("MARKER", 1, true))

  -- a slug used in Backlog/ is taken too (ids are global)
  H.write(root .. "/lib.nvim/Backlog/TASKS/2026-01-01_taken.md", F.text(F.meta("Old", "done")))
  H.write(root .. "/lib.nvim/Backlog/TASKS/untitled-audit.md", "# prose\n")
  eq(assert(mutate.new("lib.nvim", with(o, { title = "Taken" }))).slug, "taken-2")
  eq(
    assert(mutate.new("lib.nvim", with(o, { title = "Untitled audit" }))).slug,
    "untitled-audit-2",
    "free-form Backlog documents reserve their slug too"
  )

  -- explicit slug: honoured, and an error when taken
  eq(
    assert(mutate.new("lib.nvim", with(o, { title = "Whatever", slug = "my-slug" }))).slug,
    "my-slug"
  )
  local dup, dup_err = mutate.new("lib.nvim", with(o, { title = "Whatever", slug = "my-slug" }))
  eq(dup, nil)
  has(dup_err, "already exists")

  -- an area that only has Backlog/ (ALL) gets its ROADMAP/tasks created
  local in_all = assert(mutate.new("ALL", with(o, { title = "Cross cutting" })))
  ok(H.exists(root .. "/ALL/ROADMAP/tasks/cross-cutting.md"))
  ok(H.exists(root .. "/ALL/ROADMAP/TASKS.md"))
  eq(in_all.id, "ALL/cross-cutting")

  -- index = false: no TASKS.md
  local quiet = assert(mutate.new("migrate.nvim", with(o, { title = "Quiet", index = false })))
  eq(quiet.index, nil)
  ok(not H.exists(root .. "/migrate.nvim/ROADMAP/TASKS.md"), "index = false writes no index")

  -- invalid input: an error, and nothing is created
  local rejects = {
    { { title = "T" }, "nope.nvim", "unknown area" },
    { { title = "T" }, "../etc", "unknown area" },
    { { title = "T" }, "filetreepicker.nvim", "unknown area" },
    { { title = "" }, "lib.nvim", "must not be empty" },
    { { title = "   " }, "lib.nvim", "must not be empty" },
    { { title = "two\nlines" }, "lib.nvim", "single line" },
    { { title = 5 }, "lib.nvim", "must be text" },
    { { title = "T", kind = "epic" }, "lib.nvim", "unknown kind" },
    { { title = "T", prio = 7 }, "lib.nvim", "prio must be" },
    { { title = "T", effort = "huge" }, "lib.nvim", "effort" },
    { { title = "T", status = "done" }, "lib.nvim", "unknown status" },
    { { title = "T", status = "wip" }, "lib.nvim", "unknown status" },
    { { title = "T", tags = { "a,b" } }, "lib.nvim", "must not contain" },
    { { title = "T", tags = { "[x]" } }, "lib.nvim", "must not contain" },
    { { title = "T", summary = "a\nb" }, "lib.nvim", "single line" },
    { { title = "T", slug = "Bad Slug" }, "lib.nvim", "invalid slug" },
    { { title = "T", today = "soon" }, "lib.nvim", "not a date" },
  }
  local tasks_dir = root .. "/lib.nvim/ROADMAP/tasks"
  local entries_before = count_entries(tasks_dir)
  for i, case in ipairs(rejects) do
    local r, err = mutate.new(case[2], with(o, case[1]))
    eq(r, nil, "rejected case " .. i)
    has(err, case[3], "case " .. i)
  end
  eq(count_entries(tasks_dir), entries_before, "a rejected new creates nothing")

  -- ── set ─────────────────────────────────────────────────────────────────
  root, o = setup()
  local set_path = F.task(H, root, "lib.nvim", "target", {
    { "title", "Target" },
    { "status", "open" },
    { "kind", "task" },
    { "prio", "3" },
    { "tags", "[a]" },
    { "created", "2026-09-01" },
    { "updated", "2026-09-01" },
    { "custom_field", "keep me" },
  }, "\nSummary stays.\n\n## Notes\nBody stays.\n")

  local s1 = assert(mutate.set("lib.nvim/target", { status = "doing", prio = "1" }, o))
  eq(s1.changed, true)
  eq(s1.id, "lib.nvim/target")
  eq(
    H.read(set_path),
    table.concat({
      "---",
      "title: Target",
      "status: doing",
      "kind: task",
      "prio: 1",
      "tags: [a]",
      "created: 2026-09-01",
      "updated: 2026-10-03",
      "custom_field: keep me",
      "---",
      "",
      "Summary stays.",
      "",
      "## Notes",
      "Body stays.",
      "",
    }, "\n"),
    "only the named keys and updated changed; unknown key, body and order intact"
  )
  has(
    H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
    "| doing | 1 | – | [Target](tasks/target.md)",
    "the index follows"
  )

  -- a no-op patch changes nothing and does not bump updated
  local after_first = H.read(set_path)
  local s2 = assert(
    mutate.set("lib.nvim/target", { status = "doing", prio = 1 }, with(o, { today = "2027-01-01" }))
  )
  eq(s2.changed, false)
  eq(H.read(set_path), after_first, "no write for an unchanged patch")

  -- remove keys; list and csv values
  assert(mutate.set("lib.nvim/target", {
    prio = mutate.REMOVE,
    effort = "S",
    tags = "x, y",
    refs = { "lib.nvim@abc1234" },
    blocked_by = "cascade.nvim/other",
  }, o))
  local t = scan.find("lib.nvim/target", { root = root })
  eq(t.prio, nil)
  eq(t.effort, "S")
  eq(t.tags, { "x", "y" })
  eq(t.refs, { "lib.nvim@abc1234" })
  eq(t.blocked_by, { "cascade.nvim/other" })
  ok(not H.read(set_path):find("prio:", 1, true), "REMOVE deletes the line")
  assert(mutate.set("lib.nvim/target", { tags = mutate.REMOVE, blocked_by = {} }, o))
  eq(scan.find("lib.nvim/target", { root = root }).tags, {}, "removed")
  ok(not H.read(set_path):find("blocked_by", 1, true), "an empty list removes the key")
  assert(mutate.set("lib.nvim/target", { summary = "Frontmatter summary" }, o))
  eq(scan.find("lib.nvim/target", { root = root }).summary, "Frontmatter summary")

  -- refs and commits may hold characters a tag may not (#, commas, quotes); they round-trip
  assert(mutate.set("lib.nvim/target", { refs = { "PR #12", "a, b", 'say "x"' } }, o))
  eq(scan.find("lib.nvim/target", { root = root }).refs, { "PR #12", "a, b", 'say "x"' })

  -- a bracketed string (the way the file shows a list) is the list, not "[a" and "b]"
  assert(mutate.set("lib.nvim/target", { refs = "[lua/x.lua, lib.nvim@abc1234]" }, o))
  eq(
    scan.find("lib.nvim/target", { root = root }).refs,
    { "lua/x.lua", "lib.nvim@abc1234" },
    "outer brackets are dropped"
  )
  assert(mutate.set("lib.nvim/target", { tags = "[a, b]" }, o))
  eq(scan.find("lib.nvim/target", { root = root }).tags, { "a", "b" }, "same for tags")
  assert(mutate.set("lib.nvim/target", { done_in = "see #7" }, o))
  eq(scan.find("lib.nvim/target", { root = root }).done_in, "see #7")
  local bad_tag = mutate.set("lib.nvim/target", { tags = { "a #b" } }, o)
  eq(bad_tag, nil, "tags stay strict")

  -- rejected patches change nothing
  local snapshot = H.read(set_path)
  local bad_patches = {
    { {}, "nothing to set" },
    { { status = "done" }, "finishing the task" },
    { { status = "wip" }, "unknown status" },
    { { status = mutate.REMOVE }, "cannot be removed" },
    { { title = mutate.REMOVE }, "cannot be removed" },
    { { title = "a\nb" }, "single line" },
    { { kind = "epic" }, "unknown kind" },
    { { prio = "9" }, "prio must be" },
    { { effort = "xl" }, "effort" },
    { { created = "2026-99-99" }, "not a date" },
    { { updated = "2026-01-01" }, "set by the tool" },
    { { colour = "red" }, "unknown field" },
    { { blocked_by = "no-slash" }, "blocked_by" },
    { { blocked_by = "a/b/c" }, "blocked_by" },
    { { tags = { "a,b" } }, "must not contain" },
    { { ["bad key"] = "x" }, "unknown field" },
  }
  for i, case in ipairs(bad_patches) do
    local r, err = mutate.set("lib.nvim/target", case[1], o)
    eq(r, nil, "bad patch " .. i)
    has(err, case[2], "bad patch " .. i)
  end
  eq(H.read(set_path), snapshot, "rejected patches left the file alone")

  local nf, nf_err = mutate.set("lib.nvim/missing", { status = "doing" }, o)
  eq(nf, nil)
  has(nf_err, "no such open task")
  local bad_id, bad_id_err = mutate.set("lib.nvim", { status = "doing" }, o)
  eq(bad_id, nil)
  ok(bad_id_err)

  -- allow_unknown lets a custom field through
  assert(mutate.set("lib.nvim/target", { colour = "red" }, with(o, { allow_unknown = true })))
  has(H.read(set_path), "colour: red")

  -- a file without frontmatter cannot be patched (and is not damaged)
  local nofm = root .. "/lib.nvim/ROADMAP/tasks/no-frontmatter.md"
  H.write(nofm, "just prose\n")
  local nr, nerr = mutate.set("lib.nvim/no-frontmatter", { status = "doing" }, o)
  eq(nr, nil)
  ok(nerr)
  eq(H.read(nofm), "just prose\n")

  -- CRLF file keeps CRLF and everything else byte for byte
  local crlf_path = root .. "/lib.nvim/ROADMAP/tasks/crlf-set.md"
  H.write(
    crlf_path,
    H.crlf(F.text({
      { "title", "Windows" },
      { "status", "open" },
      { "updated", "2026-09-01" },
    }, "\nBody line.\n\nSecond.\n"))
  )
  assert(mutate.set("lib.nvim/crlf-set", { status = "parked" }, o))
  eq(
    H.read(crlf_path),
    H.crlf(
      "---\ntitle: Windows\nstatus: parked\nupdated: 2026-10-03\n---\n\nBody line.\n\nSecond.\n"
    ),
    "CRLF kept, only status and updated rewritten"
  )

  -- a failing index does not fail the set (the task file is the truth)
  local restore_writes = fail_index_writes()
  H.write(root .. "/lib.nvim/ROADMAP/TASKS.md", "stale\n")
  local soft = assert(mutate.set("lib.nvim/target", { prio = 2 }, o))
  eq(soft.changed, true)
  ok(soft.index_err, "the index failure is reported, not raised")
  restore_writes()

  -- index = false
  H.write(root .. "/lib.nvim/ROADMAP/TASKS.md", "stale\n")
  assert(mutate.set("lib.nvim/target", { prio = 3 }, with(o, { index = false })))
  eq(
    H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"),
    "stale\n",
    "index = false leaves the index alone"
  )

  -- ── readme_add_row ──────────────────────────────────────────────────────
  local row = "| [`2026-10-03_x.md`](./FEATURES/2026-10-03_x.md) | X (2026-10-03) |"
  local added, changed =
    mutate.readme_add_row(F.EMPTY_BACKLOG_README, "FEATURES", "2026-10-03_x.md", row)
  eq(changed, true)
  eq(
    added,
    table.concat({
      "# X — Backlog",
      "",
      "Erledigtes Material und Nachweise zu diesem Bereich.",
      "",
      "## FEATURES (1)",
      "",
      "| Datei | Inhalt |",
      "|---|---|",
      row,
      "",
      "## TASKS (0)",
      "",
      "_noch leer_",
      "",
    }, "\n"),
    "placeholder replaced by a table, count updated, the other section untouched"
  )
  local again, again_changed = mutate.readme_add_row(added, "FEATURES", "2026-10-03_x.md", row)
  eq(again_changed, false, "the same file twice adds nothing")
  eq(again, added)

  local row2 = "| [`2026-10-04_y.md`](./FEATURES/2026-10-04_y.md) | Y (2026-10-04) |"
  local two = mutate.readme_add_row(added, "FEATURES", "2026-10-04_y.md", row2)
  has(two, "|---|---|\n" .. row2 .. "\n" .. row .. "\n", "newest row on top")
  has(two, "## FEATURES (2)")

  -- a wrong count is recomputed, not incremented
  local miscounted = added:gsub("## FEATURES %(1%)", "## FEATURES (7)")
  has(mutate.readme_add_row(miscounted, "FEATURES", "2026-10-04_y.md", row2), "## FEATURES (2)")

  -- the TASKS section is independent
  local tasks_row = "| [`2026-10-03_t.md`](./TASKS/2026-10-03_t.md) | T (2026-10-03) |"
  local both = mutate.readme_add_row(added, "TASKS", "2026-10-03_t.md", tasks_row)
  has(both, "## FEATURES (1)")
  has(both, "## TASKS (1)\n\n| Datei | Inhalt |\n|---|---|\n" .. tasks_row .. "\n")

  -- a missing section is appended; no trailing newline and CRLF are kept
  local bare = "# Title\n\nintro"
  local appended = mutate.readme_add_row(bare, "TASKS", "2026-10-03_t.md", tasks_row)
  eq(
    appended,
    "# Title\n\nintro\n\n## TASKS (1)\n\n| Datei | Inhalt |\n|---|---|\n" .. tasks_row,
    "appended, no trailing newline added"
  )
  local crlf_readme = H.crlf(F.EMPTY_BACKLOG_README)
  local crlf_out = mutate.readme_add_row(crlf_readme, "FEATURES", "2026-10-03_x.md", row)
  eq(crlf_out, H.crlf(added), "CRLF README stays CRLF")

  -- a section that already has a table (as in the real READMEs)
  local real = table.concat({
    "# lib.nvim — Backlog",
    "",
    "## FEATURES (2)",
    "",
    "| Datei | Inhalt |",
    "|---|---|",
    "| [`a.md`](./FEATURES/a.md) | A |",
    "| [`b.md`](./FEATURES/b.md) | B |",
    "",
    "## TASKS (0)",
    "",
    "_noch leer_",
    "",
  }, "\n")
  local real_out = mutate.readme_add_row(real, "FEATURES", "2026-10-03_x.md", row)
  has(real_out, "## FEATURES (3)")
  has(real_out, "|---|---|\n" .. row .. "\n| [`a.md`]")
  has(real_out, "## TASKS (0)\n\n_noch leer_\n")

  -- ── done ────────────────────────────────────────────────────────────────
  root, o = setup()
  local function backlog_readme()
    return H.read(root .. "/lib.nvim/Backlog/README.md")
  end

  -- feature -> Backlog/FEATURES
  local feat_path = F.task(H, root, "lib.nvim", "ship-it", {
    { "title", "Ship it" },
    { "status", "doing" },
    { "kind", "feature" },
    { "prio", "1" },
    { "updated", "2026-09-01" },
  }, "\nA feature to ship.\n")
  F.task(H, root, "lib.nvim", "stay-open", F.meta("Stay open", "open"))
  assert(require("tasks_nvim.index").write_area("lib.nvim", o))
  local feat_before = H.read(feat_path)

  local d1 = assert(mutate.done("lib.nvim/ship-it", with(o, { done_in = "lib.nvim@abc1234" })))
  local to = root .. "/lib.nvim/Backlog/FEATURES/2026-10-03_ship-it.md"
  eq(d1.to, to)
  eq(d1.from, feat_path)
  eq(d1.bucket, "FEATURES")
  eq(d1.readme, "updated")
  ok(not H.exists(feat_path), "the open file is gone")
  eq(
    H.read(to),
    table.concat({
      "---",
      "title: Ship it",
      "status: done",
      "kind: feature",
      "prio: 1",
      "updated: 2026-10-03",
      "done_in: lib.nvim@abc1234",
      "---",
      "",
      "A feature to ship.",
      "",
    }, "\n"),
    "status done, updated, done_in; the rest as it was"
  )
  has(feat_before, "status: doing")
  local done_task = scan.find_done("lib.nvim/ship-it", { root = root })
  eq(done_task.status, "done")
  eq(done_task.done_in, "lib.nvim@abc1234")
  has(
    backlog_readme(),
    "## FEATURES (1)\n\n| Datei | Inhalt |\n|---|---|\n| [`2026-10-03_ship-it.md`](./FEATURES/2026-10-03_ship-it.md) | Ship it — A feature to ship. (2026-10-03) |\n"
  )
  has(backlog_readme(), "## TASKS (0)\n\n_noch leer_\n", "the other section is untouched")
  local idx_after = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(not idx_after:find("Ship it", 1, true), "the index no longer lists it")
  has(idx_after, "Stay open")
  eq(d1.index.action, "written")
  eq(
    require("tasks_nvim.index").write_area("lib.nvim", with(o, { check = true })).action,
    "unchanged",
    "index is fresh"
  )

  -- done twice: nothing changes
  local readme_snapshot, to_snapshot, idx_snapshot = backlog_readme(), H.read(to), idx_after
  local d2 = assert(mutate.done("lib.nvim/ship-it", with(o, { done_in = "other" })))
  eq(d2.already, true)
  eq(d2.to, to)
  eq(backlog_readme(), readme_snapshot)
  eq(H.read(to), to_snapshot)
  eq(H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"), idx_snapshot)

  -- bug -> Backlog/TASKS; the last open task goes, so the index goes
  F.task(H, root, "cascade.nvim", "crash", F.meta("Crash on exit", "open", { { "kind", "bug" } }))
  assert(require("tasks_nvim.index").write_area("cascade.nvim", o))
  ok(H.exists(root .. "/cascade.nvim/ROADMAP/TASKS.md"))
  local d3 = assert(mutate.done("cascade.nvim/crash", with(o, { date = "2026-10-01" })))
  eq(d3.bucket, "TASKS")
  ok(
    H.exists(root .. "/cascade.nvim/Backlog/TASKS/2026-10-01_crash.md"),
    "the date option is the filename prefix"
  )
  eq(
    scan.find_done("cascade.nvim/crash", { root = root }).updated,
    TODAY,
    "updated is today, not --date"
  )
  has(H.read(root .. "/cascade.nvim/Backlog/README.md"), "## TASKS (1)")
  has(H.read(root .. "/cascade.nvim/Backlog/README.md"), "## FEATURES (0)\n\n_noch leer_")
  ok(
    not H.exists(root .. "/cascade.nvim/ROADMAP/TASKS.md"),
    "no open task left: the index file is removed"
  )
  eq(d3.index.action, "removed")

  -- each kind goes where rule R6 says
  for kind, bucket in pairs({ idea = "FEATURES", research = "FEATURES", task = "TASKS" }) do
    local slug = "kind-" .. kind
    F.task(H, root, "nvim-config", slug, F.meta("K " .. kind, "open", { { "kind", kind } }))
    local r = assert(mutate.done("nvim-config/" .. slug, o))
    eq(r.bucket, bucket, kind)
    ok(H.exists(root .. "/nvim-config/Backlog/" .. bucket .. "/2026-10-03_" .. slug .. ".md"))
  end
  -- no kind at all counts as a task
  F.task(H, root, "ALL", "no-kind", F.meta("No kind", "open"))
  eq(assert(mutate.done("ALL/no-kind", o)).bucket, "TASKS")
  -- several commits
  F.task(H, root, "ALL", "multi", F.meta("Multi", "open"))
  assert(mutate.done("ALL/multi", with(o, { done_in = { "a@1", "b@2" } })))
  eq(scan.find_done("ALL/multi", { root = root }).done_in, "a@1, b@2")

  -- ── done: refusals ──────────────────────────────────────────────────────
  local none, none_err = mutate.done("lib.nvim/never-existed", o)
  eq(none, nil)
  has(none_err, "no such open task")
  local no_slug, no_slug_err = mutate.done("lib.nvim", o)
  eq(no_slug, nil)
  ok(no_slug_err)

  F.task(H, root, "lib.nvim", "weird-kind", F.meta("Weird", "open", { { "kind", "epic" } }))
  local wk, wk_err = mutate.done("lib.nvim/weird-kind", o)
  eq(wk, nil)
  has(wk_err, "unknown kind")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/weird-kind.md"), "refused: still open")

  F.task(H, root, "lib.nvim", "bad-date", F.meta("Bad date", "open"))
  local bd, bd_err = mutate.done("lib.nvim/bad-date", with(o, { date = "yesterday" }))
  eq(bd, nil)
  has(bd_err, "YYYY-MM-DD")

  -- the same id finished earlier under another date: refuse, never two files with one id
  F.task(H, root, "lib.nvim", "twin", F.meta("Twin", "open"))
  H.write(root .. "/lib.nvim/Backlog/TASKS/2026-01-01_twin.md", F.text(F.meta("Twin", "done")))
  local tw, tw_err = mutate.done("lib.nvim/twin", o)
  eq(tw, nil)
  has(tw_err, "already exists")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/twin.md"))

  -- target exists with different content: refuse and change nothing
  F.task(H, root, "lib.nvim", "clash", F.meta("Clash", "open"))
  local clash_target = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_clash.md"
  H.write(clash_target, "someone else's file\n")
  local readme_clash = backlog_readme()
  local cl, cl_err = mutate.done("lib.nvim/clash", o)
  eq(cl, nil)
  has(cl_err, "different content")
  eq(H.read(clash_target), "someone else's file\n")
  eq(backlog_readme(), readme_clash)
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/clash.md"))
  vim.fn.delete(clash_target)
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/clash.md")

  -- ── done: resume after an interrupted run ───────────────────────────────
  -- A crash between "create the Backlog file" and "delete the old one" leaves both.
  local half_path = F.task(
    H,
    root,
    "lib.nvim",
    "half-done",
    F.meta("Half done", "open", { { "kind", "task" } }),
    "\nHalf.\n"
  )
  local half_text = H.read(half_path)
  local half_done_text = require("lib.nvim.markdown.frontmatter").update_text(half_text, {
    { "status", "done" },
    { "updated", TODAY },
  })
  local half_target = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_half-done.md"
  H.write(half_target, half_done_text)
  local resumed = assert(mutate.done("lib.nvim/half-done", o))
  eq(resumed.resumed, true, "an interrupted run is completed")
  ok(not H.exists(half_path))
  eq(H.read(half_target), half_done_text)
  eq(
    select(2, backlog_readme():gsub("2026%-10%-03_half%-done%.md%)", "")),
    1,
    "one README row, not two"
  )
  eq(assert(mutate.done("lib.nvim/half-done", o)).already, true)

  -- ── done: rollback ──────────────────────────────────────────────────────
  -- Make the last step (index write) fail: the index write is stubbed to fail.
  local a_path = F.task(
    H,
    root,
    "lib.nvim",
    "roll-me",
    F.meta("Roll me back", "open", { { "kind", "feature" } }),
    "\nBody.\n"
  )
  F.task(H, root, "lib.nvim", "other-open", F.meta("Other open", "open"))
  local a_before = H.read(a_path)
  local readme_before = backlog_readme()
  local index_path = root .. "/lib.nvim/ROADMAP/TASKS.md"
  local index_before = H.read(index_path)
  local restore_index = fail_index_writes()
  local failed, fail_err = mutate.done("lib.nvim/roll-me", o)
  eq(failed, nil, "the move fails")
  has(fail_err, "index", "the error names the failing step")
  eq(H.read(a_path), a_before, "the open file is back, byte for byte")
  ok(
    not H.exists(root .. "/lib.nvim/Backlog/FEATURES/2026-10-03_roll-me.md"),
    "the Backlog file was removed again"
  )
  eq(backlog_readme(), readme_before, "the README is restored")
  eq(H.read(index_path), index_before, "the index is restored")
  restore_index()
  assert(mutate.done("lib.nvim/roll-me", o))
  ok(
    H.exists(root .. "/lib.nvim/Backlog/FEATURES/2026-10-03_roll-me.md"),
    "and it works once the obstacle is gone"
  )

  -- ── done: CRLF files ────────────────────────────────────────────────────
  local crlf_open = root .. "/lib.nvim/ROADMAP/tasks/crlf-done.md"
  H.write(
    crlf_open,
    H.crlf(F.text(F.meta("Windows done", "open", { { "kind", "task" } }), "\nWin body.\n"))
  )
  H.write(root .. "/lib.nvim/Backlog/README.md", H.crlf(backlog_readme()))
  assert(mutate.done("lib.nvim/crlf-done", with(o, { index = false })))
  local crlf_moved = H.read(root .. "/lib.nvim/Backlog/TASKS/2026-10-03_crlf-done.md")
  eq(
    crlf_moved,
    H.crlf(
      "---\ntitle: Windows done\nstatus: done\nkind: task\nupdated: 2026-10-03\n---\n\nWin body.\n"
    ),
    "moved file keeps CRLF"
  )
  local readme_crlf = backlog_readme()
  has(readme_crlf, "crlf-done.md")
  ok(not readme_crlf:gsub("\r\n", ""):find("\n", 1, true), "README stays pure CRLF")

  -- a README that does not exist: the move still works, and says so
  vim.fn.delete(root .. "/ALL/Backlog/README.md")
  F.task(H, root, "ALL", "no-readme", F.meta("No readme", "open"))
  local nr_done = assert(mutate.done("ALL/no-readme", o))
  eq(nr_done.readme, "missing")
  ok(H.exists(root .. "/ALL/Backlog/TASKS/2026-10-03_no-readme.md"))

  -- no checkpoint directory is left behind after successful runs
  ok(not H.exists(cpdir) or count_entries(cpdir) == 0, "checkpoints are discarded")

  -- the keys `set` accepts are exported for front ends (completion, docs)
  eq(mutate.SETTABLE[1], "title")
  ok(vim.tbl_contains(mutate.SETTABLE, "done_in"), "done_in is settable")
  ok(not vim.tbl_contains(mutate.SETTABLE, "updated"), "updated is the tool's, never settable")
end
