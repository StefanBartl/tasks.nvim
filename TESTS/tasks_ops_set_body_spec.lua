-- TESTS/tasks_ops_set_body_spec.lua -- `set_body`: the text below the frontmatter of an open task is replaced through the
-- write door: what it writes, what it leaves alone, the compare-and-set, the dry run, the inverse, and what it refuses.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local ops_mod = require("tasks_nvim.ops")

  local root = F.vault(H)
  local BODY =
    "\nA summary line.\n\n## Plan\n\n- [ ] 1. a step\n\n## Notizen\n\n- 2026-10-01: an older note\n"

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

  ---@param op table
  ---@param extra? table
  ---@return table entry
  local function one(op, extra)
    local text = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = { op } }, extra or {})),
      { root = root, today = F.TODAY }
    )
    local doc = vim.json.decode(text)
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc.results[1]
  end

  local function etag(path)
    return fsio.etag(H.read(path))
  end

  ---@param text string
  ---@return string
  local function without_updated(text)
    return (text:gsub("\nupdated: [^\n]*", ""))
  end

  -- the text is replaced, the frontmatter keeps every key, `updated` is set
  local a = task("edited")
  local before = H.read(a)
  local entry = one({
    op = "set_body",
    id = "lib.nvim/edited",
    body = "New text.\n\n## Plan\n\n- [ ] 1. other\n",
  })
  eq({ entry.ok, entry.outcome }, { true, "changed" }, vim.inspect(entry))
  eq(entry.changed_ids, { "lib.nvim/edited" })
  local after = H.read(a)
  has(after, "\nNew text.\n\n## Plan\n\n- [ ] 1. other\n")
  lacks(after, "A summary line.")
  eq(
    before:match("^(.-\n%-%-%-\n)"):gsub("\nupdated: [^\n]*", ""),
    after:match("^(.-\n%-%-%-\n)"):gsub("\nupdated: [^\n]*", ""),
    "the frontmatter is as it was but for updated"
  )
  has(after, "updated: " .. F.TODAY)
  eq(entry.etag_after, etag(a))

  -- the inverse puts the old text back (the white space at the ends is normalised)
  eq(entry.inverse.op, "set_body")
  eq(entry.inverse.if_match, etag(a))
  local undone = one(entry.inverse)
  eq(undone.outcome, "changed", vim.inspect(undone))
  eq(without_updated(H.read(a)), without_updated(before))

  -- the same text again is unchanged and writes nothing
  local b = task("same")
  one({ op = "set_body", id = "lib.nvim/same", body = "Same.\n" })
  local written = H.read(b)
  local again = one({ op = "set_body", id = "lib.nvim/same", body = "Same.\n" })
  eq(again.outcome, "unchanged")
  eq(H.read(b), written)

  -- compare-and-set: a stale version is a conflict, the file stays
  local c = task("versioned")
  local stale = etag(c)
  one({ op = "set_body", id = "lib.nvim/versioned", body = "First.", if_match = stale })
  local mid = H.read(c)
  local conflict =
    one({ op = "set_body", id = "lib.nvim/versioned", body = "Second.", if_match = stale })
  eq({ conflict.ok, conflict.error.code }, { false, "conflict" }, vim.inspect(conflict))
  eq(H.read(c), mid)

  -- a dry run says what it would do and writes nothing
  local d = task("dry")
  local dry_before = H.read(d)
  local dry = one({ op = "set_body", id = "lib.nvim/dry", body = "Other." }, { dry_run = true })
  eq({ dry.ok, dry.outcome }, { true, "would_change" })
  eq(dry.inverse, nil)
  eq(H.read(d), dry_before)

  -- an empty text is allowed and leaves one blank line; the line ending of the file is kept
  local e = task("emptied")
  one({ op = "set_body", id = "lib.nvim/emptied", body = "  \n " })
  has(H.read(e), "\n---\n\n")
  lacks(H.read(e), "summary")
  local crlf = F.task(H, root, "lib.nvim", "windows", F.meta("T windows", "open", {}), BODY)
  local raw = H.read(crlf):gsub("\n", "\r\n")
  H.write(crlf, raw)
  one({ op = "set_body", id = "lib.nvim/windows", body = "Line one\nLine two" })
  local out = H.read(crlf)
  has(out, "Line one\r\nLine two\r\n")
  lacks(out:gsub("\r\n", ""), "\n")

  -- refused: a control character, too long, no body, an unknown task, a finished task
  local function refused(op, code, needle)
    local r = one(op)
    eq({ r.ok, r.error.code }, { false, code }, vim.inspect(r))
    if needle then
      has(r.error.message, needle)
    end
  end
  refused(
    { op = "set_body", id = "lib.nvim/edited", body = "bell\7" },
    "invalid_argument",
    "control character"
  )
  refused(
    { op = "set_body", id = "lib.nvim/edited", body = "line\r" },
    "invalid_argument",
    "control character"
  )
  refused(
    { op = "set_body", id = "lib.nvim/edited", body = string.rep("x", ops_mod.MAX_SET_BODY + 1) },
    "payload_too_large",
    "longer than"
  )
  refused({ op = "set_body", id = "lib.nvim/edited" }, "invalid_argument")
  refused({ op = "set_body", id = "lib.nvim/nothing-here", body = "x" }, "not_found")
  -- the text may hold a tab and a line break
  local tab = one({ op = "set_body", id = "lib.nvim/edited", body = "a\tb\nc" })
  eq(tab.ok, true, vim.inspect(tab))

  -- an old text that could not be sent again leaves no inverse
  local big = task("big", "\n" .. string.rep("y", ops_mod.MAX_SET_BODY + 5) .. "\n")
  local shrunk = one({ op = "set_body", id = "lib.nvim/big", body = "small" })
  eq(shrunk.outcome, "changed")
  eq(shrunk.inverse, nil, "a text beyond the limit has no inverse")
  ok(big)
end
