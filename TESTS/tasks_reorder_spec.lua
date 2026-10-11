-- TESTS/tasks_reorder_spec.lua -- batch.reorder: a task moves inside its group by getting an `order` between its
-- neighbours'; tasks without an `order` get one only where the spot needs it; a crowd of halvings is renumbered.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local batch = require("tasks_nvim.batch")
  local plan = require("tasks_nvim.plan")
  local plan_scope = require("tasks_nvim.plan_scope")
  local scan = require("tasks_nvim.scan")
  local fm = require("lib.nvim.markdown.frontmatter")
  local fsio = require("tasks_nvim.fsio")

  -- ── the placement, pure ──────────────────────────────────────────────────────
  ---@param orders (number|false)[]  # false: no order
  ---@return Tasks.Task[]
  local function group_of(orders)
    local seq = {}
    for i, o in ipairs(orders) do
      seq[i] = { id = "a/t" .. i, order = o or nil }
    end
    return seq
  end
  local X = { id = "a/x" }

  ---@param orders (number|false)[]
  ---@param pos integer
  ---@return table writes
  ---@return boolean renumbered
  local function place(orders, pos)
    local writes, renumbered = batch.plan_reorder(group_of(orders), X, pos)
    local flat = {}
    for _, w in ipairs(writes) do
      flat[#flat + 1] = w.id .. "=" .. tostring(w.order)
    end
    return flat, renumbered
  end

  eq((place({ 1, 2, 3 }, 0)), { "a/x=0" }, "in front of numbered tasks: one below the first")
  eq((place({ 1, 2, 3 }, 3)), { "a/x=4" }, "behind numbered tasks: one above the last")
  eq((place({ 1, 2, 3 }, 1)), { "a/x=1.5" }, "between two numbers: the middle")
  eq(
    (place({ 1, 2, false, false }, 2)),
    { "a/x=3" },
    "behind the numbered, in front of the rest: no neighbour is touched"
  )
  eq(
    (place({ false, false, false }, 0)),
    { "a/x=1" },
    "in front of tasks that have no order: they stay as they are"
  )
  eq(
    (place({ false, false, false, false }, 2)),
    { "a/t1=1", "a/t2=2", "a/x=3" },
    "among tasks that have no order: the ones before the spot get the next numbers"
  )
  eq(
    (place({ 5, false, false, false }, 3)),
    { "a/t2=6", "a/t3=7", "a/x=8" },
    "the numbering goes on from the last number there is"
  )
  eq(
    (place({ false, false }, 2)),
    { "a/t1=1", "a/t2=2", "a/x=3" },
    "at the end behind tasks without order: all of them are numbered"
  )
  eq((place({}, 0)), { "a/x=1" }, "alone in the group")

  local close, renumbered = place({ 1, 1 + 1e-7, 3, false }, 1)
  eq(renumbered, true, "two values closer than the gap are not split again")
  eq(
    close,
    { "a/t2=3", "a/t3=4", "a/x=2" },
    "the numbered tasks are renumbered 1, 2, 3, ..., the unnumbered stay"
  )
  local same, same_r = place({ 2, 2 }, 1)
  eq(same_r, true, "equal values cannot be split either")
  eq(same, { "a/t1=1", "a/t2=3", "a/x=2" }, "equal values cannot be split: all are numbered afresh")

  -- ── on a vault ───────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, index = false }
  ---@param slug string
  ---@param extra? table[]
  local function add(slug, extra)
    F.task(H, root, "lib.nvim", slug, F.meta(slug, "open", extra or { { "prio", "2" } }))
  end
  for _, slug in ipairs({ "a", "b", "c", "d" }) do
    add(slug)
  end
  add("other-prio", { { "prio", "1" } })
  F.task(H, root, "lib.nvim", "other-status", F.meta("other-status", "doing", { { "prio", "2" } }))

  --- The open `open|2` tasks of lib.nvim in plan order, slugs only.
  ---@return string[]
  local function sequence()
    local shared = assert(plan_scope.shared(root))
    local built = plan.build(shared.open, shared.index)
    local out = {}
    for _, id in ipairs(built.ids) do
      if plan.group_key(built.nodes[id]) == "open|2" and id:match("^lib%.nvim/") then
        out[#out + 1] = id:match("/(.+)$")
      end
    end
    return out
  end

  ---@param slug string
  ---@return number|nil
  local function order_of(slug)
    return scan.find("lib.nvim/" .. slug, { root = root }).order
  end

  eq(sequence(), { "a", "b", "c", "d" }, "tasks without order: the plan's own order (id)")

  -- d to the front: the others are left alone
  local res = assert(batch.reorder("lib.nvim/d", {}, o))
  eq(res.changed, true)
  eq(res.group, "open|2")
  eq(res.changed_ids, { "lib.nvim/d" })
  eq(sequence(), { "d", "a", "b", "c" })
  eq(order_of("d"), 1)
  eq(order_of("a"), nil, "the others have no order")
  ok(
    res.etag_after and res.etag_after ~= res.etag_before,
    "the answer carries both versions of the moved task"
  )

  -- c right behind d, in front of a
  res = assert(batch.reorder("lib.nvim/c", { after = "lib.nvim/d", before = "lib.nvim/a" }, o))
  eq(sequence(), { "d", "c", "a", "b" })
  eq(order_of("c"), 2)
  eq(
    res.inverse,
    { after = "lib.nvim/b" },
    "the inverse puts it back: behind the task it was behind (it was last)"
  )

  -- b right behind a, among the unnumbered: a gets a number as well
  res = assert(batch.reorder("lib.nvim/b", { after = "lib.nvim/a" }, o))
  eq(sequence(), { "d", "c", "a", "b" }, "b was already right behind a: nothing to do")
  eq(res.changed, false)
  eq(res.writes, {})

  res = assert(batch.reorder("lib.nvim/a", { after = "lib.nvim/b" }, o))
  eq(sequence(), { "d", "c", "b", "a" })
  eq(
    res.changed_ids,
    { "lib.nvim/b", "lib.nvim/a" },
    "the task before the spot got a number first, the moved one last"
  )

  -- the inverse of the last move
  assert(batch.reorder("lib.nvim/a", res.inverse, o))
  eq(sequence(), { "d", "c", "a", "b" }, "the inverse of a move puts the task back")

  -- ── what is refused ─────────────────────────────────────────────────────────
  ---@param id string
  ---@param spec table
  ---@param extra? table
  ---@return { err: string, info: table }
  local function refused(id, spec, extra)
    local r, err, info = batch.reorder(id, spec, vim.tbl_extend("force", o, extra or {}))
    eq(r, nil, "refused: " .. vim.inspect(spec))
    return { err = err, info = info }
  end
  local r1 = refused("lib.nvim/a", { after = "lib.nvim/other-prio" })
  eq(r1.info.code, "conflict")
  eq(r1.info.key, "after")
  has(r1.err, "not in the group")
  eq(refused("lib.nvim/a", { before = "lib.nvim/other-status" }).info.key, "before")
  has(refused("lib.nvim/a", { after = "lib.nvim/no-such" }).err, "no open task")
  eq(
    refused("lib.nvim/a", { after = "lib.nvim/d", before = "lib.nvim/b" }).info.key,
    "neighbours",
    "d and b are not next to each other"
  )
  local r2 = refused("lib.nvim/a", { group = "doing|2" })
  eq(r2.info.code, "conflict")
  eq(r2.info.key, "group")
  eq(r2.info.actual, "open|2")
  eq(refused("lib.nvim/a", { after = "lib.nvim/a" }).info.code, "invalid_argument")
  eq(refused("lib.nvim/ghost", {}).info.code, "not_found")
  local r3 = refused("lib.nvim/a", { if_match = "sha256:0000000000000000" })
  eq(r3.info.code, "conflict")
  eq(r3.info.actual, scan.find("lib.nvim/a", { root = root }).etag)
  eq(sequence(), { "d", "c", "a", "b" }, "nothing of this was written")

  -- ── a dry run writes nothing and says what it would do ──────────────────────
  local before_text = H.read(scan.find("lib.nvim/b", { root = root }).path)
  res = assert(
    batch.reorder(
      "lib.nvim/b",
      { before = "lib.nvim/c" },
      vim.tbl_extend("force", o, { dry_run = true })
    )
  )
  eq(res.changed, true)
  ok(#res.writes >= 1)
  eq(res.changed_ids, {}, "nothing was written")
  eq(H.read(scan.find("lib.nvim/b", { root = root }).path), before_text)
  eq(sequence(), { "d", "c", "a", "b" })

  -- ── a move that would write too many files is refused ───────────────────────
  do
    local root3 = F.vault(H)
    local o3 = { root = root3, today = F.TODAY, index = false }
    for _, slug in ipairs({ "p1", "p2", "p3", "p4" }) do
      F.task(H, root3, "lib.nvim", slug, F.meta(slug, "open", { { "prio", "2" } }))
    end
    -- to the end of a group of tasks without an order: every one of them has to be numbered first (4 writes)
    local r, err, info = batch.reorder(
      "lib.nvim/p1",
      { after = "lib.nvim/p4" },
      vim.tbl_extend("force", o3, { max_writes = 3 })
    )
    eq(r, nil)
    eq(info.code, "invalid_argument")
    eq(info.writes, 4)
    has(err, "at most 3")
    eq(scan.find("lib.nvim/p2", { root = root3 }).order, nil, "and nothing was written")
    local done = assert(batch.reorder("lib.nvim/p1", { after = "lib.nvim/p4" }, o3))
    eq(#done.writes, 4)
    eq(scan.find("lib.nvim/p4", { root = root3 }).order, 3)
    eq(scan.find("lib.nvim/p1", { root = root3 }).order, 4)
  end

  -- ── another writer orders a neighbour between planning and writing ──────────
  do
    local root4 = F.vault(H)
    local o4 = { root = root4, today = F.TODAY, index = false }
    for _, slug in ipairs({ "t1", "t2", "t3", "t4" }) do
      F.task(H, root4, "lib.nvim", slug, F.meta(slug, "open", { { "prio", "2" } }))
    end
    local t2_path = scan.find("lib.nvim/t2", { root = root4 }).path
    local real = fsio.with_lock
    fsio.with_lock = function(path, run, lock_opts)
      if path == t2_path then
        fsio.with_lock = real
        assert(fm.update(path, { { "order", "42" } }))
      end
      return real(path, run, lock_opts)
    end
    -- t4 goes behind t2: t1 and t2 get numbers first (t1=1, t2=2), then t4=3; t2 changes under our hands
    local r, err, info = batch.reorder("lib.nvim/t4", { after = "lib.nvim/t2" }, o4)
    fsio.with_lock = real
    eq(r, nil, "a neighbour another writer ordered meanwhile is not overwritten")
    eq(info.code, "conflict")
    eq(info.key, "order")
    eq(info.id, "lib.nvim/t2")
    eq(info.actual, 42)
    eq(info.written, { "lib.nvim/t1" }, "and the answer says how far it got")
    has(err, "changed since the list was read")
    eq(scan.find("lib.nvim/t2", { root = root4 }).order, 42, "the other writer's value stands")
    eq(scan.find("lib.nvim/t1", { root = root4 }).order, 1, "what was written before stays")
    eq(scan.find("lib.nvim/t4", { root = root4 }).order, nil, "the moved task was not touched")
  end

  -- ── thirty halvings: the group is renumbered, the order stays right ─────────
  local root2 = F.vault(H)
  local o2 = { root = root2, today = F.TODAY, index = false }
  local slugs = { "lead", "tail" }
  for i = 1, 33 do
    slugs[#slugs + 1] = ("x%02d"):format(i)
  end
  for _, slug in ipairs(slugs) do
    F.task(H, root2, "lib.nvim", slug, F.meta(slug, "open", { { "prio", "2" } }))
  end
  -- both get a number by moving: tail to the front, lead in front of it
  assert(batch.reorder("lib.nvim/tail", {}, o2))
  assert(batch.reorder("lib.nvim/lead", {}, o2))
  local prev = "lib.nvim/tail"
  local renumbers = 0
  for i = 1, 33 do
    local id = ("lib.nvim/x%02d"):format(i)
    -- always into the same gap: right behind `lead`, in front of the one before
    local r = assert(batch.reorder(id, { after = "lib.nvim/lead", before = prev }, o2))
    renumbers = renumbers + (r.renumbered and 1 or 0)
    prev = id
  end
  ok(renumbers >= 1, "after about twenty halvings the group was renumbered")
  local shared = assert(plan_scope.shared(root2))
  local built = plan.build(shared.open, shared.index)
  local got = {}
  for _, id in ipairs(built.ids) do
    got[#got + 1] = id:match("/(.+)$")
  end
  local want = { "lead" }
  for i = 33, 1, -1 do
    want[#want + 1] = ("x%02d"):format(i)
  end
  want[#want + 1] = "tail"
  eq(got, want, "every task is where the moves put it")
  local seen = {}
  for _, t in ipairs(shared.open) do
    ok(t.order ~= nil, t.id .. " has an order")
    ok(not seen[t.order], "no two tasks share an order (" .. t.id .. ")")
    seen[t.order] = true
  end
end
