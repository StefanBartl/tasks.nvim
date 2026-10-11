-- TESTS/tasks_write_path_spec.lua -- the write path is safe for more than one writer: `set` with `if_match` / `expect`
-- is a compare-and-set under the lock, a conflict says what it found, other keys survive, a link is not written through,
-- and a lock that is busy is told from one that is stuck.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local batch = require("tasks_nvim.batch")
  local scan = require("tasks_nvim.scan")
  local fm = require("lib.nvim.markdown.frontmatter")
  local uv = vim.uv or vim.loop
  local _

  local root = F.vault(H)
  local opts = { root = root, today = F.TODAY, index = false }
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "prio", "2" } }))

  ---@return Tasks.Task
  local function alpha()
    return assert(scan.find("lib.nvim/alpha", { root = root }))
  end

  ---@param extra? table
  ---@return table
  local function with(extra)
    return vim.tbl_extend("force", opts, extra or {})
  end

  --- Run `fn` once, right before the next lock is taken: another writer slipping in between a caller's pre-check and
  --- the write.
  ---@param fn fun()
  local function once_before_lock(fn)
    local real = fsio.with_lock
    fsio.with_lock = function(path, run, o)
      fsio.with_lock = real
      fn()
      return real(path, run, o)
    end
  end

  -- ── the version tag a caller holds ─────────────────────────────────────────
  local t0 = alpha()
  ok(t0.etag and t0.etag:match("^sha256:%x+$"), "a scanned task carries its etag")

  -- ── if_match: the version is checked, the answer carries the new one ─────────
  local res, err, info =
    mutate.set("lib.nvim/alpha", { status = "doing" }, with({ if_match = t0.etag }))
  ok(res, "a matching if_match writes: " .. tostring(err))
  eq(info, nil)
  eq(res.changed, true)
  eq(res.etag_before, t0.etag)
  ok(res.etag_after and res.etag_after ~= t0.etag, "the new version differs")
  eq(alpha().etag, res.etag_after, "and is the tag of the file that is on disk now")
  eq(alpha().status, "doing")
  eq(res.before, { status = "open" }, "the old values of the patched keys come back, for an undo")

  -- the old tag is stale now
  res, err, info =
    mutate.set("lib.nvim/alpha", { status = "blocked" }, with({ if_match = t0.etag }))
  eq(res, nil)
  eq(info.code, "conflict")
  eq(info.id, "lib.nvim/alpha")
  eq(info.expected, t0.etag)
  eq(info.actual, alpha().etag, "the conflict names the version it found")
  eq(info.key, nil, "an if_match conflict is about the whole file")
  has(err, "changed since it was read")
  eq(alpha().status, "doing", "nothing was written")

  -- a patch that would change nothing is still a conflict for a caller that looks at old data
  res, _, info = mutate.set("lib.nvim/alpha", { status = "doing" }, with({ if_match = t0.etag }))
  eq(res, nil)
  eq(info.code, "conflict")

  -- without if_match the call is what it always was
  res = assert(mutate.set("lib.nvim/alpha", { status = "doing" }, opts))
  eq(res.changed, false)
  eq(res.etag_after, res.etag_before, "no change, same version")

  -- ── inside the lock: another writer slips in between the pre-check and the write ──
  local path = alpha().path
  local before = alpha()
  once_before_lock(function()
    assert(fm.update(path, { { "prio", "3" } }))
  end)
  res, _, info =
    mutate.set("lib.nvim/alpha", { status = "blocked" }, with({ if_match = before.etag }))
  eq(res, nil, "a change that arrives after the pre-check is caught under the lock")
  eq(info.code, "conflict")
  eq(info.expected, before.etag)
  eq(alpha().status, "doing", "and the write did not happen")
  eq(alpha().prio, 3, "the other writer's change stands")

  -- `expect` is one key: a change of ANOTHER key does not conflict, and is kept
  local base = alpha()
  once_before_lock(function()
    assert(fm.update(path, { { "prio", "1" } }))
  end)
  res, err = mutate.set(
    "lib.nvim/alpha",
    { status = "open" },
    with({ expect = { key = "status", value = "doing" } })
  )
  ok(res, "another key changed meanwhile, the expected one did not: " .. tostring(err))
  eq(alpha().status, "open")
  eq(alpha().prio, 1, "the other key is not undone")
  ok(
    res.etag_before ~= base.etag,
    "the tag in the answer is of the text under the lock, not the one read before"
  )

  -- `expect` on the key that did change: the conflict names key, expected and actual
  once_before_lock(function()
    assert(fm.update(path, { { "status", "parked" } }))
  end)
  res, err, info = mutate.set(
    "lib.nvim/alpha",
    { status = "doing" },
    with({ expect = { key = "status", value = "open" } })
  )
  eq(res, nil)
  eq(info, {
    code = "conflict",
    id = "lib.nvim/alpha",
    key = "status",
    expected = "open",
    actual = "parked",
  })
  has(err, "changed since the list was read")
  eq(alpha().status, "parked")

  -- ── batch.set_many hands the code on ──────────────────────────────────────────
  local out = batch.set_many({
    {
      id = "lib.nvim/alpha",
      patch = { status = "doing" },
      expect = { key = "status", value = "open" },
    },
  }, { root = root, today = F.TODAY, index = false })
  eq(#out.failed, 1)
  eq(out.failed[1].code, "conflict")
  has(out.failed[1].err, "changed since the list was read")
  eq(#out.changed, 0)

  -- ── the inverse patch puts every settable key back ───────────────────────────
  F.task(
    H,
    root,
    "lib.nvim",
    "round-trip",
    F.meta("Round trip", "open", {
      { "prio", "2" },
      { "tags", "[a, b]" },
      { "effort", "S" },
      { "value", "3" },
      { "summary", "a summary" },
      { "order", "2.5" },
    })
  )
  local rt = scan.find("lib.nvim/round-trip", { root = root })
  local forward = {
    status = "doing",
    prio = 1,
    tags = { "x" },
    effort = "L",
    value = 5,
    summary = "changed",
    order = 4,
    actor = "cdx", -- not in the file before: the inverse removes it
  }
  res = assert(mutate.set(rt.id, forward, with({ if_match = rt.etag })))
  eq(res.before.actor, mutate.REMOVE, "a key the file did not have comes back as REMOVE")
  local undone = assert(mutate.set(rt.id, res.before, with({ if_match = res.etag_after })))
  eq(undone.changed, true)
  local back = scan.find(rt.id, { root = root })
  eq(back.status, "open")
  eq(back.prio, 2)
  eq(back.tags, { "a", "b" })
  eq(back.effort, "S")
  eq(back.value, 3)
  eq(back.summary, "a summary")
  eq(back.order, 2.5)
  eq(back.actor, nil)

  -- ── a link is not written through ────────────────────────────────────────────
  do
    local outside = H.tmpdir() .. "/outside"
    local target = outside .. "/secret.md"
    local text = F.text(F.meta("From outside", "open"))
    H.write(target, text)
    local linked = root .. "/lib.nvim/ROADMAP/tasks/linked.md"
    if uv.fs_symlink(target, linked, {}) then
      res, err, info = mutate.set("lib.nvim/linked", { status = "doing" }, opts)
      eq(res, nil)
      eq(info.code, "forbidden")
      has(err, "symbolic link")
      lacks(err, root, "the message has no path of this machine")
      eq(H.read(target), text, "the file outside the vault is untouched")
      uv.fs_unlink(linked)
    else
      print("tasks_write_path_spec: file symlinks are not allowed here; the link case is skipped")
    end
  end

  -- ── the lock: busy is told from stuck ────────────────────────────────────────
  do
    local dir = H.tmpdir()
    local target = dir .. "/doc.md"
    H.write(target, "x")
    local lock = dir .. "/.doc.md.lock"

    -- what the function answers is handed back, up to three values
    local a, b, c = fsio.with_lock(target, function()
      return "one", "two", { three = true }
    end)
    eq({ a, b, c }, { "one", "two", { three = true } })

    -- a folder where the lock file should be (a checked-in `.doc.md.lock/`) is stuck at once, without waiting
    vim.fn.mkdir(lock, "p")
    local started = uv.hrtime()
    local none, msg, linfo = fsio.with_lock(target, function()
      return "never"
    end, { wait_ms = 5000 })
    eq(none, nil)
    eq(linfo.code, "lock_stuck")
    eq(linfo.retryable, false)
    has(msg, "remove it by hand")
    ok((uv.hrtime() - started) / 1e9 < 1, "no waiting for a lock nobody can release")
    vim.fn.delete(lock, "d")
  end
end
