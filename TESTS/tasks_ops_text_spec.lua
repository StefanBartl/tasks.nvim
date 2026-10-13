-- TESTS/tasks_ops_text_spec.lua -- the two operations that change the text of a task through the write door: `tick_step`
-- (one step of the `## Plan` section) and `append_note` (a dated line below the notes): what they write, what they leave
-- alone, the compare-and-set, the dry run, the inverse of a tick, and what they refuse.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local scan = require("tasks_nvim.scan")
  local steps = require("tasks_nvim.steps")

  local root = F.vault(H)

  local BODY = table.concat({
    "",
    "A summary line.",
    "",
    "## Plan",
    "",
    "- [ ] 1. first step -- Acceptance 1",
    "- [x] 2. second step",
    "- [ ] 3. third step (dropped)",
    "```",
    "- [ ] 4. inside a fence, not a step",
    "```",
    "",
    "## Notizen",
    "",
    "- 2026-10-01: an older note",
    "",
    "## Weiteres",
    "",
    "text that stays",
    "",
  }, "\n")

  ---@param slug string
  ---@param body? string
  ---@return string path
  local function task(slug, body)
    return F.task(
      H,
      root,
      "lib.nvim",
      slug,
      F.meta("T " .. slug, "open", { { "prio", "2" } }),
      body or BODY
    )
  end

  ---@param list table[]
  ---@param extra? table
  ---@return table doc
  local function ops(list, extra)
    local text = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = list }, extra or {})),
      { root = root, today = F.TODAY }
    )
    return vim.json.decode(text)
  end

  ---@param op table
  ---@param extra? table
  ---@return table entry
  local function one(op, extra)
    local doc = ops({ op }, extra)
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc.results[1]
  end

  ---@param path string
  ---@return string
  local function etag(path)
    return fsio.etag(H.read(path))
  end

  --- The file with its `updated` line taken out: what a change of the text must leave as it was.
  ---@param text string
  ---@return string
  local function without_updated(text)
    return (text:gsub("\nupdated: [^\n]*", ""))
  end

  -- ── tick_step ──────────────────────────────────────────────────────────────
  local a = task("ticker")
  local original = H.read(a)
  local entry = one({ op = "tick_step", id = "lib.nvim/ticker", n = 1 })
  eq(entry.ok, true, vim.inspect(entry))
  eq(entry.outcome, "changed")
  eq(entry.changed_ids, { "lib.nvim/ticker" })
  local after = H.read(a)
  eq(
    without_updated(after),
    (without_updated(original):gsub("%- %[ %] 1%. first", "- [x] 1. first", 1)),
    "only the box of step 1 changed"
  )
  has(after, "updated: " .. F.TODAY, "the change sets `updated`")
  eq(entry.etag_before, fsio.etag(original), "the answer names the version it worked from")
  eq(entry.etag_after, fsio.etag(after), "the answer names the version the write left")
  eq(steps.parse(after).ticked, 2)

  -- the inverse takes the tick back and is itself a tick_step with the version the change left
  eq(entry.inverse.op, "tick_step")
  eq(
    { entry.inverse.n, entry.inverse.done, entry.inverse.if_match },
    { 1, false, entry.etag_after }
  )
  local undone = one(entry.inverse)
  eq(undone.outcome, "changed", vim.inspect(undone))
  eq(without_updated(H.read(a)), without_updated(original), "undone, byte for byte but `updated`")
  eq(undone.inverse.done, true, "and the undo has its own inverse")

  -- a step that is in the wanted state already is no change: nothing is written, there is nothing to undo
  local bytes = H.read(a)
  local same = one({ op = "tick_step", id = "lib.nvim/ticker", n = 2 })
  eq({ same.ok, same.outcome, same.inverse }, { true, "unchanged", nil })
  eq(H.read(a), bytes)
  eq(one({ op = "tick_step", id = "lib.nvim/ticker", n = 1, done = false }).outcome, "unchanged")

  -- unticking
  local open = one({ op = "tick_step", id = "lib.nvim/ticker", n = 2, done = false })
  eq(open.outcome, "changed")
  eq(steps.parse(H.read(a)).items[2].done, false)
  eq(open.inverse.done, true)

  -- a dropped step, a step that is not there, a task with no steps, a step inside a fence: refused, nothing written
  bytes = H.read(a)
  local function refused(op, needle, code)
    local e = one(op)
    eq(e.ok, false, vim.inspect(e))
    eq(e.outcome, "failed")
    eq(e.error.code, code or "invalid_argument", vim.inspect(e))
    has(e.error.message, needle)
  end
  refused({ op = "tick_step", id = "lib.nvim/ticker", n = 3 }, "dropped")
  refused({ op = "tick_step", id = "lib.nvim/ticker", n = 4 }, "there is no step 4")
  eq(H.read(a), bytes, "a refused tick leaves the file as it was")
  task("nosteps", "\nNo steps here.\n")
  refused({ op = "tick_step", id = "lib.nvim/nosteps", n = 1 }, "no steps")
  refused({ op = "tick_step", id = "lib.nvim/missing", n = 1 }, "", "not_found")

  -- the shape: n is a whole number from 1, done is a boolean, and both are asked for
  for _, bad in ipairs({
    { op = "tick_step", id = "lib.nvim/ticker", n = 0 },
    { op = "tick_step", id = "lib.nvim/ticker", n = 1.5 },
    { op = "tick_step", id = "lib.nvim/ticker", n = "1" },
    { op = "tick_step", id = "lib.nvim/ticker", n = 1, done = "yes" },
    { op = "tick_step", id = "lib.nvim/ticker", n = 1, surprise = true },
  }) do
    local doc = ops({ bad })
    eq(doc.kind, "tasks.error", vim.inspect(bad))
    eq(doc.code, "invalid_argument")
  end
  refused({ op = "tick_step", id = "lib.nvim/ticker" }, "needs id and n")
  eq(H.read(a), bytes)

  -- compare-and-set: a request that was based on an older version is a conflict and writes nothing
  local stale =
    one({ op = "tick_step", id = "lib.nvim/ticker", n = 1, if_match = "sha256:0000000000000000" })
  eq(stale.error.code, "conflict", vim.inspect(stale))
  eq(H.read(a), bytes)
  local current = one({ op = "tick_step", id = "lib.nvim/ticker", n = 1, if_match = etag(a) })
  eq(current.outcome, "changed")

  -- a dry run says what it would do and writes nothing
  bytes = H.read(a)
  local dry = one(
    { op = "tick_step", id = "lib.nvim/ticker", n = 1, done = false },
    { dry_run = true }
  )
  eq({ dry.ok, dry.outcome, dry.etag_after, dry.changed_ids }, { true, "would_change", nil, {} })
  eq(H.read(a), bytes)

  -- a file with CRLF line endings keeps them
  local crlf = task("crlf", "\nSummary.\n\n## Plan\n\n- [ ] 1. one\n- [ ] 2. two\n")
  local raw = H.read(crlf):gsub("\r?\n", "\r\n")
  local fh = assert(io.open(crlf, "wb"))
  fh:write(raw)
  fh:close()
  eq(one({ op = "tick_step", id = "lib.nvim/crlf", n = 2 }).outcome, "changed")
  local crlf_after = H.read(crlf)
  has(crlf_after, "- [x] 2. two\r\n")
  eq(
    select(2, crlf_after:gsub("\r\n", "")),
    select(2, crlf_after:gsub("\n", "")),
    "no bare LF was added"
  )

  -- ── append_note ────────────────────────────────────────────────────────────
  local n1 = task("noter")
  local note = one({ op = "append_note", id = "lib.nvim/noter", text = "  a new note  " })
  eq({ note.ok, note.outcome, note.inverse }, { true, "changed", nil })
  eq(note.etag_after, etag(n1))
  local text = H.read(n1)
  has(
    text,
    "- 2026-10-01: an older note\n- " .. F.TODAY .. ": a new note\n\n## Weiteres",
    "below the last note, above the next section"
  )
  has(text, "text that stays")
  eq(steps.parse(text).items[1].done, false, "the steps are not touched")
  has(text, "updated: " .. F.TODAY)
  -- the second note goes below the first
  one({ op = "append_note", id = "lib.nvim/noter", text = "second" })
  has(H.read(n1), "a new note\n- " .. F.TODAY .. ": second\n\n## Weiteres")

  -- the same text twice is two notes (a note is a log line, not a state)
  eq(one({ op = "append_note", id = "lib.nvim/noter", text = "second" }).outcome, "changed")

  -- the notes are the last section, or a heading without any line, or missing
  local last = task("lastsec", "\nSummary.\n\n## Notizen\n\n- 2026-10-01: old\n")
  one({ op = "append_note", id = "lib.nvim/lastsec", text = "new" })
  eq(H.read(last):match("## Notizen\n(.*)$"), "\n- 2026-10-01: old\n- " .. F.TODAY .. ": new\n")
  local empty = task("emptysec", "\nSummary.\n\n## Notizen\n")
  one({ op = "append_note", id = "lib.nvim/emptysec", text = "first" })
  has(H.read(empty), "## Notizen\n\n- " .. F.TODAY .. ": first")
  local none = task("nosec", "\nSummary.\n")
  one({ op = "append_note", id = "lib.nvim/nosec", text = "made" })
  has(H.read(none), "\nSummary.\n\n## Notizen\n\n- " .. F.TODAY .. ": made\n")
  local english = task("english", "\n## Context\n\nSome.\n")
  one({ op = "append_note", id = "lib.nvim/english", text = "made" })
  has(H.read(english), "\n## Notes\n\n- " .. F.TODAY .. ": made\n")
  -- a heading inside a code fence is no heading
  local fenced = task("fenced", "\n```\n## Notizen\n```\n\nSummary.\n")
  one({ op = "append_note", id = "lib.nvim/fenced", text = "x" })
  has(H.read(fenced), "```\n\nSummary.\n\n## Notizen\n\n- " .. F.TODAY .. ": x\n")

  -- what is refused: nothing is written
  bytes = H.read(n1)
  refused({ op = "append_note", id = "lib.nvim/noter", text = "   " }, "empty")
  refused({ op = "append_note", id = "lib.nvim/noter", text = "two\nlines" }, "control character")
  refused({ op = "append_note", id = "lib.nvim/noter", text = "bell\7" }, "control character")
  refused(
    { op = "append_note", id = "lib.nvim/noter", text = string.rep("x", 1001) },
    "longer than"
  )
  -- the 8-bit controls and the Unicode line separators are refused like in every other text a front end sends
  refused(
    { op = "append_note", id = "lib.nvim/noter", text = "a\226\128\168b" },
    "control character"
  )
  refused({ op = "append_note", id = "lib.nvim/noter", text = "c\194\133d" }, "control character")
  refused({ op = "append_note", id = "lib.nvim/noter" }, "needs id and text")
  refused({ op = "append_note", id = "lib.nvim/missing", text = "x" }, "", "not_found")
  eq(H.read(n1), bytes)
  local stale_note = one({
    op = "append_note",
    id = "lib.nvim/noter",
    text = "x",
    if_match = "sha256:0000000000000000",
  })
  eq(stale_note.error.code, "conflict")
  eq(H.read(n1), bytes)
  local dry_note = one(
    { op = "append_note", id = "lib.nvim/noter", text = "dry" },
    { dry_run = true }
  )
  eq(dry_note.outcome, "would_change")
  eq(H.read(n1), bytes)

  -- a task that is a link is not written through
  if vim.fn.has("win32") == 0 then
    local target = H.tmpdir() .. "/outside.md"
    H.write(target, F.text(F.meta("Out", "open"), BODY))
    local link = root .. "/lib.nvim/ROADMAP/tasks/linked.md"
    ok(vim.uv.fs_symlink(target, link))
    local e = one({ op = "append_note", id = "lib.nvim/linked", text = "x" })
    eq(e.ok, false)
    eq(
      H.read(target),
      F.text(F.meta("Out", "open"), BODY),
      "the file outside the vault was not touched"
    )
  end

  -- two operations of one request work on the file one after the other
  local both = task("both")
  local doc = ops({
    { op = "tick_step", id = "lib.nvim/both", n = 1 },
    { op = "append_note", id = "lib.nvim/both", text = "ticked" },
  })
  eq({ doc.results[1].ok, doc.results[2].ok }, { true, true }, vim.inspect(doc))
  local final = H.read(both)
  has(final, "- [x] 1. first")
  has(final, ": ticked")
  eq(
    doc.results[2].etag_before,
    doc.results[1].etag_after,
    "the second works on the version the first left"
  )

  -- ── new with a body ────────────────────────────────────────────────────────
  local text_in = "First line of the note.\n\n- one\n- two\n\n## Own section\n\nMore."
  local made = one({ op = "new", area = "lib.nvim", title = "From a note", body = text_in })
  eq({ made.ok, made.outcome }, { true, "created" }, vim.inspect(made))
  local made_text = H.read(root .. "/" .. made.file)
  has(made_text, "title: From a note")
  has(made_text, "\n" .. text_in .. "\n", "the text is kept as it was written")
  lacks(
    made_text,
    "## Kontext",
    "the sections of the template are not added to a text that was given"
  )
  eq(
    require("tasks_nvim.model").parse_text(
      made_text,
      { path = "x.md", area = "lib.nvim", slug = "x" }
    ).summary,
    "First line of the note.",
    "the first paragraph is the summary"
  )
  -- no body: the template, as before
  local plain = one({ op = "new", area = "lib.nvim", title = "No text given" })
  has(H.read(root .. "/" .. plain.file), "## Kontext")
  -- refused: empty, a control character, too long, and a dry run writes nothing
  local function refused_new(body, needle, code)
    local e = one({ op = "new", area = "lib.nvim", title = "Refused body", body = body })
    eq({ e.ok, e.error.code }, { false, code or "invalid_argument" }, vim.inspect(e))
    has(e.error.message, needle)
  end
  refused_new("   \n  ", "must not be empty")
  refused_new("bell\7", "control character")
  refused_new(string.rep("x", 20001), "longer than", "payload_too_large")
  local dry_new = one(
    { op = "new", area = "lib.nvim", title = "Dry body", body = "text" },
    { dry_run = true }
  )
  eq({ dry_new.ok, dry_new.outcome }, { true, "would_create" })
  eq(fsio.is_file(root .. "/lib.nvim/ROADMAP/tasks/dry-body.md"), false)

  -- the overview of the area is current
  local idx = require("tasks_nvim.index").write_area("lib.nvim", { root = root, check = true })
  eq(idx.action, "unchanged", "the overview of the area matches the files")
  ok(scan.find("lib.nvim/both", { root = root }))
  lacks(H.read(both), "\r")
end
