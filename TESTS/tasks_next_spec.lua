-- TESTS/tasks_next_spec.lua -- tasks_nvim.next_pick: the best ready task, the reason, the runners-up and the empty answers.

---@diagnostic disable: need-check-nil, undefined-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local model = require("tasks_nvim.model")
  local next_pick = require("tasks_nvim.next_pick")

  ---@param id string
  ---@param o? { status?: string, prio?: string, effort?: string, value?: string, actor?: string, blocked_by?: string[], tags?: string }
  ---@return Tasks.Task
  local function T(id, o)
    o = o or {}
    local area, slug = id:match("^([^/]+)/(.+)$")
    local lines = { "---", "title: " .. slug, "status: " .. (o.status or "open") }
    for _, key in ipairs({ "prio", "effort", "value", "actor", "tags" }) do
      if o[key] then
        lines[#lines + 1] = key .. ": " .. o[key]
      end
    end
    if o.blocked_by then
      lines[#lines + 1] = "blocked_by: [" .. table.concat(o.blocked_by, ", ") .. "]"
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = "text"
    return model.parse_text(
      table.concat(lines, "\n") .. "\n",
      { path = "/v/" .. area .. "/ROADMAP/tasks/" .. slug .. ".md", area = area }
    )
  end

  ---@param list Tasks.Task[]
  ---@return string[]
  local function ids(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = t.id
    end
    return out
  end

  -- ── freed by the finished task wins, even against a better prio elsewhere ──
  local tasks = {
    T("a/follow-up", { prio = "3", blocked_by = { "a/just-done" } }),
    T("a/urgent", { prio = "1" }),
    T("b/elsewhere", { prio = "1" }),
  }
  local pick = next_pick.pick({
    tasks = tasks,
    is_done = { ["a/just-done"] = true },
    done = { id = "a/just-done", area = "a" },
  })
  eq(pick.task.id, "a/follow-up", "the task this one freed comes first")
  eq(pick.reason, "freed")
  eq(pick.freed, { "a/follow-up" })
  eq(ids(pick.alternatives), { "a/urgent", "b/elsewhere" }, "then the same area, then the vault")

  -- a task that still waits on something else is not freed
  local partly = next_pick.pick({
    tasks = { T("a/two-blockers", { blocked_by = { "a/just-done", "a/other" } }), T("a/other") },
    is_done = { ["a/just-done"] = true },
    done = { id = "a/just-done", area = "a" },
  })
  eq(partly.freed, {}, "freed means the LAST open blocker")
  eq(partly.task.id, "a/other")

  -- a freed task still written `blocked` is named, but it is not a candidate
  local stale = next_pick.pick({
    tasks = {
      T("a/was-blocked", { status = "blocked", blocked_by = { "a/just-done" } }),
      T("a/plain"),
    },
    is_done = { ["a/just-done"] = true },
    done = { id = "a/just-done", area = "a" },
  })
  eq(stale.freed, { "a/was-blocked" })
  eq(stale.freed_blocked, { "a/was-blocked" }, "offered to be set to open")
  eq(stale.task.id, "a/plain", "a status that says blocked is not ready")

  -- ── area before vault, then status, prio, roi, effort ──
  local ranked = next_pick.pick({
    tasks = {
      T("b/best-elsewhere", { prio = "1", status = "doing" }),
      T("a/decision", { status = "decision", prio = "1" }),
      T("a/open-p2", { prio = "2" }),
      T("a/doing-p3", { status = "doing", prio = "3" }),
    },
    done = { id = "a/x", area = "a" },
  })
  eq(ranked.task.id, "a/doing-p3", "doing before open before decision, inside the area")
  eq(ranked.reason, "area")
  eq(ids(ranked.alternatives), { "a/open-p2", "a/decision" })
  eq(ranked.ready, { area = 3, vault = 4 })
  eq(ranked.open, { area = 3, vault = 4 })

  local by_roi = next_pick.pick({
    tasks = {
      T("a/low-roi", { prio = "2", effort = "L", value = "2" }),
      T("a/high-roi", { prio = "2", effort = "S", value = "4" }),
      T("a/no-roi", { prio = "2" }),
      T("a/small", { prio = "2", effort = "XS" }),
    },
    n = 3,
  })
  eq(by_roi.task.id, "a/high-roi", "same prio: the best return on effort")
  eq(
    ids(by_roi.alternatives),
    { "a/low-roi", "a/small", "a/no-roi" },
    "figures first, then smaller effort, then none"
  )

  -- the effective prio: a prio 3 task blocking a prio 1 task ranks as prio 1
  local inversion = next_pick.pick({
    tasks = {
      T("a/base", { prio = "3" }),
      T("a/top", { prio = "1", blocked_by = { "a/base" } }),
      T("a/mid", { prio = "2" }),
    },
  })
  eq(inversion.task.id, "a/base")

  -- ── who it is for ──
  local mixed = {
    T("a/ai-1", { actor = "cdx", prio = "1" }),
    T("a/ai-2", { actor = "cdx", prio = "2" }),
    T("a/mine", { actor = "me", prio = "3" }),
    T("a/pair", { actor = "pair", prio = "3", effort = "S" }),
    T("a/who-knows", { prio = "3", effort = "L" }),
    T("a/decide", { status = "decision", prio = "2" }),
  }
  local human = next_pick.pick({ tasks = mixed, n = 5 })
  local offered = { human.task }
  vim.list_extend(offered, human.alternatives)
  ok(not vim.tbl_contains(ids(offered), "a/ai-1"), "cdx is not 'your next task'")
  eq(
    human.task.id,
    "a/pair",
    "status comes before prio: the open tasks first, a decision after them, whatever its prio"
  )
  eq(ids(human.cdx), { "a/ai-1", "a/ai-2" }, "the AI tasks are listed apart")
  local queue = next_pick.pick({ tasks = mixed, actor = "cdx" })
  eq(queue.task.id, "a/ai-1", "--actor=cdx asks for the AI queue")
  eq(ids(queue.alternatives), { "a/ai-2" })
  eq(queue.cdx, {}, "no separate list when that queue is the answer")
  local mine = next_pick.pick({ tasks = mixed, actor = "me" })
  eq(mine.task.id, "a/mine", "me: the written one first (open before decision) ...")
  eq(ids(mine.alternatives), { "a/decide" }, "... and the derived decision after it")
  eq(
    next_pick.pick({ tasks = mixed, actor = "none" }).task.id,
    "a/who-knows",
    "none: nobody classified it"
  )

  -- ── the empty answers ──
  local all_done = next_pick.pick({ tasks = {}, done = { id = "a/x", area = "a" } })
  eq(all_done.task, nil)
  eq(all_done.empty.kind, "all_done", "only when nothing is open at all")
  eq(all_done.empty.area_empty, true)

  local waiting = next_pick.pick({
    tasks = {
      T("a/blocked-1", { status = "blocked", blocked_by = { "a/blocked-2" } }),
      T("a/blocked-2", { status = "blocked", blocked_by = { "a/blocked-1" } }),
      T("a/shelf", { status = "parked" }),
      T("a/old-status", { status = "blocked" }),
      T("a/yours", { status = "blocked", actor = "me", blocked_by = { "a/shelf" } }),
    },
    done = { id = "a/x", area = "a" },
  })
  eq(waiting.task, nil)
  eq(waiting.empty.kind, "nothing_startable", "never 'all done' when only waiting work is left")
  eq(waiting.empty.waiting, 3, "two in a cycle and one behind a parked task")
  eq(waiting.empty.parked, 1)
  eq(waiting.empty.blocked_status, 1)
  eq(waiting.empty.for_me, 1)
  eq(waiting.empty.area_empty, false)

  local only_ai =
    next_pick.pick({ tasks = { T("a/ai", { actor = "cdx" }) }, done = { id = "a/x", area = "a" } })
  eq(only_ai.task, nil)
  eq(only_ai.empty.kind, "only_cdx", "everything startable is for an AI session")
  eq(ids(only_ai.cdx), { "a/ai" })

  local elsewhere = next_pick.pick({ tasks = { T("b/other") }, done = { id = "a/x", area = "a" } })
  eq(elsewhere.task.id, "b/other")
  eq(elsewhere.reason, "vault")
  eq(elsewhere.open.area, 0, "the area itself is empty ...")
  eq(elsewhere.ready.vault, 1, "... and the vault still has work")

  -- no finished task at all: a plain "what now?"
  local plain = next_pick.pick({ tasks = { T("a/x", { prio = "2" }), T("b/y", { prio = "1" }) } })
  eq(plain.task.id, "b/y")
  eq(plain.reason, "vault")
  eq(plain.freed, {})
end
