-- TESTS/tasks_reopen_spec.lua -- `reopen` of the write door: a finished task comes back to ROADMAP/tasks, its row leaves
-- the Backlog README, and what must not be done is refused (a name that is taken, a folder task, an old version).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, has, lacks = H.eq, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }

  ---@param list table[]
  ---@param extra? table
  ---@return table entry
  local function one(list, extra)
    local text = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = list }, extra or {})),
      { root = root, today = F.TODAY }
    )
    local doc = vim.json.decode(text)
    eq(doc.kind, "tasks.result", text)
    return doc.results[1]
  end

  ---@param title string
  ---@param extra? table
  ---@return string id
  local function finished(title, extra)
    local made =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {})))
    assert(mutate.done(
      made.id,
      vim.tbl_extend("force", o, {
        done_in = "lib.nvim@abc1234",
        commits = "lib.nvim@abc1234",
        remind = "2026-12-01",
      })
    ))
    return made.id
  end

  local readme = root .. "/lib.nvim/Backlog/README.md"
  local function backlog_file(id)
    return assert(scan.find_done(id, { root = root })).path
  end

  -- ── a finished task comes back ─────────────────────────────────────────────
  local a = finished("Came back")
  local b = finished("Stays finished")
  local done_path = backlog_file(a)
  local before = H.read(done_path)
  has(before, "status: done")
  has(before, "done_in: lib.nvim@abc1234")
  has(H.read(readme), "Came back")
  has(H.read(readme), "## TASKS (2)")

  local dry = one({ { op = "reopen", id = a } }, { dry_run = true })
  eq({ dry.ok, dry.outcome }, { true, "would_change" }, vim.inspect(dry))
  eq(fsio.is_file(done_path), true, "a dry run moves nothing")
  eq(scan.find(a, { root = root }), nil)

  local e = one({ { op = "reopen", id = a } })
  eq({ e.ok, e.outcome, e.changed_ids }, { true, "changed", { a } }, vim.inspect(e))
  eq(e.file, "lib.nvim/ROADMAP/tasks/came-back.md")
  local open = assert(scan.find(a, { root = root }), "the task is open again")
  eq(open.status, "open")
  local text = H.read(open.path)
  lacks(text, "done_in:")
  lacks(text, "remind:")
  has(text, "commits: [lib.nvim@abc1234]") -- the work was done: the commits stay with the task
  has(text, "updated: " .. F.TODAY)
  has(text, "title: Came back")
  eq(fsio.is_file(done_path), false, "the finished file is gone")
  eq(e.etag_after, fsio.etag(text), "the answer names the version it wrote")

  -- the README lost that row and only that row
  local md = H.read(readme)
  lacks(md, "Came back")
  has(md, "Stays finished")
  has(md, "## TASKS (1)")

  -- the overview of the area lists it again
  has(H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"), "Came back")

  -- an open task is no change; the last row of a section brings the placeholder back
  eq(one({ { op = "reopen", id = a } }).outcome, "unchanged")
  local e2 = one({ { op = "reopen", id = b, status = "doing" } })
  eq(e2.ok, true, vim.inspect(e2))
  eq(assert(scan.find(b, { root = root })).status, "doing")
  md = H.read(readme)
  has(md, "## TASKS (0)")
  has(md, "_noch leer_")
  lacks(md, "| Datei | Inhalt |")

  -- ── what is refused ────────────────────────────────────────────────────────
  local function refused(op, code, needle)
    local r = one({ op })
    eq({ r.ok, r.error and r.error.code }, { false, code }, vim.inspect(r))
    has(r.error.message, needle)
  end
  refused({ op = "reopen", id = "lib.nvim/never-was" }, "not_found", "no such finished task")
  refused({ op = "reopen" }, "invalid_argument", "needs id")

  -- a name that is taken by a plan: the finished task stays where it is
  local c = finished("Same name")
  H.write(
    require("tasks_nvim.vault").plan_path(root, "lib.nvim", "same-name"),
    F.text({ { "title", "A plan" }, { "status", "planning" } })
  )
  local c_path = backlog_file(c)
  refused({ op = "reopen", id = c }, "exists", "open task or plan of this name")
  eq(fsio.is_file(c_path), true, "nothing was moved")
  -- a status that does not exist is refused before anything moves
  refused({ op = "reopen", id = c, status = "done" }, "invalid_argument", "unknown status")
  eq(fsio.is_file(c_path), true)

  -- an old version of the finished file is a conflict
  local d = finished("Versioned")
  local stale = one({ { op = "reopen", id = d, if_match = "sha256:0000000000000000" } })
  eq(stale.error.code, "conflict", vim.inspect(stale))
  eq(fsio.is_file(backlog_file(d)), true)
  local right = one({ { op = "reopen", id = d, if_match = fsio.etag(H.read(backlog_file(d))) } })
  eq(right.outcome, "changed", vim.inspect(right))

  -- the row leaves the bucket the file was in, whatever its kind says now
  local g = finished("Kind edited later", { kind = "feature" })
  local g_path = backlog_file(g)
  has(g_path, "/Backlog/FEATURES/")
  H.write(g_path, (H.read(g_path):gsub("kind: feature", "kind: bug")))
  has(H.read(readme), "Kind edited later")
  eq(one({ { op = "reopen", id = g } }).outcome, "changed")
  lacks(H.read(readme), "Kind edited later")

  -- a task that is a folder is not moved
  local f = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "A folder", folder = true }))
  )
  assert(mutate.done(f.id, o))
  local folder_file = backlog_file(f.id)
  refused({ op = "reopen", id = f.id }, "invalid_argument", "folder task")
  eq(fsio.is_file(folder_file), true)

  -- the finished file cannot be removed (a lock of an editor or a scanner): the open copy is taken away again
  -- and the answer says nothing changed; when that fails too, the answer says that both files stay
  local real_remove = fsio.remove
  ---@param stub fun(path: string): boolean|nil, string|nil  # takes the place of fsio.remove
  local function reopen_with_remove(id, stub)
    fsio.remove = stub
    local ok, res, err = pcall(mutate.reopen, id, o)
    fsio.remove = real_remove
    assert(ok, res)
    return res, err
  end
  ---@param fails fun(path: string): boolean  # which paths refuse to be removed
  local function reopen_with_stuck(id, fails)
    return reopen_with_remove(id, function(path)
      if fails(path) then
        return false, "locked by another process"
      end
      return real_remove(path)
    end)
  end
  local h = finished("Locked finished file")
  local h_done = backlog_file(h)
  local h_open = require("tasks_nvim.vault").task_path(root, "lib.nvim", "locked-finished-file")
  local res, err = reopen_with_stuck(h, function(path)
    return path == h_done
  end)
  eq(res, nil)
  has(err, "nothing was changed")
  has(err, "locked by another process")
  eq(
    { fsio.is_file(h_done), fsio.is_file(h_open) },
    { true, false },
    "the open copy was taken away"
  )

  local res2, err2 = reopen_with_stuck(h, function()
    return true
  end)
  eq(res2, nil)
  lacks(err2, "nothing was changed")
  has(err2, "both stay")
  has(err2, h_open)
  eq({ fsio.is_file(h_done), fsio.is_file(h_open) }, { true, true }, "the state the answer names")
  -- (the vault is put right by hand: the real remove works again)
  assert(real_remove(h_open))
  eq(
    one({ { op = "reopen", id = h } }).outcome,
    "changed",
    "a later reopen works once the lock is gone"
  )

  -- a removal that raises, and one that says no reason: the same rollback, the reason is told as it is
  local vault_mod = require("tasks_nvim.vault")
  local i = finished("Remove raises")
  local i_done, i_open = backlog_file(i), vault_mod.task_path(root, "lib.nvim", "remove-raises")
  local _, raised = reopen_with_remove(i, function(path)
    if path == i_done then
      error("boom")
    end
    return real_remove(path)
  end)
  has(raised, "nothing was changed")
  has(raised, "boom")
  eq({ fsio.is_file(i_done), fsio.is_file(i_open) }, { true, false })
  has(H.read(readme), "Remove raises")

  local _, silent = reopen_with_remove(i, function(path)
    if path == i_done then
      return false
    end
    return real_remove(path)
  end)
  has(silent, "unknown reason")
  eq({ fsio.is_file(i_done), fsio.is_file(i_open) }, { true, false })

  -- the finished file was taken away by someone else meanwhile: that is what was wanted, the open copy stays
  local gone = finished("Gone meanwhile")
  local gone_done = backlog_file(gone)
  local gone_open = vault_mod.task_path(root, "lib.nvim", "gone-meanwhile")
  local took, took_err = reopen_with_remove(gone, function(path)
    if path == gone_done then
      assert(real_remove(path))
      return false, "ENOENT: no such file"
    end
    return real_remove(path)
  end)
  eq(took_err, nil)
  eq(took.changed, true, vim.inspect(took))
  eq({ fsio.is_file(gone_done), fsio.is_file(gone_open) }, { false, true })
  lacks(H.read(readme), "Gone meanwhile")
end
