-- TESTS/tasks_review2_spec.lua -- the second review round (the commits of waves 0-3 read for bugs, security and
-- performance): each fix has its case here. The marker blocks have their own spec (`tasks_marker_blocks_spec`), the
-- plan close and the id namespace are in `tasks_plans_spec`, the SEC-32 patterns in `tasks_review_fixes_spec`.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line; specs replace
-- module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local batch = require("tasks_nvim.batch")
  local cli = require("tasks_nvim.cli")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local plan_view = require("tasks_nvim.plan_view")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local function run(argv)
    local out, err = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. F.TODAY }), {
        out = function(x)
          out[#out + 1] = x
        end,
        err = function(x)
          err[#err + 1] = x
        end,
      })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  -- ── a typed count is not a loop: `999999999p` is one cycle ──
  do
    local tasks = {}
    for _, status in ipairs({ "open", "doing", "blocked", "parked", "decision", "done", "weird" }) do
      tasks[#tasks + 1] = { id = "a/" .. status, status = status }
    end
    tasks[#tasks + 1] = { id = "a/none" }
    local function naive(cur, step, presses)
      for _ = 1, presses do
        cur = step(cur)
      end
      return cur
    end
    for presses = 1, 14 do
      for _, step in ipairs(batch.plan_cycle(tasks, "status", presses)) do
        local from = step.from
        eq(
          step.to,
          naive(from, model.cycle_status, presses),
          ("status %s x%d"):format(tostring(from), presses)
        )
      end
    end
    local prios = {}
    for _, prio in ipairs({ 1, 2, 3, 9 }) do
      prios[#prios + 1] = { id = "a/p" .. prio, prio = prio }
    end
    prios[#prios + 1] = { id = "a/pnone" }
    for presses = 1, 14 do
      for _, step in ipairs(batch.plan_cycle(prios, "prio", presses)) do
        eq(
          step.to,
          naive(step.from, model.cycle_prio, presses),
          ("prio %s x%d"):format(tostring(step.from), presses)
        )
      end
    end
    local t0 = vim.uv.hrtime()
    local huge = batch.plan_cycle(tasks, "status", 999999999)
    ok((vim.uv.hrtime() - t0) / 1e9 < 0.2, "a huge count costs one cycle, not a billion steps")
    eq(#huge, #tasks)
    for _, step in ipairs(huge) do
      eq(
        step.to,
        naive(step.from, model.cycle_status, 1 + ((999999999 - 1) % #model.OPEN_STATUSES))
      )
    end
  end

  -- ── migrate-actor names an area that does not exist ──
  do
    local typo = run({ "migrate-actor", "lib.nv1m" })
    eq(typo.code, 2)
    has(typo.err, "unknown area")
    eq(run({ "migrate-actor", "lib.nvim" }).code, 0, "a real area still works")
  end

  -- ── done --unblock: the advice is worked out after the freed tasks are open ──
  do
    local x =
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Blocker", status = "doing" }))
    F.task(
      H,
      root,
      "lib.nvim",
      "waiter",
      F.meta("Waiter", "blocked", { { "blocked_by", "[lib.nvim/blocker]" } })
    )
    F.task(H, root, "lib.nvim", "decider", F.meta("Decider", "decision"))
    local res = run({ "done", x.id, "--unblock" })
    eq(res.code, 0, res.err)
    has(res.out, "unblocked\tlib.nvim/waiter")
    local first_next = res.out:match("next: ([^\t\n]+)")
    eq(first_next, "lib.nvim/waiter", "the task that was just unblocked leads the advice")
    lacks(res.out, "next: lib.nvim/decider", "and the decision does not")
  end

  -- ── the headless CLI refreshes the documents named in $TASKS_MARKER_DOCS ──
  do
    local doc = H.tmpdir() .. "/ENV-HANDOVER.md"
    local s, f = plan_view.block_markers("lib.nvim")
    H.write(doc, "# Doc\n\n" .. s .. "\nSTALE\n" .. f .. "\n")
    local member = mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Env member" }))
    vim.env.TASKS_MARKER_DOCS = doc
    local res = run({ "done", member.id })
    vim.env.TASKS_MARKER_DOCS = nil
    eq(res.code, 0, res.err)
    has(res.out, "refreshed\t")
    lacks(H.read(doc), "STALE")
    local docs = require("tasks_nvim.done_flow").marker_docs()
    eq(#docs, 0, "unset again: no document")
  end

  -- ── a task of a status nobody knows is not "everything is done" ──
  do
    local lonely = F.vault(H)
    F.task(H, lonely, "lib.nvim", "typo", F.meta("Typo", "in progress"))
    F.task(H, lonely, "lib.nvim", "notes", { { "title", "just notes" } })
    local out, err = {}, {}
    cli.run({ "next", "--vault=" .. lonely, "--today=" .. F.TODAY }, {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    local printed = table.concat(out)
    has(printed, "empty:")
    lacks(printed, "Everything is done")
    has(printed, "1 with a status nobody knows")
    -- a vault with nothing at all still says it
    local empty_root = F.vault(H)
    local out2 = {}
    cli.run({ "next", "--vault=" .. empty_root, "--today=" .. F.TODAY }, {
      out = function(x)
        out2[#out2 + 1] = x
      end,
      err = function() end,
    })
    has(table.concat(out2), "Everything is done")
  end

  -- ── ids are file names: a TAB or LF in one does not start a record of its own ──
  do
    local lines = plan_view.next_lines({
      task = { id = "a/b\tc\nd", title = "t" },
      reason = "vault",
      alternatives = { { id = "a/e\tf", title = "u" } },
      cdx = { { id = "a/i\tj", title = "v" } },
      freed = { "a/g\nh", "a/k" },
    })
    eq(#lines, 4, "next, then, freed and cdx: one line each")
    for _, line in ipairs(lines) do
      lacks(line, "\n")
    end
    eq(select(2, lines[1]:gsub("\t", "")), 2, "the next line has its two separators and no more")
    eq(select(2, lines[2]:gsub("\t", "")), 1)
    eq(select(2, lines[4]:gsub("\t", "")), 1)
  end
end
