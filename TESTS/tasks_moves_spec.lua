-- TESTS/tasks_moves_spec.lua -- moves.preview: moving a task to another area, stage 1. What would break is reported;
-- nothing is written.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local moves = require("tasks_nvim.moves")
  local plans = require("tasks_nvim.plans")

  local root = F.vault(H)
  local o = { root = root }

  local made = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Ship",
    areas = "lib.nvim",
    target = "lib.nvim/mover",
  }))
  F.task(H, root, "lib.nvim", "mover", F.meta("Mover", "open", { { "plan", made.id } }))
  F.task(
    H,
    root,
    "lib.nvim",
    "waits",
    F.meta("Waits", "open", { { "blocked_by", "lib.nvim/mover" } })
  )
  F.task(H, root, "lib.nvim", "later", F.meta("Later", "open", { { "after", "lib.nvim/mover" } }))
  F.task(
    H,
    root,
    "cascade.nvim",
    "mentions",
    F.meta("Mentions", "open", { { "refs", "[lib.nvim/mover]" } })
  )
  F.task(H, root, "lib.nvim", "unrelated", F.meta("Unrelated", "open"))
  F.task(H, root, "lib.nvim", "taken", F.meta("Taken", "open"))
  F.task(H, root, "cascade.nvim", "taken", F.meta("Taken elsewhere", "open"))
  H.write(
    root .. "/cascade.nvim/Backlog/TASKS/2026-09-01_done-there.md",
    F.text(F.meta("Done there", "done"))
  )
  F.task(H, root, "lib.nvim", "done-there", F.meta("Done there too", "open"))

  local wide = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Wide",
    areas = "lib.nvim,cascade.nvim",
  }))
  F.task(H, root, "lib.nvim", "in-wide", F.meta("In wide", "open", { { "plan", wide.id } }))

  --- Every file of the vault with its bytes.
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
  local before = everything()

  -- ── a move that can be made, and what it would break ─────────────────────────
  local pv = assert(moves.preview("lib.nvim/mover", "cascade.nvim", o))
  eq(pv.id, "lib.nvim/mover")
  eq(pv.new_id, "cascade.nvim/mover")
  eq(pv.to_area, "cascade.nvim")
  ok(pv.to:find("cascade.nvim/ROADMAP/tasks/mover.md", 1, true), pv.to)
  ok(pv.from:find("lib.nvim/ROADMAP/tasks/mover.md", 1, true), pv.from)
  eq(pv.folder, false)
  eq(pv.ok, true)
  eq(pv.conflicts, {})
  eq(pv.references, {
    { kind = "after", id = "lib.nvim/later" },
    { kind = "blocked_by", id = "lib.nvim/waits" },
    { kind = "plan_target", id = made.id },
    { kind = "refs", id = "cascade.nvim/mentions" },
  }, "every place that names the old id, sorted")
  eq(#pv.notes, 1, "the task's plan does not list the new area")
  has(pv.notes[1], "does not list the area cascade.nvim")

  local unrelated = assert(moves.preview("lib.nvim/unrelated", "cascade.nvim", o))
  eq(unrelated.references, {}, "nobody names it")
  eq(unrelated.ok, true)

  -- ── the slug must be free in the target area ────────────────────────────────
  local taken = assert(moves.preview("lib.nvim/taken", "cascade.nvim", o))
  eq(taken.ok, false)
  eq(taken.conflicts[1].code, "slug-taken")
  has(taken.conflicts[1].message, "cascade.nvim/taken is an open task")
  local finished = assert(moves.preview("lib.nvim/done-there", "cascade.nvim", o))
  eq(finished.ok, false)
  has(finished.conflicts[1].message, "finished task")

  -- ── what is refused outright ─────────────────────────────────────────────────
  ---@param id string
  ---@param area any
  ---@return string err
  ---@return table info
  local function refused(id, area)
    local r, err, info = moves.preview(id, area, o)
    eq(r, nil)
    return err, info
  end
  local gone, gone_info = refused("lib.nvim/ghost", "cascade.nvim")
  eq(gone_info.code, "not_found")
  has(gone, "no such open task")
  local unknown, unknown_info = refused("lib.nvim/mover", "no-such.nvim")
  eq(unknown_info.code, "not_found")
  has(unknown, "unknown area")
  local same, same_info = refused("lib.nvim/mover", "lib.nvim")
  eq(same_info.code, "invalid_argument")
  has(same, "already")
  eq(select(2, refused("lib.nvim/mover", "../x")).code, "invalid_argument")
  eq(select(2, refused("lib.nvim/mover", 42)).code, "invalid_argument")

  -- ── a plan that does not list the new area is a note, not a conflict ─────────
  local narrow = assert(moves.preview("lib.nvim/mover", "nvim-config", o))
  eq(narrow.ok, true)
  eq(#narrow.notes, 1)
  has(narrow.notes[1], "does not list the area nvim-config")

  -- a plan that lists both areas has nothing to say
  eq(assert(moves.preview("lib.nvim/in-wide", "cascade.nvim", o)).notes, {})

  eq(everything(), before, "not a byte of the vault changed")
end
