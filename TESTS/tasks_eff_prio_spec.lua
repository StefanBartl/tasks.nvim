-- TESTS/tasks_eff_prio_spec.lua -- the priority a task is grouped by: `readiness.eff_prio` is always the part after the
-- bar of `group`, also where it is not the task's own (a task that a better task waits on), so a client never has to
-- take the key apart.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq = H.eq
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local contract = require("tasks_nvim.contract")
  local mutate = require("tasks_nvim.mutate")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }

  ---@param title string
  ---@param extra? table
  ---@return string id
  local function make(title, extra)
    return assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {}))
    ).id
  end

  -- `low` has the priority 3 and the task `urgent` (priority 1) waits on it: `low` is grouped by 1
  local low = make("Low but needed", { prio = 3 })
  local urgent = make("Urgent", { prio = 1 })
  assert(mutate.set(urgent, { blocked_by = { low } }, o))
  local plain = make("Plain", { prio = 2 })
  local none = make("No priority")
  -- two tasks that wait on each other, each with its own priority, one that waits on them, and a parked one
  local cyc_a = make("Cycle a", { prio = 2 })
  local cyc_b = make("Cycle b", { prio = 3 })
  assert(mutate.set(cyc_a, { blocked_by = { cyc_b } }, o))
  assert(mutate.set(cyc_b, { blocked_by = { cyc_a } }, o))
  local behind = make("Behind the cycle", { prio = 1 })
  assert(mutate.set(behind, { blocked_by = { cyc_a } }, o))
  local parked = make("Parked", { prio = 2 })
  assert(mutate.set(parked, { status = "parked" }, o))

  local snap = assert(contract.snapshot({ root = root }))
  ---@type table<string, table>
  local by_id = {}
  for _, t in ipairs(snap.tasks) do
    by_id[t.id] = t
  end

  eq(by_id[low].readiness.eff_prio, 1, "the better priority of the task that waits on it")
  eq(by_id[low].group, "open|1")
  eq(by_id[urgent].readiness.eff_prio, 1)
  eq(by_id[plain].readiness.eff_prio, 2)
  eq(by_id[plain].group, "open|2")
  eq(by_id[none].readiness.eff_prio, nil, "no priority is a missing number, not 0")
  eq(by_id[none].group, "open|-")

  -- a task in a cycle keeps its own priority as the effective one (the group key says the same)
  eq(by_id[cyc_a].readiness.in_cycle, true, "the fixture has a cycle")
  eq(by_id[cyc_a].readiness.eff_prio, 2)
  eq(by_id[cyc_a].group, "open|2")
  eq(by_id[cyc_b].readiness.eff_prio, 3)
  eq(by_id[cyc_b].group, "open|3")
  eq(by_id[behind].readiness.eff_prio, 1)
  eq(by_id[parked].readiness.eff_prio, 2)
  eq(by_id[parked].group, "parked|2")

  -- the rule for every task of the vault
  for id, t in pairs(by_id) do
    local label = t.group:match("|(.*)$")
    eq(label, t.readiness.eff_prio and tostring(t.readiness.eff_prio) or "-", id)
  end
end
