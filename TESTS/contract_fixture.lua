-- TESTS/contract_fixture.lua -- the synthetic vault the contract is tested and its golden files are made from.
-- Never the real vault, never anybody's private area: every name, title and path here is made up. Every date is fixed,
-- so the bytes of every file (and with them every `etag`, `rev` and `digest`) are the same on every machine and run.
--
-- What it holds, on purpose: every readiness state (ready, waiting, stuck, freed, parked, decision, a cycle, a
-- finished blocker), a plan file with phases, a same-file conflict, an absolute `refs:` entry, a hostile title, a
-- non-ASCII title, steps, a broken task, a task that says `done` inside `ROADMAP/`, and a task with a status nobody knows.

local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

local M = {}

local DATE = "2026-01-01"

---@param H table
---@param root string
---@param area string
---@param slug string
---@param extra table[]   # `{ key, rawvalue }` lines after the title and status
---@param status? string
---@param title? string
---@param body? string
local function task(H, root, area, slug, extra, status, title, body)
  local meta = { { "title", title or ("Task " .. slug) }, { "status", status or "open" } }
  for _, kv in ipairs(extra) do
    meta[#meta + 1] = kv
  end
  meta[#meta + 1] = { "created", DATE }
  meta[#meta + 1] = { "updated", DATE }
  F.task(H, root, area, slug, meta, body or "\nA summary line for " .. slug .. ".\n")
end

---Build the vault under a fresh temp dir.
---@param H table
---@return string root  # forward slashes, no trailing slash
function M.build(H)
  local root = F.vault(H)
  vim.fn.mkdir(root .. "/lib.nvim/ROADMAP/tasks", "p")
  vim.fn.mkdir(root .. "/lib.nvim/ROADMAP/plans", "p")
  vim.fn.mkdir(root .. "/cascade.nvim/ROADMAP/tasks", "p")

  -- ready, with steps, tags, an absolute ref, a hostile title and a same-file ref shared with `alpha-twin`
  task(
    H,
    root,
    "lib.nvim",
    "alpha",
    {
      { "kind", "feature" },
      { "prio", "1" },
      { "effort", "S" },
      { "value", "5" },
      { "actor", "cdx" },
      { "tags", "[ui, docs]" },
      {
        "refs",
        "[docs/shared.md, /abs/outside/secret.md, C:/Users/someone/private/notes.md, repo@abc1234]",
      },
    },
    "open",
    'Alpha <script>alert(1)</script> & "quotes" \\ slash',
    "\nThe body of alpha.\n\n## Plan\n\n- [x] 1. first\n- [ ] 2. second\n- [ ] 3. third (dropped)\n"
  )
  task(H, root, "lib.nvim", "alpha-twin", {
    { "prio", "1" },
    { "effort", "XS" },
    { "refs", "[docs/shared.md]" },
  }, "open", "Twin of alpha (same file)")

  -- waits for an open blocker; value without effort, effort without value
  task(H, root, "lib.nvim", "beta", {
    { "prio", "2" },
    { "effort", "2d" },
    { "blocked_by", "[lib.nvim/alpha]" },
  }, "doing", "Beta waits for alpha")
  task(
    H,
    root,
    "lib.nvim",
    "gamma",
    { { "prio", "3" }, { "value", "2" } },
    "decision",
    "Gamma is a decision"
  )

  -- parked, and a task stuck behind it
  task(H, root, "lib.nvim", "delta", { { "prio", "3" } }, "parked", "Delta is parked")
  task(
    H,
    root,
    "lib.nvim",
    "epsilon",
    { { "blocked_by", "[lib.nvim/delta]" } },
    "blocked",
    "Epsilon is stuck behind a parked task"
  )

  -- a cycle over hard edges
  task(H, root, "lib.nvim", "cyc-a", { { "blocked_by", "[lib.nvim/cyc-b]" } }, "open", "Cycle A")
  task(H, root, "lib.nvim", "cyc-b", { { "blocked_by", "[lib.nvim/cyc-a]" } }, "open", "Cycle B")

  -- a fraction of `order`, non-ASCII text
  task(
    H,
    root,
    "lib.nvim",
    "order-a",
    { { "prio", "2" }, { "order", "1.5" }, { "effort", "M" } },
    "open",
    "Größe 日本 \240\159\152\128"
  )

  -- not in the list: a finished task left in ROADMAP, a status nobody knows
  task(H, root, "lib.nvim", "done-here", {}, "done", "Done but still in ROADMAP")
  task(H, root, "lib.nvim", "odd-status", {}, "wip", "A status nobody knows")

  -- broken: values out of range (still in the document, valid = false)
  task(
    H,
    root,
    "lib.nvim",
    "broken",
    { { "prio", "9" }, { "effort", "huge" } },
    "open",
    "Broken task"
  )

  -- a plan with phases; two tasks of it, a task that waits on `alpha` from another area, a finished blocker
  H.write(
    root .. "/lib.nvim/ROADMAP/plans/the-plan.md",
    "---\ntitle: The plan\nstatus: doing\nareas: [lib.nvim, cascade.nvim]\nphase_order: [build, test]\ncreated: "
      .. DATE
      .. "\nupdated: "
      .. DATE
      .. "\n---\n\nA plan of the fixture vault.\n"
  )
  task(H, root, "cascade.nvim", "zeta", {
    { "prio", "2" },
    { "effort", "S" },
    { "value", "4" },
    { "actor", "me" },
    { "plan", "lib.nvim/the-plan" },
    { "phase", "build" },
  }, "open", "Zeta builds")
  task(
    H,
    root,
    "cascade.nvim",
    "eta",
    { { "effort", "S" }, { "plan", "lib.nvim/the-plan" }, { "phase", "test" } },
    "open",
    "Eta tests"
  )
  task(
    H,
    root,
    "cascade.nvim",
    "theta",
    { { "blocked_by", "[lib.nvim/old-done]" } },
    "blocked",
    "Theta was blocked by a finished task"
  )
  task(
    H,
    root,
    "cascade.nvim",
    "iota",
    { { "blocked_by", "[lib.nvim/alpha]" } },
    "open",
    "Iota waits across areas"
  )
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-01-02_old-done.md",
    "---\ntitle: Old and done\nstatus: done\ndone_in: lib.nvim@abc1234\ncreated: "
      .. DATE
      .. "\nupdated: "
      .. DATE
      .. "\n---\n\nFinished long ago.\n"
  )
  return root
end

return M
