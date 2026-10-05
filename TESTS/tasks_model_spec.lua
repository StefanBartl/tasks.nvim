-- TESTS/tasks/tasks_model_spec.lua -- tasks.model: reading a file, validation, ranking, filters.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")

  --- Parse text as a roadmap task of area `lib.nvim`.
  ---@param text string
  ---@param slug? string
  local function parse(text, slug)
    return model.parse_text(text, {
      path = "/v/lib.nvim/ROADMAP/tasks/" .. (slug or "some-task") .. ".md",
      area = "lib.nvim",
    })
  end

  --- True when `task.errors` holds an entry with `code`.
  local function has_code(task, code)
    for _, c in ipairs(task.error_codes) do
      if c == code then
        return true
      end
    end
    return false
  end

  -- ── a complete, valid task ──────────────────────────────────────────────
  local full = parse(
    F.text({
      { "title", "Picker items as their own source" },
      { "status", "doing" },
      { "kind", "feature" },
      { "prio", "2" },
      { "effort", "M" },
      { "tags", "[pickers, ui]" },
      { "created", "2026-10-03" },
      { "updated", "2026-10-04" },
      { "blocked_by", "pickers.nvim/items-source" },
      { "refs", "[lib.nvim@803de65, lua/x.lua]" },
      { "done_in", "abc1234" },
      { "custom_field", "kept" },
    }, "\nFirst paragraph\ncontinues here.\n\n## Kontext\nMore.\n"),
    "picker-items"
  )
  eq(full.errors, {}, "no errors")
  ok(full.valid)
  eq(full.id, "lib.nvim/picker-items")
  eq(full.slug, "picker-items")
  eq(full.area, "lib.nvim")
  eq(full.location, "roadmap")
  eq(full.title, "Picker items as their own source")
  eq(full.status, "doing")
  eq(full.kind, "feature")
  eq(full.prio, 2)
  eq(full.effort, "M")
  eq(full.tags, { "pickers", "ui" })
  eq(full.created, "2026-10-03")
  eq(full.updated, "2026-10-04")
  eq(full.blocked_by, { "pickers.nvim/items-source" })
  eq(full.refs, { "lib.nvim@803de65", "lua/x.lua" })
  eq(full.done_in, "abc1234")
  eq(full.meta.custom_field, "kept", "unknown frontmatter keys stay visible in meta")
  eq(full.summary, "First paragraph continues here.", "first body paragraph, lines joined")

  -- ── summary rules ───────────────────────────────────────────────────────
  eq(
    parse(F.text(F.meta("T", "open", { { "summary", "From the frontmatter" } }), "\nBody para.\n")).summary,
    "From the frontmatter",
    "frontmatter summary beats the body"
  )
  eq(
    parse(F.text(F.meta("T", "open"), "\n\n## Heading first\n\nParagraph under it.\n")).summary,
    "Paragraph under it.",
    "headings are skipped"
  )
  eq(
    parse(F.text(F.meta("T", "open"), "\n<!-- note -->\n\n```lua\ncode()\n```\n\nReal text.\n")).summary,
    "Real text.",
    "comments and fenced code are skipped"
  )
  eq(parse(F.text(F.meta("T", "open"), "")).summary, "", "no body, no summary")
  eq(
    parse(F.text(F.meta("T", "open"), "\n## Only\n\n<!-- x -->\n")).summary,
    "",
    "comment-only body"
  )
  eq(model.first_paragraph("a   b\n  c\n\nd"), "a b c", "whitespace collapsed")

  -- ── defaults and soft fields ────────────────────────────────────────────
  local minimal = parse(F.text(F.meta("Just a title", "open")))
  ok(minimal.valid, "title + status is enough (R3)")
  eq(minimal.prio, nil)
  eq(minimal.tags, {})
  eq(minimal.blocked_by, {})
  eq(minimal.kind, nil)

  local scalar_tag = parse(F.text(F.meta("T", "open", { { "tags", "solo" } })))
  eq(scalar_tag.tags, { "solo" }, "a scalar counts as a one-element list")

  local list_blocker =
    parse(F.text(F.meta("T", "blocked", { { "blocked_by", "[a.nvim/x, b.nvim/y]" } })))
  eq(list_blocker.blocked_by, { "a.nvim/x", "b.nvim/y" })

  local quoted = parse(F.text(F.meta('"Fix #12: it | breaks"', "open")))
  eq(quoted.title, "Fix #12: it | breaks", "quoted title survives # and :")

  -- ── validation: every problem becomes an error, never a raise ───────────
  local cases = {
    { F.text({ { "status", "open" } }), "title-missing" },
    { F.text({ { "title", "T" } }), "status-missing" },
    { F.text(F.meta("T", "wip")), "unknown-status" },
    { F.text(F.meta("T", "open", { { "kind", "epic" } })), "unknown-kind" },
    { F.text(F.meta("T", "open", { { "prio", "4" } })), "bad-prio" },
    { F.text(F.meta("T", "open", { { "prio", "high" } })), "bad-prio" },
    { F.text(F.meta("T", "open", { { "effort", "huge" } })), "bad-effort" },
    { F.text(F.meta("T", "open", { { "created", "2026-13-01" } })), "bad-date" },
    { F.text(F.meta("T", "open", { { "updated", "2026-02-30" } })), "bad-date" },
    { F.text(F.meta("T", "open", { { "updated", "yesterday" } })), "bad-date" },
    { F.text(F.meta("T", "open", { { "blocked_by", "no-slash" } })), "bad-blocked-by" },
    { F.text(F.meta("T", "open", { { "blocked_by", "a/b/c" } })), "bad-blocked-by" },
    { "no frontmatter at all\n", "frontmatter-missing" },
    { "---\ntitle: T\nstatus: open\nnever closed\n", "frontmatter-missing" },
    { "", "frontmatter-missing" },
    { F.text(F.meta("T", "open", { { "nested", "{a: 1}" } })), "frontmatter-invalid" },
    { F.text(F.meta("", "open")), "title-missing" },
  }
  for i, case in ipairs(cases) do
    local t = parse(case[1])
    ok(not t.valid, ("case %d (%s) is invalid"):format(i, case[2]))
    ok(
      has_code(t, case[2]),
      ("case %d wants code %s, got %s"):format(i, case[2], vim.inspect(t.error_codes))
    )
    eq(#t.errors, #t.error_codes, "one code per error")
    ok(t.slug and t.id, "an invalid task still has an id")
  end

  local bad_prio = parse(F.text(F.meta("Title kept", "open", { { "prio", "9" } })))
  eq(bad_prio.title, "Title kept", "fields that are fine are still read")
  eq(bad_prio.prio, nil, "an invalid prio is nil, not guessed")

  local bad_slug = parse(F.text(F.meta("T", "open")), "Bad_Slug")
  ok(has_code(bad_slug, "slug"), "uppercase/underscore filename is a slug error")
  local nested = model.parse_text(F.text(F.meta("T", "open")), {
    path = "/v/lib.nvim/ROADMAP/tasks/sub/x.md",
    area = "lib.nvim",
    nested = true,
  })
  ok(has_code(nested, "slug"), "a nested file is flagged")

  for _, junk in ipairs({ "\0\1\2", "---\n\0\n---\n", ("x"):rep(10000), "---\r\n---\r\n" }) do
    local t = parse(junk)
    ok(type(t.errors) == "table", "junk text never raises")
  end

  -- ── from_file ───────────────────────────────────────────────────────────
  local dir = H.tmpdir()
  local file = dir .. "/lib.nvim/ROADMAP/tasks/read-me.md"
  H.write(file, F.text(F.meta("Read me", "open", { { "prio", "1" } })))
  local read = model.from_file(file, { area = "lib.nvim" })
  eq(read.id, "lib.nvim/read-me")
  eq(read.prio, 1)
  ok(read.valid)

  local missing = model.from_file(dir .. "/nope/gone.md", { area = "lib.nvim" })
  ok(not missing.valid, "a missing file is an invalid task")
  eq(missing.error_codes, { "unreadable" })
  eq(missing.id, "lib.nvim/gone")

  -- CRLF files read like LF files
  local crlf_file = dir .. "/lib.nvim/ROADMAP/tasks/crlf-task.md"
  H.write(
    crlf_file,
    H.crlf(
      F.text(
        F.meta("Windows task", "doing", { { "prio", "3" }, { "tags", "[a, b]" } }),
        "\nSummary on CRLF.\n\nSecond.\n"
      )
    )
  )
  local crlf = model.from_file(crlf_file, { area = "lib.nvim" })
  ok(crlf.valid, "CRLF task is valid: " .. vim.inspect(crlf.errors))
  eq(crlf.title, "Windows task")
  eq(crlf.status, "doing")
  eq(crlf.prio, 3)
  eq(crlf.tags, { "a", "b" })
  eq(crlf.summary, "Summary on CRLF.", "no stray CR in the summary")

  -- backlog slug: the date prefix is not part of the id
  eq(model.slug_of("/v/x/Backlog/TASKS/2026-10-03_cycle-count.md", "backlog"), "cycle-count")
  eq(
    model.slug_of("/v/x/ROADMAP/tasks/2026-10-03_cycle-count.md", "roadmap"),
    "2026-10-03_cycle-count"
  )
  local done = model.parse_text(F.text(F.meta("D", "done")), {
    path = "/v/lib.nvim/Backlog/TASKS/2026-10-03_cycle-count.md",
    area = "lib.nvim",
    location = "backlog",
  })
  eq(done.id, "lib.nvim/cycle-count")
  ok(done.valid)

  -- ── enums and dates ─────────────────────────────────────────────────────
  eq(model.STATUSES, { "doing", "decision", "blocked", "open", "parked", "done" })
  eq(model.OPEN_STATUSES, { "doing", "decision", "blocked", "open", "parked" })
  ok(
    model.is_effort("XS")
      and model.is_effort("XL")
      and model.is_effort("3d")
      and model.is_effort("0.5d")
  )
  ok(
    not model.is_effort("xl")
      and not model.is_effort("d")
      and not model.is_effort("1.d")
      and not model.is_effort("")
  )
  ok(model.is_date("2024-02-29"), "leap day")
  ok(not model.is_date("2023-02-29"), "no leap day in 2023")
  ok(not model.is_date("2026-4-1") and not model.is_date("26-04-01") and not model.is_date(nil))
  eq(model.days_between("2026-10-01", "2026-10-03"), 2)
  eq(model.days_between("2025-12-31", "2026-01-01"), 1)
  eq(model.days_between("2026-10-03", "2026-10-01"), -2)
  eq(model.days_between("2024-02-28", "2024-03-01"), 2, "across a leap day")
  eq(model.days_between("nope", "2026-10-01"), nil)
  eq(model.to_prio("2"), 2)
  eq(model.to_prio(3), 3)
  eq(model.to_prio("0"), nil)
  eq(model.to_prio("12"), nil)

  -- ── ranking ─────────────────────────────────────────────────────────────
  --- Build a bare task for sorting.
  local function t(area, slug, status, prio)
    return {
      id = area .. "/" .. slug,
      area = area,
      slug = slug,
      path = "/" .. area .. "/" .. slug,
      status = status,
      prio = prio,
      tags = {},
      blocked_by = {},
    }
  end
  local list = {
    t("lib.nvim", "z-open-p1", "open", 1),
    t("lib.nvim", "a-parked", "parked", 1),
    t("lib.nvim", "b-open-p2", "open", 2),
    t("lib.nvim", "a-open-p2", "open", 2),
    t("lib.nvim", "c-open-noprio", "open", nil),
    t("cascade.nvim", "a-open-p2", "open", 2),
    t("lib.nvim", "d-blocked", "blocked", 3),
    t("lib.nvim", "e-decision", "decision", 3),
    t("lib.nvim", "f-doing", "doing", 3),
    t("lib.nvim", "g-unknown", "wip", 1),
  }
  local want = {
    "lib.nvim/f-doing", -- doing before everything
    "lib.nvim/e-decision",
    "lib.nvim/d-blocked",
    "lib.nvim/z-open-p1", -- open: prio 1 first
    "cascade.nvim/a-open-p2", -- prio 2: area, then slug
    "lib.nvim/a-open-p2",
    "lib.nvim/b-open-p2",
    "lib.nvim/c-open-noprio", -- no prio after prio 3
    "lib.nvim/a-parked",
    "lib.nvim/g-unknown", -- unknown status last
  }
  local function ids(tasks)
    local out = {}
    for _, x in ipairs(tasks) do
      out[#out + 1] = x.id
    end
    return out
  end
  eq(ids(model.sort(vim.deepcopy(list))), want, "status rank, prio, area, slug")

  -- the order does not depend on the input order
  for seed = 1, 20 do
    local shuffled = vim.deepcopy(list)
    for i = #shuffled, 2, -1 do
      local j = ((seed * 31 + i * 17) % i) + 1
      shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    eq(
      ids(model.sort(shuffled)),
      want,
      "deterministic whatever the input order (seed " .. seed .. ")"
    )
  end

  -- ── filters ─────────────────────────────────────────────────────────────
  local pool = {
    vim.tbl_extend(
      "force",
      t("lib.nvim", "one", "open", 1),
      { kind = "bug", tags = { "ui" }, updated = "2026-10-01" }
    ),
    vim.tbl_extend(
      "force",
      t("lib.nvim", "two", "doing", 2),
      { kind = "feature", tags = { "ui", "release" }, updated = "2026-09-01" }
    ),
    vim.tbl_extend(
      "force",
      t("cascade.nvim", "three", "blocked", 3),
      { kind = "task", blocked_by = { "lib.nvim/one" }, created = "2026-01-01" }
    ),
    vim.tbl_extend("force", t("cascade.nvim", "four", "decision", nil), { kind = "idea" }),
    vim.tbl_extend(
      "force",
      t("lib.nvim", "five", "open", 3),
      { blocked_by = { "x/y" }, updated = "2026-10-03" }
    ),
  }
  eq(ids(model.filter(pool, nil)), ids(pool), "no filter keeps everything, in order")
  eq(ids(model.filter(pool, { status = "open" })), { "lib.nvim/one", "lib.nvim/five" })
  eq(
    ids(model.filter(pool, { status = { "open", "doing" } })),
    { "lib.nvim/one", "lib.nvim/two", "lib.nvim/five" }
  )
  eq(ids(model.filter(pool, { prio = 1 })), { "lib.nvim/one" })
  eq(
    ids(model.filter(pool, { prio = { 1, 3 } })),
    { "lib.nvim/one", "cascade.nvim/three", "lib.nvim/five" }
  )
  eq(
    ids(model.filter(pool, { prio_max = 2 })),
    { "lib.nvim/one", "lib.nvim/two" },
    "no prio never matches prio_max"
  )
  eq(ids(model.filter(pool, { kind = "bug" })), { "lib.nvim/one" })
  eq(ids(model.filter(pool, { kind = { "bug", "idea" } })), { "lib.nvim/one", "cascade.nvim/four" })
  eq(ids(model.filter(pool, { tag = "ui" })), { "lib.nvim/one", "lib.nvim/two" })
  eq(ids(model.filter(pool, { tag = { "release", "zzz" } })), { "lib.nvim/two" }, "tags match any")
  eq(
    ids(model.filter(pool, { area = "cascade.nvim" })),
    { "cascade.nvim/three", "cascade.nvim/four" }
  )
  eq(
    ids(model.filter(pool, { blocked = true })),
    { "cascade.nvim/three", "lib.nvim/five" },
    "blocked status or blocked_by"
  )
  eq(
    ids(model.filter(pool, { status = "open", prio_max = 1, tag = "ui" })),
    { "lib.nvim/one" },
    "criteria combine with AND"
  )

  -- stale: days since updated (else created); undated counts as stale
  local stale = model.filter(pool, { stale = 30, today = "2026-10-03" })
  eq(
    ids(stale),
    { "lib.nvim/two", "cascade.nvim/three", "cascade.nvim/four" },
    "updated 2026-09-01, created 2026-01-01, undated"
  )
  eq(
    ids(model.filter(pool, { stale = 2, today = "2026-10-03" })),
    { "lib.nvim/one", "lib.nvim/two", "cascade.nvim/three", "cascade.nvim/four" },
    "age is >= days: 2 days old counts at stale=2"
  )
  eq(ids(model.filter(pool, { stale = 0, today = "2026-10-03" })), ids(pool), "stale=0 keeps all")

  -- ── filter_from_options: the words the CLI and the editor commands share ──
  eq(
    require("tasks_nvim.filter_opts").split_commas(" a, b ,,c "),
    { "a", "b", "c" },
    "split_commas trims and drops empties"
  )
  eq(require("tasks_nvim.filter_opts").split_commas(""), {}, "split_commas of nothing")

  local f = assert(require("tasks_nvim.filter_opts").parse({}))
  eq(f.status, nil, "no option, no criterion")
  eq(f.blocked, nil)

  f = assert(require("tasks_nvim.filter_opts").parse({
    status = "doing, decision",
    prio = "1,2",
    kind = "bug",
    tag = "ui,release",
    stale = "30",
    blocked = true,
    today = "2026-10-03",
  }))
  eq(f.status, { "doing", "decision" })
  eq(f.prio, { 1, 2 })
  eq(f.kind, { "bug" })
  eq(f.tag, { "ui", "release" })
  eq(f.stale, 30, "a digit string becomes a number")
  eq(f.blocked, true)
  eq(f.today, "2026-10-03")

  f = assert(require("tasks_nvim.filter_opts").parse({ prio = "<=2", stale = 7 }))
  eq(f.prio_max, 2, "<=N is a ceiling")
  eq(f.prio, nil)
  eq(f.stale, 7, "a number is accepted as is")
  f = assert(require("tasks_nvim.filter_opts").parse({ prio = 3 }))
  eq(f.prio, { 3 }, "a number prio is accepted")

  ---@param opt table
  ---@param needle string
  local function rejected(opt, needle)
    local res, err = require("tasks_nvim.filter_opts").parse(opt)
    eq(res, nil, "rejected: " .. needle)
    has(err, needle)
  end
  rejected({ status = "doing,nope" }, "unknown status in --status: nope")
  rejected({ kind = "epic" }, "unknown kind in --kind: epic")
  rejected({ prio = "4" }, "--prio must be 1, 2, 3")
  rejected({ prio = "<=x" }, "--prio must be 1, 2, 3")
  rejected({ stale = "abc" }, "--stale must be a whole number, got 'abc'")
  rejected({ stale = "-3" }, "--stale must be a whole number")

  -- ── a hand-written title with " #" is cut at the YAML comment ───────────
  do
    local cut = parse("---\ntitle: Fix bug #12 and a [b] | c\nstatus: open\n---\nBody.\n")
    eq(cut.title, "Fix bug", "the title ends at the YAML comment")
    eq(#cut.hints, 1, "one hint")
    eq(cut.hints[1].code, "title-comment")
    has(cut.hints[1].msg, "#12 and a [b] | c", "the hint quotes the swallowed text")
    eq(cut.valid, true, "the file is still a valid task")

    local crlf_cut = parse(H.crlf("---\ntitle: CRLF: task # with colon\nstatus: open\n---\n"))
    eq(crlf_cut.title, "CRLF: task", "CRLF file: same cut")
    eq(#crlf_cut.hints, 1, "CRLF file: hint too")

    local quoted_title = parse('---\ntitle: "Fix bug #12 now"\nstatus: open\n---\n')
    eq(quoted_title.title, "Fix bug #12 now", "a quoted_title title keeps the #")
    eq(quoted_title.hints, {}, "no hint for a quoted_title title")
    eq(parse("---\ntitle: Fix bug#12\nstatus: open\n---\n").hints, {}, "# without a space is text")
    local noted = parse('---\ntitle: "Real title" # a note\nstatus: open\n---\n')
    eq(noted.title, "Real title", "a quoted title with a trailing comment keeps its text")
    eq(noted.hints, {}, "a real comment after a quoted title is not a hint")
    eq(parse("---\ntitle: 'It''s' # n\nstatus: open\n---\n").hints, {}, "single-quoted too")
  end

  -- ── a long whitespace run is read in linear time (SEC-32) ───────────────
  -- `s:match("^%s*(.-)%s*$")` retries the rest of a run from every byte inside
  -- it: 100 000 spaces in a body line took ~25 s. The bound fails loudly if a
  -- quadratic trim ever comes back; the fixed code needs a few milliseconds.
  do
    local run = (" "):rep(100000)
    local text = "---\ntitle: a" .. run .. "b\nstatus: open\ntags: [x" .. run .. "y,  z  ]\n---\n\n"
    text = text .. run .. "word" .. run .. "\n"
    local t0 = vim.uv.hrtime()
    local long = parse(text)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < 3000, ("parsing took %.0f ms"):format(ms))
    eq(long.title, "a" .. run .. "b", "inner run kept, nothing around it")
    eq(long.summary, "word", "the body line is trimmed")
    eq(long.tags[2], "z", "a list item is trimmed")
    eq(
      require("tasks_nvim.filter_opts").split_commas("a ,  b  , " .. run .. "c" .. run),
      { "a", "b", "c" },
      "comma list"
    )
    eq(require("tasks_nvim.fsio").trim("  \t x y \r\n"), "x y", "fsio.trim")
    eq(require("tasks_nvim.fsio").trim("x"), "x", "one character")
    eq(require("tasks_nvim.fsio").trim(run), "", "an all-whitespace string")
    eq(require("tasks_nvim.fsio").trim(""), "", "the empty string")
  end

  -- ── control characters from a file never reach a terminal ───────────────
  -- A raw ESC in a title (`list`, the index, the dashboard) or in a status (the
  -- `check` message) is an escape sequence: window title, OSC 52 clipboard write.
  do
    local fsio = require("tasks_nvim.fsio")
    local esc, bel, csi = "\27", "\7", "\194\155" -- ESC, BEL, the UTF-8 form of C1 CSI
    local function clean_of(label, s)
      ok(
        type(s) == "string" and not s:find("%c") and not s:find(csi, 1, true),
        label .. " is clean"
      )
    end
    local text = table.concat({
      "---",
      "title: Evil" .. esc .. "[2J" .. esc .. "]52;c;AAAA" .. bel .. " end" .. csi .. "31m",
      "status: op" .. esc .. "[0men",
      "tags: [a" .. esc .. "b, plain]",
      "refs: [lua/x" .. esc .. ".lua]",
      "summary: sum" .. csi .. "mary",
      "---",
      "",
    }, "\n")
    local evil = parse(text)
    clean_of("title", evil.title)
    eq(evil.title, "Evil [2J ]52;c;AAAA  end 31m", "each control character became one space")
    clean_of("summary", evil.summary)
    clean_of("status", evil.status)
    clean_of("tag", evil.tags[1])
    eq(evil.tags[2], "plain", "other items are untouched")
    clean_of("ref", evil.refs[1])
    for i, msg in ipairs(evil.errors) do
      clean_of("error " .. i, msg)
    end
    ok(#evil.errors > 0, "the bad status is still reported")
    clean_of(
      "body summary",
      parse("---\ntitle: t\nstatus: open\n---\n\nbody " .. esc .. "[31m red\n").summary
    )
    eq(
      fsio.clean("plain text, tab\tstays? no: " .. csi),
      "plain text, tab stays? no:  ",
      "fsio.clean"
    )
    eq(fsio.clean("ünïcode ✓ stays"), "ünïcode ✓ stays", "other UTF-8 is not touched")
    eq(
      parse("---\ntitle: \27\27\nstatus: open\n---\n").errors[1],
      "title is empty",
      "only controls"
    )
  end
end
