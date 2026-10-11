-- TESTS/tasks_ops_spec.lua -- tasks-ops/1, the write door: the shape of a request, every operation, dry runs, limits,
-- what a front end may not write, the answers a client has to handle (conflict, refused relation, partial success), and
-- two writers at once.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local scan = require("tasks_nvim.scan")
  local script_dir = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "prio", "2" } }))
  F.task(
    H,
    root,
    "lib.nvim",
    "beta",
    F.meta("Beta", "open", { { "prio", "2" }, { "blocked_by", "lib.nvim/alpha" } })
  )
  F.task(H, root, "lib.nvim", "gamma", F.meta("Gamma", "open", { { "prio", "2" } }))
  F.task(H, root, "cascade.nvim", "delta", F.meta("Delta", "doing", { { "prio", "1" } }))

  ---@param list table[]
  ---@param extra? table
  ---@return table doc
  ---@return string text
  ---@return string|nil code
  local function ops(list, extra)
    local text, code = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = list }, extra or {})),
      { root = root, today = F.TODAY }
    )
    return vim.json.decode(text), text, code
  end

  ---@param list table[]
  ---@param extra? table
  ---@return table entry  # the only result
  local function one(list, extra)
    local doc = ops(list, extra)
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    eq(#doc.results, 1)
    return doc.results[1]
  end

  ---@param id string
  ---@return Tasks.Task
  local function find(id)
    return assert(scan.find(id, { root = root }))
  end

  --- Every file of the vault with its bytes: what a refused or dry request must leave exactly as it is.
  ---@return table<string, string>
  local function everything()
    local out = {}
    for _, path in ipairs(vim.fn.globpath(root, "**/*", true, true)) do
      if vim.fn.isdirectory(path) == 0 then
        out[path] = H.read(path)
      end
    end
    return out
  end

  -- ── the shape of a request: refused as a whole, nothing runs ─────────────────
  local before = everything()
  ---@param req string
  ---@param code string
  ---@param needle string
  local function bad(req, code, needle)
    local text, c = api.call("ops", req, { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    eq(doc.kind, "tasks.error", req)
    eq(doc.code, code, req)
    eq(c, code)
    has(doc.message, needle, req)
  end
  bad("{}", "invalid_argument", "list of operations is missing")
  bad('{"ops":[]}', "invalid_argument", "empty")
  bad('{"ops":[{"op":"explode"}]}', "invalid_argument", "unknown operation")
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":{},"colour":1}]}',
    "invalid_argument",
    "unknown field 'colour'"
  )
  bad('{"ops":[{"op":"set","id":7,"patch":{}}]}', "invalid_argument", "id must be text")
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":[1]}]}',
    "invalid_argument",
    "patch must be an object"
  )
  bad(
    '{"ops":[{"op":"new","area":"lib.nvim","title":"x","body":"hi"}]}',
    "invalid_argument",
    "body must be"
  )
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":{}}],"nope":1}',
    "invalid_argument",
    "unknown field 'nope'"
  )
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":{}}],"client_op_id":"a b"}',
    "invalid_argument",
    "client_op_id"
  )
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":{}}],"dry_run":"yes"}',
    "invalid_argument",
    "dry_run"
  )
  bad('{"schema":2,"ops":[{"op":"done","id":"x"}]}', "unsupported_schema", "schema 2")
  bad("{ not json", "invalid_argument", "not valid JSON")
  local many = {}
  for i = 1, 101 do
    many[i] = { op = "set", id = "lib.nvim/alpha", patch = { summary = "x" .. i } }
  end
  bad(vim.json.encode({ ops = many }), "payload_too_large", "at most 100")
  eq(
    everything(),
    before,
    "a refused request writes nothing, not even the operations before the bad one"
  )

  -- a mistake in the SECOND operation refuses the first as well
  bad(
    '{"ops":[{"op":"set","id":"lib.nvim/alpha","patch":{"summary":"written?"}},{"op":"bogus"}]}',
    "invalid_argument",
    "ops[2]"
  )
  eq(find("lib.nvim/alpha").meta.summary, nil, "so the first was not written")

  -- ── set: changed, the answer, the inverse, the index once ───────────────────
  local alpha = find("lib.nvim/alpha")
  local gamma = find("lib.nvim/gamma")
  local doc = ops({
    {
      op = "set",
      id = "lib.nvim/alpha",
      patch = { status = "doing", summary = "A summary" },
      if_match = alpha.etag,
    },
    { op = "set", id = "lib.nvim/gamma", patch = { prio = 1 }, if_match = gamma.etag },
  }, { client_op_id = "t-1" })
  eq(doc.kind, "tasks.result")
  eq(doc.client_op_id, "t-1", "echoed, for a client that must not repeat itself")
  eq(doc.dry_run, false)
  eq(doc.ok, true)
  local r1, r2 = doc.results[1], doc.results[2]
  eq({ r1.n, r1.op, r1.ok, r1.outcome, r1.id }, { 1, "set", true, "changed", "lib.nvim/alpha" })
  eq(r1.etag_before, alpha.etag)
  eq(r1.etag_after, find("lib.nvim/alpha").etag)
  eq(r1.changed_ids, { "lib.nvim/alpha" })
  eq(r1.inverse, {
    op = "set",
    id = "lib.nvim/alpha",
    patch = { status = "open", summary = vim.NIL },
    if_match = r1.etag_after,
  }, "the inverse restores the old status and removes the summary the change added")
  eq(r1.index, { action = "written" }, "one index write for the area...")
  eq(r2.index, { action = "written" }, "...reported on every operation of it")
  eq(find("lib.nvim/alpha").status, "doing")
  eq(find("lib.nvim/gamma").prio, 1)
  ok(H.exists(root .. "/lib.nvim/ROADMAP/TASKS.md"), "the generated overview is current")

  -- the inverse undoes it, and is itself undoable
  local undo = one({ r1.inverse })
  eq(undo.outcome, "changed")
  eq(find("lib.nvim/alpha").status, "open")
  eq(find("lib.nvim/alpha").meta.summary, nil)
  eq(undo.etag_after, find("lib.nvim/alpha").etag)

  -- a patch that changes nothing
  local same = one({ { op = "set", id = "lib.nvim/alpha", patch = { status = "open" } } })
  eq({ same.ok, same.outcome }, { true, "unchanged" })
  eq(same.inverse, nil)
  eq(same.changed_ids, {})
  eq(same.index, nil, "nothing changed, nothing re-indexed")

  -- ── conflicts: the answer names both versions; the other operations still run ──
  local stale = find("lib.nvim/alpha").etag
  assert(
    mutate.set("lib.nvim/alpha", { prio = 3 }, { root = root, today = F.TODAY, index = false })
  )
  local mixed = ops({
    { op = "set", id = "lib.nvim/alpha", patch = { status = "blocked" }, if_match = stale },
    { op = "set", id = "lib.nvim/gamma", patch = { summary = "second goes through" } },
  })
  eq(mixed.ok, false, "not everything worked, and the document says so")
  local c1 = mixed.results[1]
  eq(
    { c1.ok, c1.outcome, c1.error.code, c1.error.retryable },
    { false, "failed", "conflict", false }
  )
  eq(c1.error.details.expected, stale)
  eq(c1.error.details.actual, find("lib.nvim/alpha").etag)
  eq(c1.error.details.id, "lib.nvim/alpha")
  eq(mixed.results[2].ok, true, "a failed operation does not stop the next")
  eq(find("lib.nvim/gamma").meta.summary, "second goes through")
  eq(find("lib.nvim/alpha").status, "open", "the conflict wrote nothing")

  -- `expect`: one key
  local ex = one({
    {
      op = "set",
      id = "lib.nvim/alpha",
      patch = { status = "doing" },
      expect = { key = "status", value = "parked" },
    },
  })
  eq(ex.error.code, "conflict")
  eq(ex.error.details.key, "status")
  eq(ex.error.details.actual, "open")
  eq(
    one({
      {
        op = "set",
        id = "lib.nvim/alpha",
        patch = { status = "doing" },
        expect = { key = "status", value = "open" },
      },
    }).outcome,
    "changed"
  )
  eq(
    one({
      {
        op = "set",
        id = "lib.nvim/alpha",
        patch = { status = "open" },
        expect = { key = "colour", value = 1 },
      },
    }).error.code,
    "invalid_argument"
  )

  -- `null` in a patch removes a key
  assert(
    mutate.set("lib.nvim/gamma", { effort = "S" }, { root = root, today = F.TODAY, index = false })
  )
  eq(find("lib.nvim/gamma").effort, "S")
  local removal = one({ { op = "set", id = "lib.nvim/gamma", patch = { effort = vim.NIL } } })
  eq(removal.outcome, "changed")
  eq(find("lib.nvim/gamma").effort, nil)
  eq(removal.inverse.patch, { effort = "S" })

  -- ── values: invalid, unknown, too big ───────────────────────────────────────
  ---@param patch table
  ---@param code string
  ---@param needle? string
  local function refused_patch(patch, code, needle)
    local e = one({ { op = "set", id = "lib.nvim/gamma", patch = patch } })
    eq({ e.ok, e.outcome, e.error.code }, { false, "failed", code }, vim.inspect(patch))
    if needle then
      has(e.error.message, needle)
    end
  end
  refused_patch({ status = "someday" }, "invalid_argument", "unknown status")
  refused_patch({ status = "done" }, "invalid_argument", "tasks done")
  refused_patch({ prio = 9 }, "invalid_argument", "prio must be")
  refused_patch({ colour = "red" }, "invalid_argument", "unknown field")
  refused_patch({ updated = "2026-01-01" }, "invalid_argument", "set by the tool")
  refused_patch({}, "invalid_argument", "nothing to set")
  local ghost = one({ { op = "set", id = "lib.nvim/ghost", patch = { status = "open" } } })
  eq(ghost.error.code, "not_found")
  eq(
    one({ { op = "set", id = "no-slash", patch = { status = "open" } } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ { op = "set", id = "no.such.area/x", patch = { status = "open" } } }).error.code,
    "not_found"
  )

  -- limits are kept on writing
  local long = ("x"):rep(301)
  local over = one({ { op = "set", id = "lib.nvim/gamma", patch = { title = long } } })
  eq(over.error.code, "payload_too_large")
  has(over.error.message, "title")
  local tags = {}
  for i = 1, 101 do
    tags[i] = "t" .. i
  end
  eq(
    one({ { op = "set", id = "lib.nvim/gamma", patch = { tags = tags } } }).error.code,
    "payload_too_large"
  )
  eq(
    one({ { op = "set", id = "lib.nvim/gamma", patch = { summary = ("s"):rep(1001) } } }).error.code,
    "payload_too_large"
  )
  eq(
    one({ { op = "set", id = "lib.nvim/gamma", patch = { title = ("t"):rep(300) } } }).outcome,
    "changed",
    "300 is the limit, not 299"
  )

  -- ── refs: what a front end may add ──────────────────────────────────────────
  ---@param refs string[]
  ---@return table entry
  local function with_refs(refs)
    return one({ { op = "set", id = "lib.nvim/gamma", patch = { refs = refs } } })
  end
  for _, bad_ref in ipairs({
    "../other.nvim/lua/x.lua",
    "C:/Users/x/secret.txt",
    "C:\\Users\\x\\secret.txt",
    "/etc/passwd",
    "//server/share/x",
    "\\\\server\\share\\x",
    "docs/a.md:abc",
    "name:anchor",
    "https://example.org/x",
    "a/b\ttab",
  }) do
    local e = with_refs({ bad_ref })
    eq({ e.ok, e.error and e.error.code }, { false, "invalid_argument" }, "refused: " .. bad_ref)
  end
  eq(
    with_refs({
      "lua/a.lua",
      "lua/a.lua:42",
      "lua/a.lua:42:7",
      "lua/a.lua:10-20",
      "docs/a.md#top",
      "lib.nvim@abc1234",
      "lib.nvim/alpha",
    }).outcome,
    "changed"
  )
  -- an entry the task already has stays, even when it would not be accepted as new
  H.write(
    find("lib.nvim/gamma").path,
    F.text(
      F.meta(
        "Gamma",
        "open",
        { { "prio", "1" }, { "refs", "[../old/x.lua, https://old.example/x]" } }
      )
    )
  )
  local keep = with_refs({ "../old/x.lua", "https://old.example/x", "new/ref.lua" })
  eq(keep.outcome, "changed", "existing entries are grandfathered: " .. vim.inspect(keep))
  eq(
    with_refs({ "../old/x.lua", "../new.lua" }).error.code,
    "invalid_argument",
    "a new entry is checked"
  )

  -- ── relations are judged before they are written ────────────────────────────
  local function relation(patch)
    return one({ { op = "set", id = "lib.nvim/alpha", patch = patch } })
  end
  local cyc = relation({ blocked_by = { "lib.nvim/beta" } })
  eq(cyc.error.code, "invalid_argument")
  eq(cyc.error.details.problems[1].code, "blocked-by-cycle")
  eq(cyc.error.details.problems[1].members, { "lib.nvim/alpha", "lib.nvim/beta" })
  eq(
    relation({ blocked_by = { "lib.nvim/alpha" } }).error.details.problems[1].code,
    "blocked-by-self"
  )
  eq(
    relation({ blocked_by = { "lib.nvim/nowhere" } }).error.details.problems[1].code,
    "blocked-by-dangling"
  )
  eq(relation({ after = { "lib.nvim/nowhere" } }).error.details.problems[1].code, "after-dangling")
  eq(relation({ plan = "lib.nvim/no-plan" }).error.details.problems[1].code, "plan-unknown")
  eq(find("lib.nvim/alpha").blocked_by, {}, "none of them was written")
  local good = assert(
    plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Ship", phases = "build,ship" })
  )
  eq(relation({ plan = good.id, phase = "build" }).outcome, "changed")
  eq(relation({ phase = "nonsense" }).error.details.problems[1].code, "plan-phase")
  eq(
    relation({ blocked_by = { "cascade.nvim/delta" } }).outcome,
    "changed",
    "a task of another area is fine"
  )
  eq(
    relation({ blocked_by = vim.NIL, plan = vim.NIL, phase = vim.NIL }).outcome,
    "changed",
    "and relations can be removed"
  )

  -- ── new ─────────────────────────────────────────────────────────────────────
  local created = one({
    {
      op = "new",
      area = "lib.nvim",
      title = "Brand new",
      fields = { kind = "feature", prio = 2, tags = { "ui" }, refs = { "lua/x.lua" } },
    },
  })
  eq({ created.ok, created.outcome, created.id }, { true, "created", "lib.nvim/brand-new" })
  eq(
    created.file,
    "lib.nvim/ROADMAP/tasks/brand-new.md",
    "a path below the vault, never an absolute one"
  )
  eq(created.changed_ids, { "lib.nvim/brand-new" })
  eq(created.etag_after, find("lib.nvim/brand-new").etag)
  eq(created.index, { action = "written" })
  local nt = find("lib.nvim/brand-new")
  eq(
    { nt.title, nt.kind, nt.prio, nt.tags, nt.created },
    { "Brand new", "feature", 2, { "ui" }, F.TODAY }
  )
  -- the same title again: the next free slug
  eq(one({ { op = "new", area = "lib.nvim", title = "Brand new" } }).id, "lib.nvim/brand-new-2")
  -- what is refused
  eq(one({ { op = "new", area = "no.such.area", title = "x" } }).error.code, "not_found")
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { colour = 1 } } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { plan = "lib.nvim/ship" } } }).error.code,
    "invalid_argument",
    "relations are set afterwards"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { kind = "mystery" } } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "multi\nline" } }).error.code,
    "invalid_argument"
  )
  eq(one({ { op = "new", area = "lib.nvim", title = long } }).error.code, "payload_too_large")
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { refs = { "../x" } } } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { slug = "brand-new" } } }).error.code,
    "exists",
    "a slug that was asked for and is taken"
  )
  -- a title that looks like an option is a title; a tab in it becomes a space (a title is one line of plain text)
  local odd = one({ { op = "new", area = "lib.nvim", title = "--help\tme" } })
  eq(odd.ok, true, vim.inspect(odd))
  eq(odd.id, "lib.nvim/help-me")
  eq(find(odd.id).title, "--help me")

  -- ── reorder ─────────────────────────────────────────────────────────────────
  for _, slug in ipairs({ "r1", "r2", "r3" }) do
    F.task(H, root, "lib.nvim", slug, F.meta(slug, "parked", { { "prio", "3" } }))
  end
  local ro = one({ { op = "reorder", id = "lib.nvim/r3", before = "lib.nvim/r1" } })
  eq({ ro.ok, ro.op, ro.outcome }, { true, "reorder", "changed" }, vim.inspect(ro))
  eq(ro.group, "parked|3", "the group the move happened in")
  eq(ro.changed_ids, { "lib.nvim/r3" })
  eq(ro.inverse, {
    op = "reorder",
    id = "lib.nvim/r3",
    after = "lib.nvim/r2",
    if_match = ro.etag_after,
  })
  eq(ro.index, { action = "written" })
  eq(find("lib.nvim/r3").order, 1)
  local back = one({ ro.inverse })
  eq(
    back.outcome,
    "changed",
    "the inverse puts r3 back behind r2: the tasks before the spot get their numbers"
  )
  eq(back.changed_ids, { "lib.nvim/r1", "lib.nvim/r2", "lib.nvim/r3" })
  eq(
    { find("lib.nvim/r1").order, find("lib.nvim/r2").order, find("lib.nvim/r3").order },
    { 1, 2, 3 }
  )
  eq(one({ { op = "reorder", id = "lib.nvim/gamma", group = "nothing|9" } }).error.code, "conflict")
  eq(
    one({ { op = "reorder", id = "lib.nvim/gamma", after = "cascade.nvim/delta" } }).error.code,
    "conflict",
    "another group"
  )
  eq(one({ { op = "reorder", id = "lib.nvim/ghost" } }).error.code, "not_found")

  -- ── done: a preview first, then the token ───────────────────────────────────
  local ptext = api.call(
    "done_preview",
    vim.json.encode({ params = { id = "lib.nvim/gamma" } }),
    { root = root, today = F.TODAY }
  )
  local pv = vim.json.decode(ptext)
  eq(pv.kind, "tasks.donepreview")
  eq(pv.etag, find("lib.nvim/gamma").etag)
  local no_token = one({ { op = "done", id = "lib.nvim/gamma" } })
  eq(no_token.error.code, "invalid_argument")
  has(no_token.error.message, "confirm")
  ok(find("lib.nvim/gamma"), "still open")
  local last = pv.confirm:sub(-1)
  local wrong = one({
    {
      op = "done",
      id = "lib.nvim/gamma",
      confirm = pv.confirm:sub(1, -2) .. (last == "0" and "1" or "0"),
    },
  })
  eq(wrong.error.code, "invalid_argument", "a token that is not a token")
  local other = one({ { op = "done", id = "lib.nvim/alpha", confirm = pv.confirm } })
  eq(other.error.code, "invalid_argument", "a token for another task")
  ok(find("lib.nvim/alpha"), "and it was not finished")

  -- the file changes after the preview: the token is for a version that is gone
  assert(
    mutate.set(
      "lib.nvim/gamma",
      { summary = "edited meanwhile" },
      { root = root, today = F.TODAY, index = false }
    )
  )
  local late = one({ { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm } })
  eq(late.error.code, "conflict")
  eq(late.error.details.id, "lib.nvim/gamma")
  ok(find("lib.nvim/gamma"), "so it stays")

  pv = vim.json.decode(
    (
      api.call(
        "done_preview",
        vim.json.encode({ params = { id = "lib.nvim/gamma" } }),
        { root = root, today = F.TODAY }
      )
    )
  )
  local fin = one({
    { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm, done_in = "lib.nvim@abc1234" },
  })
  eq({ fin.ok, fin.outcome }, { true, "done" }, vim.inspect(fin))
  eq(fin.to, "lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_gamma.md")
  eq(fin.changed_ids, { "lib.nvim/gamma" })
  eq(fin.index, { action = "written" })
  eq(scan.find("lib.nvim/gamma", { root = root }), nil, "it is gone from ROADMAP")
  ok(H.exists(root .. "/lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_gamma.md"))
  has(
    H.read(root .. "/lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_gamma.md"),
    "done_in: lib.nvim@abc1234"
  )
  local again = one({ { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm } })
  eq(
    { again.ok, again.outcome },
    { true, "unchanged" },
    "finished already: a repeated request does no harm"
  )

  -- ── move_area: a report, never a move ───────────────────────────────────────
  local mv = one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
  eq(mv.error.code, "invalid_argument", "without dry_run the move is refused")
  has(mv.error.message, "dry run")
  local plan_doc = ops(
    { { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } },
    { dry_run = true }
  )
  local m = plan_doc.results[1]
  eq({ m.ok, m.outcome }, { true, "would_move" })
  eq(m.move.new_id, "cascade.nvim/alpha")
  eq(m.move.to, "cascade.nvim/ROADMAP/tasks/alpha.md")
  eq(m.move.references[1], { kind = "blocked_by", id = "lib.nvim/beta" })
  eq(m.changed_ids, {})
  local blocked = ops(
    { { op = "move_area", id = "lib.nvim/alpha", to_area = "lib.nvim" } },
    { dry_run = true }
  )
  eq(blocked.results[1].error.code, "invalid_argument")

  -- ── a dry run writes nothing and says what it would do ──────────────────────
  local snapshot = everything()
  local dry = ops({
    { op = "set", id = "lib.nvim/alpha", patch = { status = "parked" } },
    { op = "new", area = "lib.nvim", title = "Would exist" },
    { op = "reorder", id = "lib.nvim/alpha", before = "lib.nvim/beta" },
    { op = "set", id = "lib.nvim/alpha", patch = { prio = 9 } },
    { op = "done", id = "lib.nvim/beta" },
  }, { dry_run = true })
  eq(dry.dry_run, true)
  eq(everything(), snapshot, "a dry run touches not one byte")
  eq(dry.results[1].outcome, "would_change")
  eq(dry.results[1].etag_after, nil, "the version it would leave is not known")
  eq(dry.results[1].changed_ids, {})
  eq(dry.results[1].inverse, nil)
  eq(dry.results[1].index, nil)
  eq(dry.results[2].outcome, "would_create")
  eq(dry.results[2].id, "lib.nvim/would-exist")
  eq(dry.results[4].error.code, "invalid_argument", "a dry run validates")
  eq(dry.results[5].outcome, "would_done", "done needs no token for a dry run")
  eq(dry.ok, false)

  -- ── no path of this machine in an answer ────────────────────────────────────
  local _, text = ops({
    { op = "set", id = "lib.nvim/ghost", patch = { status = "open" } },
    { op = "new", area = "lib.nvim", title = "A path test" },
    { op = "done", id = "lib.nvim/ghost", confirm = "x" },
    { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
  })
  lacks(text, root)
  lacks(text, (root:gsub("/", "\\")))

  -- ── a link is not written through ───────────────────────────────────────────
  do
    local outside = H.tmpdir() .. "/outside"
    local target = outside .. "/secret.md"
    local secret = F.text(F.meta("From outside", "open"))
    H.write(target, secret)
    local linked = root .. "/lib.nvim/ROADMAP/tasks/linked.md"
    if vim.uv.fs_symlink(target, linked, {}) then
      local e = one({ { op = "set", id = "lib.nvim/linked", patch = { status = "doing" } } })
      eq(e.ok, false)
      ok(
        e.error.code == "forbidden" or e.error.code == "not_found",
        "refused: " .. vim.inspect(e.error)
      )
      eq(H.read(target), secret, "the file outside the vault is untouched")
      vim.uv.fs_unlink(linked)
    end
  end

  -- ── two writers at once: exactly one wins ───────────────────────────────────
  local lib = vim.env.LIB_NVIM_DIR
  if lib and lib ~= "" then
    local contested = find("lib.nvim/beta")
    ---@param status string
    ---@return vim.SystemObj
    local function writer(status)
      local req = vim.json.encode({
        ops = {
          {
            op = "set",
            id = "lib.nvim/beta",
            patch = { status = status },
            if_match = contested.etag,
          },
        },
      })
      return vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-l",
        script_dir .. "/scripts/tasks.lua",
        "call",
        "ops",
        "--params=-",
        "--vault=" .. root,
        "--today=" .. F.TODAY,
      }, { text = true, stdin = req, env = { LIB_NVIM_DIR = lib } })
    end
    local a, b = writer("doing"), writer("parked")
    local ra, rb = a:wait(60000), b:wait(60000)
    local da, db = vim.json.decode(ra.stdout), vim.json.decode(rb.stdout)
    local wins = 0
    local conflicts = 0
    for _, d in ipairs({ da, db }) do
      local e = d.results[1]
      if e.outcome == "changed" then
        wins = wins + 1
      elseif e.error and e.error.code == "conflict" then
        conflicts = conflicts + 1
        eq(e.error.details.expected, contested.etag)
      end
    end
    eq(
      { wins, conflicts },
      { 1, 1 },
      "one wins, the other is told it lost: " .. ra.stdout .. rb.stdout
    )
    eq(
      { ra.code + rb.code },
      { 1 },
      "and the exit code of the loser is a failure for the shell (exactly one of the two)"
    )
    local final = find("lib.nvim/beta")
    ok(final.status == "doing" or final.status == "parked")
    eq(final.blocked_by, { "lib.nvim/alpha" }, "the other keys are as they were")
    eq(
      final.etag,
      (da.results[1].etag_after or db.results[1].etag_after),
      "and the winner's version is what is on disk"
    )
  end

  -- ── the index is current after all this ────────────────────────────────────
  local idx = require("tasks_nvim.index").write_area("lib.nvim", { root = root, check = true })
  eq(idx.action, "unchanged", "the overview of the area matches the files")
  ok(fsio.is_file(root .. "/lib.nvim/ROADMAP/TASKS.md"))
end
