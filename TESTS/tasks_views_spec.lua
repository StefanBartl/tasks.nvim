-- TESTS/tasks_views_spec.lua -- the saved views of the tasks: the file each is kept in, the document `tasks.views`, and the
-- operations `view_save` and `view_delete` through the write door: what they write, the compare-and-set, the dry run, the
-- inverse, and what they refuse.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local views = require("tasks_nvim.views")

  local root = F.vault(H)

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

  ---@return table doc
  local function listing()
    local text = api.call("views", nil, { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    eq(doc.kind, "tasks.views", vim.inspect(doc))
    return doc
  end

  ---@param id string
  ---@return string path
  local function path_of(id)
    local area, slug = id:match("^([^/]+)/(.+)$")
    return views.path(root, area, slug)
  end

  ---@param id string
  ---@return string
  local function etag(id)
    return fsio.etag(H.read(path_of(id)))
  end

  local BY_STATUS = { title = "By status", display = "columns", group_by = "status" }

  -- no view: the document is there, with empty lists (an empty list is `[]`, never `{}`)
  local empty_text = api.call("views", nil, { root = root, today = F.TODAY })
  local empty = vim.json.decode(empty_text)
  eq({ empty.views, empty.problems }, { {}, {} })
  has(empty_text, '"views":[]')
  has(empty_text, '"problems":[]')

  -- a new view: a file at <area>/ROADMAP/views/<slug>.md, named from the title, with the dates of the day
  local made = one({ op = "view_save", area = "lib.nvim", view = BY_STATUS })
  eq(
    { made.ok, made.outcome, made.id },
    { true, "created", "lib.nvim/by-status" },
    vim.inspect(made)
  )
  eq(made.file, "lib.nvim/ROADMAP/views/by-status.md")
  eq(made.etag_after, etag("lib.nvim/by-status"))
  local text = H.read(path_of("lib.nvim/by-status"))
  has(text, "title: By status")
  has(text, "display: columns")
  has(text, "group_by: status")
  has(text, "created: " .. F.TODAY)
  has(text, "updated: " .. F.TODAY)
  -- no key of the selection is written for an empty selection
  lacks(text, "sel_")

  -- the same title again gets the next free name, never the file of the first
  local second = one({ op = "view_save", area = "lib.nvim", view = BY_STATUS })
  eq({ second.ok, second.id }, { true, "lib.nvim/by-status-2" }, vim.inspect(second))
  eq(H.read(path_of("lib.nvim/by-status")), text)

  -- the document: sorted by id, each with the version tag of its file, the selection as lists
  local full = one({
    op = "view_save",
    area = "cascade.nvim",
    view = {
      title = "Prio by actor",
      display = "matrix",
      group_by = "prio",
      group_by2 = "actor",
      collapsed = { "3" },
      select = { areas = { "lib.nvim", "cascade.nvim" }, tags = { "golden" }, query = "build" },
    },
  })
  eq(full.ok, true, vim.inspect(full))
  local doc = listing()
  local ids = {}
  for _, v in ipairs(doc.views) do
    ids[#ids + 1] = v.id
  end
  eq(ids, { "cascade.nvim/prio-by-actor", "lib.nvim/by-status", "lib.nvim/by-status-2" })
  local matrix = doc.views[1]
  eq(matrix.etag, etag("cascade.nvim/prio-by-actor"))
  eq(
    { matrix.display, matrix.group_by, matrix.group_by2, matrix.collapsed },
    { "matrix", "prio", "actor", { "3" } }
  )
  eq(matrix.select, {
    areas = { "lib.nvim", "cascade.nvim" },
    statuses = {},
    actors = {},
    kinds = {},
    tags = { "golden" },
    plans = {},
    query = "build",
  }, "every list of the selection is there, the empty ones too")
  eq({ matrix.created, matrix.updated }, { F.TODAY, F.TODAY })

  -- a view is no task: it is in no list of the tasks
  local snapshot = vim.json.decode((api.call("snapshot", nil, { root = root, today = F.TODAY })))
  eq(#snapshot.tasks, 0)

  -- the rev follows the files: a change of a view is a new rev, a read of the same files is the same
  local rev = doc.rev
  eq(listing().rev, rev)

  -- replacing a view that exists takes the version the caller read: without it, and with a stale one, it is a conflict
  local target = "lib.nvim/by-status"
  local before = H.read(path_of(target))
  local other =
    { title = "By status", display = "list", group_by = "status", collapsed = { "parked" } }
  local bare = one({ op = "view_save", id = target, view = other })
  eq({ bare.ok, bare.error.code }, { false, "conflict" }, vim.inspect(bare))
  eq(H.read(path_of(target)), before)
  local stale =
    one({ op = "view_save", id = target, view = other, if_match = "sha256:0000000000000000" })
  eq({ stale.ok, stale.error.code }, { false, "conflict" }, vim.inspect(stale))
  eq(stale.error.details.actual, etag(target))
  eq(H.read(path_of(target)), before)

  -- with the right version: replaced, `created` kept, the entry carries both versions and the inverse
  local tag = etag(target)
  local changed = one({ op = "view_save", id = target, view = other, if_match = tag })
  eq(
    { changed.ok, changed.outcome, changed.etag_before },
    { true, "changed", tag },
    vim.inspect(changed)
  )
  eq(changed.etag_after, etag(target))
  has(H.read(path_of(target)), "display: list")
  has(H.read(path_of(target)), "created: " .. F.TODAY)
  ok(listing().rev ~= rev, "the rev of the views changed with a view")

  -- the inverse puts the view back, and is itself a change that can be undone
  eq(changed.inverse.op, "view_save")
  eq(changed.inverse.id, target)
  eq(changed.inverse.if_match, changed.etag_after)
  local undone = one(changed.inverse)
  eq({ undone.ok, undone.outcome }, { true, "changed" }, vim.inspect(undone))
  eq(H.read(path_of(target)), before, "the file is as it was, byte for byte")

  -- the same view again is unchanged and writes nothing
  local same = one({ op = "view_save", id = target, view = BY_STATUS, if_match = etag(target) })
  eq({ same.ok, same.outcome }, { true, "unchanged" }, vim.inspect(same))
  eq(same.inverse, nil)
  eq(H.read(path_of(target)), before)

  -- a version on a name that is free is a conflict too: the view is gone
  local gone =
    one({ op = "view_save", id = "lib.nvim/never-made", view = BY_STATUS, if_match = tag })
  eq({ gone.ok, gone.error.code }, { false, "conflict" }, vim.inspect(gone))
  ok(not H.exists(path_of("lib.nvim/never-made")))

  -- a name given with no file makes one
  local named = one({ op = "view_save", id = "lib.nvim/chosen-name", view = BY_STATUS })
  eq({ named.ok, named.outcome }, { true, "created" }, vim.inspect(named))
  ok(H.exists(path_of("lib.nvim/chosen-name")))

  -- a dry run says what it would do and writes nothing
  local dry = one({ op = "view_save", area = "lib.nvim", view = BY_STATUS }, { dry_run = true })
  eq({ dry.ok, dry.outcome }, { true, "would_create" }, vim.inspect(dry))
  eq(dry.inverse, nil)
  ok(not H.exists(path_of("lib.nvim/by-status-3")))
  local dry_change = one(
    { op = "view_save", id = target, view = other, if_match = etag(target) },
    { dry_run = true }
  )
  eq({ dry_change.ok, dry_change.outcome }, { true, "would_change" }, vim.inspect(dry_change))
  eq(H.read(path_of(target)), before)

  -- a file that is no view is a problem of the document, not a view and not a failure of the others
  H.write(
    root .. "/lib.nvim/ROADMAP/views/broken.md",
    "---\ntitle: Broken\ndisplay: cube\ngroup_by: status\n---\n"
  )
  H.write(root .. "/lib.nvim/ROADMAP/views/no-frontmatter.md", "just text\n")
  local with_problems = listing()
  local problem_ids = {}
  for _, p in ipairs(with_problems.problems) do
    problem_ids[#problem_ids + 1] = p.id
    lacks(p.message, root, "a problem names no path of the machine")
  end
  eq(problem_ids, { "lib.nvim/broken", "lib.nvim/no-frontmatter" })
  eq(#with_problems.views, 4, "the views that can be read are all there")
  -- and it can be replaced by a good one on the version it has
  local mended = one({
    op = "view_save",
    id = "lib.nvim/broken",
    view = BY_STATUS,
    if_match = etag("lib.nvim/broken"),
  })
  eq({ mended.ok, mended.outcome }, { true, "changed" }, vim.inspect(mended))
  eq(mended.inverse, nil, "a file that was no view has nothing to go back to")
  os.remove(path_of("lib.nvim/no-frontmatter"))

  -- delete: gone, with the inverse that makes it again
  local victim = "cascade.nvim/prio-by-actor"
  local victim_view = vim.deepcopy(listing().views[1])
  eq(victim_view.id, victim)
  local deleted = one({ op = "view_delete", id = victim, if_match = etag(victim) })
  eq({ deleted.ok, deleted.outcome }, { true, "deleted" }, vim.inspect(deleted))
  ok(not H.exists(path_of(victim)))
  local back = one(deleted.inverse)
  eq({ back.ok, back.outcome }, { true, "created" }, vim.inspect(back))
  local restored = nil
  for _, v in ipairs(listing().views) do
    if v.id == victim then
      restored = v
    end
  end
  eq(restored.select, victim_view.select)
  eq(
    { restored.display, restored.group_by, restored.group_by2, restored.collapsed, restored.title },
    { "matrix", "prio", "actor", { "3" }, "Prio by actor" }
  )

  -- delete on a stale version is a conflict and the file stays; a dry run deletes nothing
  local keep = one({ op = "view_delete", id = victim, if_match = "sha256:0000000000000000" })
  eq({ keep.ok, keep.error.code }, { false, "conflict" }, vim.inspect(keep))
  ok(H.exists(path_of(victim)))
  local dry_delete = one({ op = "view_delete", id = victim }, { dry_run = true })
  eq({ dry_delete.ok, dry_delete.outcome }, { true, "would_delete" }, vim.inspect(dry_delete))
  ok(H.exists(path_of(victim)))

  -- refused: a view that does not hold together, an area that is not there, a name that leads out of the folder
  local function refused(op, code, needle)
    local r = one(op)
    eq({ r.ok, r.error.code }, { false, code }, vim.inspect(r))
    if needle then
      has(r.error.message, needle)
    end
  end
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "cube", group_by = "status" },
  }, "invalid_argument", "cube")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "columns", group_by = "colour" },
  }, "invalid_argument", "colour")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "", display = "columns", group_by = "status" },
  }, "invalid_argument")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "a\nb", display = "columns", group_by = "status" },
  }, "invalid_argument")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "columns", group_by = "status", group_by2 = "prio" },
  }, "invalid_argument")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "matrix", group_by = "status", group_by2 = "status" },
  }, "invalid_argument")
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "matrix", group_by = "status" },
  }, "invalid_argument")
  refused({ op = "view_save", area = "nowhere", view = BY_STATUS }, "not_found", "nowhere")
  refused(
    { op = "view_save", area = "lib.nvim", slug = "../evil", view = BY_STATUS },
    "invalid_argument"
  )
  refused({ op = "view_save", id = "lib.nvim/../evil", view = BY_STATUS }, "invalid_argument")
  refused({ op = "view_save", id = "lib.nvim", view = BY_STATUS }, "invalid_argument")
  refused(
    { op = "view_save", id = "lib.nvim/x", area = "lib.nvim", view = BY_STATUS },
    "invalid_argument"
  )
  refused({ op = "view_save", area = "lib.nvim" }, "invalid_argument")
  refused({ op = "view_save", view = BY_STATUS }, "invalid_argument")
  refused({ op = "view_delete", id = "lib.nvim/never-made-either" }, "not_found")
  refused({ op = "view_delete", id = "../x" }, "not_found")
  refused({ op = "view_delete", id = "lib.nvim/../../x" }, "not_found")
  refused({ op = "view_delete" }, "invalid_argument")
  local too_many = {}
  for i = 1, views.MAX_LIST + 1 do
    too_many[i] = "t" .. i
  end
  refused({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "x", display = "list", group_by = "status", select = { tags = too_many } },
  }, "invalid_argument")
  ok(
    not H.exists(root .. "/evil.md") and not H.exists(root .. "/lib.nvim/ROADMAP/evil.md"),
    "nothing written outside the folder"
  )

  -- a view can hold the limits it promises
  local fits = {}
  for i = 1, views.MAX_LIST do
    fits[i] = "t" .. i
  end
  local big = one({
    op = "view_save",
    area = "lib.nvim",
    view = { title = "Big", display = "list", group_by = "tags", select = { tags = fits } },
  })
  eq(big.ok, true, vim.inspect(big))
  local big_view
  for _, v in ipairs(listing().views) do
    if v.id == "lib.nvim/big" then
      big_view = v
    end
  end
  eq(big_view.select.tags, fits)

  -- a title with the characters of a frontmatter value (quotes, a colon, a hash, an umlaut) comes back as it went in
  local odd = 'Ärger: "so" # nicht'
  local made_odd = one({
    op = "view_save",
    area = "lib.nvim",
    slug = "odd",
    view = { title = odd, display = "list", group_by = "status" },
  })
  eq(made_odd.ok, true, vim.inspect(made_odd))
  for _, v in ipairs(listing().views) do
    if v.id == "lib.nvim/odd" then
      eq(v.title, odd)
    end
  end
end
