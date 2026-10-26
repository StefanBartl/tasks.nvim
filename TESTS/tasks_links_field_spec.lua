-- TESTS/tasks_links_field_spec.lua -- the `links` field: web addresses (http/https) of a task, apart from `refs`.
-- Model check, `new`, `set`, the write door, the contract entry and the CLI text.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local ops = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY }

  -- ── what is a web link ─────────────────────────────────────────────────────
  ok(model.is_web_link("https://example.org/a#b"), "https")
  ok(model.is_web_link("HTTP://example.org"), "http, any case")
  ok(not model.is_web_link("ftp://example.org"), "no ftp")
  ok(not model.is_web_link("javascript:alert(1)"), "no javascript:")
  ok(not model.is_web_link("file:///c:/x"), "no file:")
  ok(not model.is_web_link("lua/x.lua"), "no path")
  ok(not model.is_web_link("https://"), "a host is needed")
  ok(not model.is_web_link("https://a b"), "no blank")
  ok(not model.is_web_link("https://a\tb"), "no control character")
  ok(not model.is_web_link(5), "no number")

  -- ── new: a list or a comma string, once each, written after refs ───────────
  local made = assert(mutate.new(
    "lib.nvim",
    vim.tbl_extend("force", o, {
      title = "Has links",
      refs = "lua/x.lua",
      web_links = "https://example.org/docs#intro, http://example.com, https://example.org/docs#intro",
    })
  ))
  local text = assert(H.read(made.path))
  has(text, "refs: [lua/x.lua]\nlinks: [https://example.org/docs#intro, http://example.com]")
  local task = assert(scan.find(made.id, { root = root }))
  eq(task.links, { "https://example.org/docs#intro", "http://example.com" })
  eq(task.refs, { "lua/x.lua" }, "refs stay apart")

  local bad, berr = mutate.new(
    "lib.nvim",
    vim.tbl_extend("force", o, { title = "Bad link", web_links = "ftp://example.org" })
  )
  eq(bad, nil)
  has(berr, "not an http:// or https:// address")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/bad-link.md"), "nothing written")

  -- a task without links has no `links` line
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "No links" })))
  ok(not (H.read(plain.path) or ""):find("links:", 1, true))

  -- ── set: replaces the list, an empty value removes it, a bad entry is refused ─
  assert(mutate.set(made.id, { links = { "https://z.org" } }, o))
  has(assert(H.read(made.path)), "links: [https://z.org]")
  local _, serr = mutate.set(made.id, { links = { "mailto:a@b.c" } }, o)
  has(serr, "not an http:// or https:// address")
  has(assert(H.read(made.path)), "links: [https://z.org]", "a refused patch changes nothing")
  assert(mutate.set(made.id, { links = "" }, o))
  ok(not assert(H.read(made.path)):find("links:", 1, true), "an empty value removes the key")

  -- ── check: a hand-written bad entry is a finding, the file still reads ─────
  F.task(
    H,
    root,
    "lib.nvim",
    "hand-written",
    F.meta("Hand", "open", { { "links", "[https://ok.org, ftp://no]" } })
  )
  local res = assert(check.run({ root = root }))
  local found = false
  for _, f in ipairs(res.findings or {}) do
    if f.code == "bad-link" and f.path:find("hand-written", 1, true) then
      found = true
    end
  end
  ok(found, "bad-link is reported")

  -- ── the write door: `new` takes fields.links; a bad one is refused ─────────
  local doc = assert(ops.run({
    ops = {
      { op = "new", area = "lib.nvim", title = "Door", fields = { links = { "https://d.org" } } },
    },
  }, { root = root, today = F.TODAY }))
  ok(doc.results[1].ok, vim.inspect(doc.results[1]))
  local refused = assert(ops.run({
    ops = {
      { op = "new", area = "lib.nvim", title = "Door bad", fields = { links = { "ftp://d.org" } } },
    },
  }, { root = root, today = F.TODAY }))
  ok(not refused.results[1].ok, "a non-http link is refused")

  -- ── the contract entry carries `links` only when there are some ────────────
  local api = require("tasks_nvim.api")
  local function entry_of(id)
    local reply = api.call("task", vim.json.encode({ params = { id = id } }), { root = root })
    return vim.json.decode(reply).task
  end
  eq(entry_of(doc.results[1].id).links, { "https://d.org" })
  eq(entry_of(plain.id).links, nil)
  -- a hand-written `javascript:` entry is a problem of the task and never reaches a client as a link
  F.task(
    H,
    root,
    "lib.nvim",
    "js-link",
    F.meta("Js", "open", { { "links", "[javascript:alert(1), https://ok.org]" } })
  )
  local js = entry_of("lib.nvim/js-link")
  eq(js.links, { "https://ok.org" })
  eq(js.valid, false, "the task is marked as having a problem")
end
