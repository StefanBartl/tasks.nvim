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
    '{"ops":[{"op":"new","area":"lib.nvim","title":"x","body":5}]}',
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

  -- a control character does not get into the vault: it would reach terminals and parsers of other tools
  for _, bad_text in ipairs({
    "red\27[31m",
    "nul\0byte",
    "c1\194\155csi",
    "line\226\128\168sep",
    "del\127",
    -- the shared rule (lib.nvim.contract.ops) also refuses bytes that are no UTF-8: a raw C1 byte is a CSI to an
    -- 8-bit terminal, an overlong form is a slash or an ESC the checks above do not see
    "raw\155csi",
    "overlong\192\175slash",
    "latin1 \252ber",
  }) do
    eq(
      one({ { op = "set", id = "lib.nvim/gamma", patch = { summary = bad_text } } }).error.code,
      "invalid_argument",
      "summary " .. vim.inspect(bad_text)
    )
  end
  eq(
    one({ { op = "set", id = "lib.nvim/gamma", patch = { tags = { "ok", "bad\27" } } } }).error.code,
    "invalid_argument",
    "inside a list too"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "esc\27[2Jtitle" } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ { op = "new", area = "lib.nvim", title = "x", fields = { summary = "a\226\128\169b" } } }).error.code,
    "invalid_argument"
  )
  eq(
    one({
      {
        op = "set",
        id = "lib.nvim/gamma",
        patch = { summary = "Größe 日本 \240\159\152\128 and\ta tab" },
      },
    }).ok,
    true,
    "ordinary text, non-ASCII and a tab are fine"
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
  -- the relations at birth: written as given, judged as `set` judges them
  local related = one({
    {
      op = "new",
      area = "lib.nvim",
      title = "Born related",
      fields = {
        after = { "lib.nvim/gamma", "cascade.nvim/delta" },
        plan = good.id,
        phase = "ship",
      },
    },
  })
  eq({ related.ok, related.outcome }, { true, "created" }, vim.inspect(related))
  local rt = find(related.id)
  eq(
    { rt.after, rt.plan, rt.phase },
    { { "lib.nvim/gamma", "cascade.nvim/delta" }, good.id, "ship" }
  )
  eq(
    find(one({
      {
        op = "new",
        area = "lib.nvim",
        title = "One after",
        fields = { after = "lib.nvim/gamma" },
      },
    }).id).after,
    { "lib.nvim/gamma" },
    "a single id is a list of one"
  )
  ---@param fields table
  ---@return table entry
  local function born(fields)
    local files_before = everything()
    local e = one({ { op = "new", area = "lib.nvim", title = "Refused birth", fields = fields } })
    eq(everything(), files_before, "a refused new writes nothing")
    return e
  end
  local function problem(fields)
    local e = born(fields)
    eq(e.error.code, "invalid_argument", vim.inspect(e))
    return e.error.details.problems[1].code
  end
  eq(problem({ after = { "lib.nvim/nowhere" } }), "after-dangling")
  eq(problem({ after = "lib.nvim/alpha, lib.nvim/nowhere" }), "after-dangling")
  eq(problem({ plan = "lib.nvim/no-plan" }), "plan-unknown")
  eq(problem({ plan = good.id, phase = "nonsense" }), "plan-phase")
  eq(born({ phase = "Not A Slug" }).error.code, "invalid_argument")
  eq(born({ after = { "not an id" } }).error.code, "invalid_argument")
  -- a dry run judges them too
  eq(
    one({
      {
        op = "new",
        area = "lib.nvim",
        title = "Dry related",
        fields = { plan = "lib.nvim/no-plan" },
      },
    }, { dry_run = true }).error.details.problems[1].code,
    "plan-unknown"
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
  -- a move that numbered neighbours: `restore` gives every file its old order back, not only its place
  eq(#ro.restore, 1, "a move that wrote one file has its restore too: r3 had no number")
  eq(ro.restore[1].id, "lib.nvim/r3")
  ok(ro.restore[1].patch.order == vim.NIL, "the key the move added is taken away")
  eq(ro.restore[1].if_match, ro.etag_after)
  eq(#back.restore, 3, "one entry for each file the move wrote")
  for _, step in ipairs(back.restore) do
    eq(step.op, "set")
    eq(one({ step }).outcome, "changed", vim.inspect(step))
  end
  eq(
    { find("lib.nvim/r1").order, find("lib.nvim/r2").order, find("lib.nvim/r3").order },
    { nil, nil, 1 },
    "the neighbours have no number again, the moved task its old one"
  )
  local single = one({ { op = "reorder", id = "lib.nvim/r2", before = "lib.nvim/r3" } })
  eq(single.changed_ids, { "lib.nvim/r2" })
  eq(one({ single.restore[1] }).outcome, "changed")
  eq(find("lib.nvim/r2").order, nil, "one file written, one file restored: r2 has no number again")
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
    {
      op = "done",
      id = "lib.nvim/gamma",
      confirm = pv.confirm,
      done_in = "lib.nvim@abc1234",
      commits = { "lib.nvim@abc1234", "tasks.nvim@def5678" },
    },
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
  has(
    H.read(root .. "/lib.nvim/Backlog/TASKS/" .. F.TODAY .. "_gamma.md"),
    "commits: [lib.nvim@abc1234, tasks.nvim@def5678]"
  )
  local again = one({ { op = "done", id = "lib.nvim/gamma", confirm = pv.confirm } })
  eq(
    { again.ok, again.outcome },
    { true, "unchanged" },
    "finished already: a repeated request does no harm"
  )

  -- ── move_area: a report with dry_run, the move without ───────────────────────
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

  -- two moves of one request that meet in one target: the dry run sees the disk only, so it must say for the second
  -- what the real run does (an open task of that name is there by then); the dry run writes nothing
  F.task(H, root, "third.nvim", "anchor", F.meta("Anchor", "open", {}))
  F.task(H, root, "lib.nvim", "twin", F.meta("Twin", "open", {}))
  F.task(H, root, "cascade.nvim", "twin", F.meta("Twin", "open", {}))
  local before_twins = everything()
  local twins = ops({
    { op = "move_area", id = "lib.nvim/twin", to_area = "third.nvim" },
    { op = "move_area", id = "cascade.nvim/twin", to_area = "third.nvim" },
  }, { dry_run = true }).results
  eq({ twins[1].ok, twins[1].outcome }, { true, "would_move" }, vim.inspect(twins[1]))
  eq({ twins[2].ok, twins[2].outcome }, { false, "blocked" }, vim.inspect(twins[2]))
  eq(twins[2].move.conflicts[1].code, "slug-taken")
  has(twins[2].move.conflicts[1].message, "another move of this request")
  eq(everything(), before_twins, "a dry run touches not one byte")
  vim.fn.delete(root .. "/third.nvim", "rf")
  os.remove(find("lib.nvim/twin").path)
  os.remove(find("cascade.nvim/twin").path)

  -- the move: file, references and indexes follow, the answer carries the way moved_back
  local moved = one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
  eq({ moved.ok, moved.outcome, moved.new_id }, { true, "moved", "cascade.nvim/alpha" })
  eq(scan.find("lib.nvim/alpha", { root = root }), nil, "the old id is gone")
  eq(find("cascade.nvim/alpha").area, "cascade.nvim")
  eq(
    find("lib.nvim/beta").blocked_by,
    { "cascade.nvim/alpha" },
    "what named the old id names the new one"
  )
  eq(moved.rewritten, { { kind = "blocked_by", id = "lib.nvim/beta" } })
  eq(moved.inverse.op, "move_area")
  eq({ moved.inverse.id, moved.inverse.to_area }, { "cascade.nvim/alpha", "lib.nvim" })
  eq(moved.etag_after, find("cascade.nvim/alpha").etag)
  has(H.read(root .. "/cascade.nvim/ROADMAP/TASKS.md"), "alpha")
  local moved_back = one({ moved.inverse })
  eq({ moved_back.ok, moved_back.outcome, moved_back.new_id }, { true, "moved", "lib.nvim/alpha" })
  eq(find("lib.nvim/beta").blocked_by, { "lib.nvim/alpha" })

  -- a taken slug, a stale_move version and an unknown area write nothing
  local clash = one({ { op = "new", area = "cascade.nvim", title = "Alpha" } })
  eq(clash.outcome, "created")
  local state = everything()
  local refused_move =
    one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
  eq({ refused_move.ok, refused_move.error.code }, { false, "invalid_argument" })
  eq(everything(), state, "a refused_move move touches not one byte")
  os.remove(find(clash.id).path)
  local stale_move = one({
    {
      op = "move_area",
      id = "lib.nvim/alpha",
      to_area = "cascade.nvim",
      if_match = "sha256:0000000000000000",
    },
  })
  eq(stale_move.error.code, "conflict")
  eq(
    one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "nowhere.nvim" } }).error.code,
    "not_found"
  )
  eq(find("lib.nvim/alpha").area, "lib.nvim")

  -- a plan whose target it is follows the move, and comes back with it
  local target_plan = one({
    { op = "plan_new", area = "lib.nvim", title = "Move target plan", target = "lib.nvim/alpha" },
  })
  eq(target_plan.ok, true)
  local plan_file = root .. "/" .. target_plan.file
  has(H.read(plan_file), "target: lib.nvim/alpha")
  -- a task that names it in after and refs, so every kind of reference a check can find is there
  local follower_path = root .. "/lib.nvim/ROADMAP/tasks/follower.md"
  F.task(
    H,
    root,
    "lib.nvim",
    "follower",
    F.meta("Follower", "open", { { "after", "[lib.nvim/alpha]" }, { "refs", "[lib.nvim/alpha]" } })
  )

  ---The findings of `check` that say a reference points nowhere.
  ---@return string[]  # `<code> <id>`, sorted
  local function dangling()
    local res = assert(require("tasks_nvim.check").run({ root = root }))
    local out = {}
    for _, f in ipairs(res.findings) do
      if
        f.code == "blocked-by-dangling"
        or f.code == "after-dangling"
        or f.code == "plan-target-unknown"
      then
        out[#out + 1] = f.code .. " " .. tostring(f.id)
      end
    end
    table.sort(out)
    return out
  end
  -- a positive control: the detector finds what it is for, or the empty answers below prove nothing
  F.task(
    H,
    root,
    "lib.nvim",
    "ghostly",
    F.meta("Ghostly", "open", {
      { "after", "[lib.nvim/no-such]" },
      { "blocked_by", "lib.nvim/no-such-either" },
    })
  )
  eq(
    dangling(),
    { "after-dangling lib.nvim/ghostly", "blocked-by-dangling lib.nvim/ghostly" },
    "a relation that points nowhere is found"
  )
  os.remove(find("lib.nvim/ghostly").path)
  eq(dangling(), {}, "nothing dangles before the move")

  local with_plan = one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
  eq(with_plan.outcome, "moved")
  has(H.read(plan_file), "target: cascade.nvim/alpha")
  eq(
    vim.tbl_contains(
      vim.tbl_map(function(r)
        return r.kind
      end, with_plan.rewritten),
      "plan_target"
    ),
    true
  )
  eq(find("lib.nvim/follower").after, { "cascade.nvim/alpha" })
  eq(find("lib.nvim/follower").refs, { "cascade.nvim/alpha" })
  -- acceptance of the move (stage 2): after it, check finds no reference that points nowhere
  eq(dangling(), {}, "check finds nothing dangling after the move")
  one({ with_plan.inverse })
  has(H.read(plan_file), "target: lib.nvim/alpha")
  eq(dangling(), {}, "nor after the move back")
  os.remove(follower_path)

  -- a folder task moves as a whole, with what lies beside its file
  local folder_dir = root .. "/lib.nvim/ROADMAP/tasks/folio"
  H.write(folder_dir .. "/folio.md", F.text(F.meta("Folio", "open")))
  H.write(folder_dir .. "/asset.txt", "beside the task")
  local folio = one({ { op = "move_area", id = "lib.nvim/folio", to_area = "cascade.nvim" } })
  eq(folio.outcome, "moved")
  eq(vim.fn.isdirectory(folder_dir), 0, "the folder left the old area")
  eq(H.read(root .. "/cascade.nvim/ROADMAP/tasks/folio/asset.txt"), "beside the task")
  eq(find("cascade.nvim/folio").folder, true)
  one({ folio.inverse })
  eq(H.read(folder_dir .. "/asset.txt"), "beside the task")

  -- a rewrite that cannot be made (the lock of a referencing task is stuck) puts everything back
  do
    local lock = root .. "/lib.nvim/ROADMAP/tasks/.beta.md.lock"
    vim.fn.mkdir(lock, "p")
    local state_before = everything()
    local failed_move =
      one({ { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
    eq(failed_move.ok, false)
    eq(failed_move.error.code, "lock_stuck")
    vim.fn.delete(lock, "d")
    state_before[lock] = nil
    eq(everything(), state_before, "a failed move leaves every byte as it was")
    eq(find("lib.nvim/alpha").area, "lib.nvim")
    eq(find("lib.nvim/beta").blocked_by, { "lib.nvim/alpha" })
  end

  -- a step after the file moved fails and the rollback cannot put the file back: the answer says
  -- `rollback incomplete` and names the path, and the text stays where it is (the new file holds it)
  do
    local lock = root .. "/lib.nvim/ROADMAP/tasks/.beta.md.lock"
    local alpha_path = find("lib.nvim/alpha").path
    local alpha_text = H.read(alpha_path)
    local real_create = fsio.create_exclusive
    vim.fn.mkdir(lock, "p")
    fsio.create_exclusive = function(path, content)
      if vim.fs.normalize(path) == vim.fs.normalize(alpha_path) then
        return false, "stubbed restore failure"
      end
      return real_create(path, content)
    end
    local okc, failed =
      pcall(one, { { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" } })
    fsio.create_exclusive = real_create
    vim.fn.delete(lock, "d")
    ok(okc, tostring(failed))
    eq(failed.ok, false)
    eq(failed.error.code, "lock_stuck", "the reason of the failing step keeps its code")
    has(failed.error.message, "rollback incomplete")
    has(
      failed.error.message,
      "lib.nvim/ROADMAP/tasks/alpha.md",
      "the path that could not be restored"
    )
    has(
      failed.error.message,
      "cascade.nvim/ROADMAP/tasks/alpha.md",
      "and the file that holds the text"
    )
    local stranded = root .. "/cascade.nvim/ROADMAP/tasks/alpha.md"
    has(H.read(stranded), "title: Alpha", "the text is not lost")
    -- put the vault back by hand for the specs that follow
    H.write(alpha_path, alpha_text)
    os.remove(stranded)
    eq(find("lib.nvim/alpha").area, "lib.nvim")
  end

  -- the same for a folder task: the folder moved, writing its file failed, and the folder cannot be
  -- moved back; the answer names it
  do
    local folio_dir = root .. "/lib.nvim/ROADMAP/tasks/folio"
    local dst_dir = root .. "/cascade.nvim/ROADMAP/tasks/folio"
    local real_rename, real_write = fsio.rename, fsio.write_atomic
    fsio.write_atomic = function(path, content)
      if vim.fs.normalize(path) == vim.fs.normalize(dst_dir .. "/folio.md") then
        return false, "stubbed write failure"
      end
      return real_write(path, content)
    end
    fsio.rename = function(from, to)
      if vim.fs.normalize(from) == vim.fs.normalize(dst_dir) then
        return false, "stubbed rename-back failure"
      end
      return real_rename(from, to)
    end
    local okc, failed =
      pcall(one, { { op = "move_area", id = "lib.nvim/folio", to_area = "cascade.nvim" } })
    fsio.rename, fsio.write_atomic = real_rename, real_write
    ok(okc, tostring(failed))
    eq(failed.ok, false)
    has(failed.error.message, "stubbed write failure")
    has(failed.error.message, "rollback incomplete")
    has(
      failed.error.message,
      "cascade.nvim/ROADMAP/tasks/folio",
      "the folder that could not be moved back"
    )
    eq(H.read(dst_dir .. "/asset.txt"), "beside the task", "the folder keeps what lay in it")
    -- put the vault back by hand
    ok(real_rename(dst_dir, folio_dir))
    H.write(folio_dir .. "/folio.md", F.text(F.meta("Folio", "open")))
    eq(find("lib.nvim/folio").area, "lib.nvim")
  end

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

  -- ── a task in a dependency cycle has no place in the order ─────────────────
  do
    local cyc_root = F.vault(H)
    F.task(H, cyc_root, "lib.nvim", "c1", F.meta("C1", "open", { { "blocked_by", "lib.nvim/c2" } }))
    F.task(H, cyc_root, "lib.nvim", "c2", F.meta("C2", "open", { { "blocked_by", "lib.nvim/c1" } }))
    local text = api.call(
      "ops",
      vim.json.encode({ ops = { { op = "reorder", id = "lib.nvim/c1" } } }),
      { root = cyc_root, today = F.TODAY }
    )
    local e = vim.json.decode(text).results[1]
    eq({ e.ok, e.error and e.error.code }, { false, "invalid_argument" }, text)
    has(e.error.message, "dependency cycle")
  end

  -- ── an internal error names the file in the plugin, never where the plugin is installed ──
  do
    local errors = require("lib.nvim.contract.errors")
    eq(
      errors.scrub("B:\\repos\\tasks.nvim/lua/tasks_nvim/edges.lua:116: attempt to index nil"),
      "tasks_nvim/edges.lua:116: attempt to index nil"
    )
    eq(
      errors.scrub(
        "C:\\Users\\x\\AppData\\Local\\nvim-data\\lazy\\tasks.nvim\\lua\\tasks_nvim\\ops.lua:9: boom"
      ),
      "tasks_nvim\\ops.lua:9: boom"
    )
    eq(
      errors.scrub("/home/x/.local/share/nvim/lazy/tasks.nvim/lua/tasks_nvim/x.lua:1: y"),
      "tasks_nvim/x.lua:1: y"
    )
    eq(errors.scrub("plain message"), "plain message")
    eq(errors.classify("/opt/p/lua/tasks_nvim/a.lua:2: bug").message, "tasks_nvim/a.lua:2: bug")
    eq(errors.classify("a message about nothing known").code, "internal")
  end

  -- ── no path of this machine in an answer ────────────────────────────────────
  local _, text = ops({
    { op = "set", id = "lib.nvim/ghost", patch = { status = "open" } },
    { op = "new", area = "lib.nvim", title = "A path test" },
    { op = "done", id = "lib.nvim/ghost", confirm = "x" },
    { op = "move_area", id = "lib.nvim/alpha", to_area = "lib.nvim" },
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

  -- ── plan_new: a plan file, with a dry run that names it ─────────────────────────
  do
    local files_before = everything()
    local wizard_dry = one({
      {
        op = "plan_new",
        area = "lib.nvim",
        title = "Wizard plan",
        areas = { "lib.nvim", "cascade.nvim" },
        target = "lib.nvim/alpha",
        phases = { "design", "build" },
        gate = "hard",
        summary = "Made by the wizard.",
      },
    }, { dry_run = true })
    eq(wizard_dry.ok, true, vim.inspect(wizard_dry))
    eq(wizard_dry.outcome, "would_create")
    eq(wizard_dry.id, "lib.nvim/wizard-plan")
    eq(wizard_dry.slug, "wizard-plan")
    eq(wizard_dry.renamed, false)
    eq(wizard_dry.file, "lib.nvim/ROADMAP/plans/wizard-plan.md")
    eq(wizard_dry.changed_ids, {})
    eq(everything(), files_before, "a dry run writes nothing, not even the folder")

    local made = one({
      {
        op = "plan_new",
        area = "lib.nvim",
        title = "Wizard plan",
        areas = { "lib.nvim", "cascade.nvim" },
        target = "lib.nvim/alpha",
        phases = { "design", "build" },
        gate = "hard",
        summary = "Made by the wizard.",
      },
    })
    eq(made.ok, true, vim.inspect(made))
    eq(made.outcome, "created")
    eq(made.id, "lib.nvim/wizard-plan")
    eq(made.changed_ids, { "lib.nvim/wizard-plan" })
    local plan_text = H.read(root .. "/lib.nvim/ROADMAP/plans/wizard-plan.md")
    has(plan_text, "title: Wizard plan")
    has(plan_text, "gate: hard")
    has(plan_text, "Made by the wizard.")
    local file =
      plans.from_file(root .. "/lib.nvim/ROADMAP/plans/wizard-plan.md", { area = "lib.nvim" })
    eq(file.phase_order, { "design", "build" })
    eq(file.target, "lib.nvim/alpha")

    -- The same title again: the name is taken, another one is chosen, and the dry run says so beforehand.
    local again_dry = one(
      { { op = "plan_new", area = "lib.nvim", title = "Wizard plan" } },
      { dry_run = true }
    )
    eq({ again_dry.slug, again_dry.renamed }, { "wizard-plan-2", true })
    local again_real = one({ { op = "plan_new", area = "lib.nvim", title = "Wizard plan" } })
    eq({ again_real.id, again_real.renamed }, { "lib.nvim/wizard-plan-2", true })

    -- A task holds its name too (plans, tasks and finished items share one namespace per area).
    local held = one(
      { { op = "plan_new", area = "lib.nvim", title = "Alpha" } },
      { dry_run = true }
    )
    eq({ held.slug, held.renamed }, { "alpha-2", true })
    -- A folder with the name of a plan file holds it as well, in the dry run and in the real run.
    vim.fn.mkdir(root .. "/lib.nvim/ROADMAP/plans/dir-slug.md", "p")
    local folder_dry = one(
      { { op = "plan_new", area = "lib.nvim", title = "Dir slug" } },
      { dry_run = true }
    )
    local folder_real = one({ { op = "plan_new", area = "lib.nvim", title = "Dir slug" } })
    eq(folder_dry.id, folder_real.id, "the dry run names the plan the real run makes")
    -- A slug can be asked for.
    local own = one(
      { { op = "plan_new", area = "lib.nvim", title = "Whatever", slug = "my-own" } },
      { dry_run = true }
    )
    eq(own.id, "lib.nvim/my-own")

    -- What is refused is told with a reason and nothing is written.
    local vault_before = everything()
    local function refused(op, needle, code)
      local entry = one({ op })
      eq(entry.ok, false, vim.inspect(entry))
      eq(entry.error.code, code or "invalid_argument", vim.inspect(entry))
      has(entry.error.message, needle)
    end
    refused({ op = "plan_new", area = "nowhere.nvim", title = "X" }, "unknown area", "not_found")
    refused({ op = "plan_new", area = "lib.nvim", title = "bad\27title" }, "control character")
    refused({ op = "plan_new", area = "lib.nvim", title = "X", phases = { "Not Kebab" } }, "kebab")
    refused(
      { op = "plan_new", area = "lib.nvim", title = "X", phases = { "a,b" } },
      "must not contain"
    )
    -- a control character is refused in every text the request carries, not in the title only
    for _, field in ipairs({ "summary", "slug", "target", "gate", "status" }) do
      local op = { op = "plan_new", area = "lib.nvim", title = "X" }
      op[field] = "bad\27value"
      refused(op, "control character")
    end
    refused(
      { op = "plan_new", area = "lib.nvim", title = "X", areas = { "a\27b" } },
      "control character"
    )
    refused(
      { op = "plan_new", area = "lib.nvim", title = "X", phases = { "a\27b" } },
      "control character"
    )
    refused({ op = "plan_new", area = "lib.\27[31mnvim", title = "X" }, "control character")
    refused(
      { op = "plan_new", area = string.rep("a", 400), title = "X" },
      "longer",
      "payload_too_large"
    )
    refused(
      { op = "plan_new", area = "lib.nvim", title = "X", slug = string.rep("a", 201) },
      "longer than"
    )
    refused({ op = "new", area = "lib.\27[31mnvim", title = "X" }, "control character")
    refused({ op = "plan_new", area = "lib.nvim", title = "X", gate = "soft" }, "gate")
    refused({ op = "plan_new", area = "lib.nvim", title = "X", status = "done" }, "status")
    refused({ op = "plan_new", area = "lib.nvim", title = "X", summary = "two\nlines" }, "one line")
    refused({ op = "plan_new", area = "lib.nvim", title = "X", target = "nonsense" }, "target")
    refused(
      { op = "plan_new", area = "lib.nvim", title = string.rep("x", 301) },
      "longer",
      "payload_too_large"
    )
    eq(everything(), vault_before, "refused plans leave the vault as it was")
    local unknown_field =
      ops({ { op = "plan_new", area = "lib.nvim", title = "X", surprise = true } })
    eq(unknown_field.kind, "tasks.error", "an unknown field is refused for the whole request")
  end

  -- ── the index is current after all this ────────────────────────────────────
  local idx = require("tasks_nvim.index").write_area("lib.nvim", { root = root, check = true })
  eq(idx.action, "unchanged", "the overview of the area matches the files")
  ok(fsio.is_file(root .. "/lib.nvim/ROADMAP/TASKS.md"))

  -- ── an index that cannot be written does not add a field to the document ───
  do
    local index = require("tasks_nvim.index")
    local real = index.write_area
    index.write_area = function()
      error(root .. "/lib.nvim/ROADMAP/TASKS.md: disk on fire")
    end
    local pcalled, got = pcall(ops, { { op = "new", area = "lib.nvim", title = "Index probe" } })
    index.write_area = real
    ok(pcalled, "an index that raises does not take the door down")
    eq(got.kind, "tasks.result", "the answer is still a result")
    eq(got.finish_error, nil, "tasks-ops/1 has no finish_error")
    eq(got.results[1].ok, true, vim.inspect(got.results[1]))
    eq(got.results[1].index.action, "error", "the index failure is told on the entry")
    ok(
      not tostring(got.results[1].index.error):find(root, 1, true),
      "and names no path of this machine"
    )
  end
end
