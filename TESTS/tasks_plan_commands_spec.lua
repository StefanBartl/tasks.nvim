-- TESTS/tasks_plan_commands_spec.lua -- `:Tasks plan|next|estimate`, `list --ready|--waiting|--unestimated`, the dialog
-- after `done` and the dashboard's one answer for a stack of finished tasks, through the real command grammar.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local routes = require("tasks_nvim.ui.routes")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")
  local popup = require("tasks_nvim.ui.next_popup")

  local root = F.vault(H)
  vault.set_root(root)
  routes.register_types()
  composer.verb("TaskP", { routes = routes.routes({ flat = true }) })
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }

  local orig_notify, orig_yesno = vim.notify, confirm.yesno
  ---@type { msg: string, level: integer }[]
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end
  local function restore()
    vim.notify = orig_notify
    confirm.yesno = orig_yesno
    popup.chooser = nil
    cmd.chooser = nil
    vault.set_root(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end
  local function said()
    local out = {}
    for _, n in ipairs(notes) do
      out[#out + 1] = n.msg
    end
    return table.concat(out, "\n")
  end
  ---@param line string
  local function run(line)
    notes = {}
    vim.cmd("TaskP " .. line)
    vim.wait(30, function()
      return false
    end)
  end

  local good, failure = pcall(function()
    local base = assert(
      mutate.new(
        "lib.nvim",
        vim.tbl_extend("force", o, { title = "Cmd base", effort = "S", value = 4 })
      )
    )
    local mid = assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Cmd mid", effort = "M" }))
    )
    local stale =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Cmd stale" })))
    assert(mutate.set(mid.id, { blocked_by = "[" .. base.id .. "]" }, o))
    assert(mutate.set(stale.id, { status = "blocked", blocked_by = "[" .. base.id .. "]" }, o))

    -- ── plan: into a file, the guard, the formats ──
    local out_dir = H.tmpdir() .. "/out"
    vim.fn.mkdir(out_dir, "p")
    local plan_file = out_dir .. "/plan.md"
    run("plan lib.nvim --to=file:" .. plan_file)
    local text = assert(H.read(plan_file), said())
    has(text, "# Plan: lib.nvim")
    has(text, "## Ready now")
    has(text, "## Stage 1")
    has(said(), "plan of lib.nvim")
    run("plan lib.nvim --to=file:" .. plan_file)
    has(said(), "already exists", "an existing file is never overwritten silently")
    run("plan lib.nvim --to=file:" .. plan_file .. " --force")
    eq(H.read(plan_file), text, "--force replaces it")

    local ids_file = out_dir .. "/ids.txt"
    run("plan lib.nvim --ready --format=ids --to=file:" .. ids_file)
    eq(H.read(ids_file), base.id .. "\n", "only what is ready, one id per line")
    local tsv_file = out_dir .. "/plan.tsv"
    run("plan lib.nvim --format=tsv --to=file:" .. tsv_file)
    has(H.read(tsv_file), "0\t" .. base.id .. "\tready\t")
    local for_file = out_dir .. "/for.md"
    run("plan --for=" .. mid.id .. " --to=file:" .. for_file)
    has(H.read(for_file), "# Plan: for " .. mid.id)
    lacks(
      H.read(for_file),
      stale.id,
      "the closure holds the task and what comes before it, nothing else"
    )

    run("plan --format=pdf")
    has(said(), "expected one of md|tsv|ids")
    run("plan --to=qf")
    has(said(), "--to=qf lists tasks")

    -- the plan lands in a scratch buffer by default
    run("plan lib.nvim")
    ok(vim.bo.filetype == "markdown", "the plan is shown in a Markdown buffer")
    has(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "## Ready now")

    -- ── list --ready / --waiting / --unestimated through the command ──
    local listed = out_dir .. "/ready.csv"
    run("list lib.nvim --ready --to=file:" .. listed)
    local ready_csv = assert(H.read(listed))
    has(ready_csv, base.id)
    lacks(ready_csv, mid.id)
    run("list --ready --waiting")
    has(said(), "exclude each other")

    -- ── estimate: the line, then the walk ──
    run("estimate lib.nvim")
    has(said(), "lib.nvim: 3 tasks")
    has(said(), "from 2 of 3")
    has(said(), "miss an effort or a value")

    local answers = {}
    local asked = {}
    cmd.chooser = function(msg, choices, cb)
      asked[#asked + 1] = msg
      local step = table.remove(answers, 1)
      cb(step and step(choices) or 1)
    end
    -- mid: effort M but no value -> asks the value only; stale: asks effort and value
    answers = {
      function()
        return 5 -- value 3 for mid  (Skip, Stop, 1, 2, 3, ...: index 5 is "3")
      end,
      function()
        return 5 -- effort for stale: Skip, Stop, XS, S, M -> index 5 = M
      end,
      function()
        return 1 -- value for stale: Skip
      end,
    }
    run("estimate lib.nvim --walk")
    eq(#asked, 3, "mid: value only; stale: effort and value")
    has(asked[1], mid.id)
    has(asked[1], "Value")
    has(asked[2], stale.id)
    has(asked[2], "Effort")
    eq(scan.find(mid.id, { root = root }).value, 3)
    eq(scan.find(mid.id, { root = root }).effort, "M", "an effort that was there stays")
    eq(scan.find(stale.id, { root = root }).effort, "M")
    eq(scan.find(stale.id, { root = root }).value, nil, "Skip leaves a field out")
    has(said(), "estimate: 2 changed")

    -- Stop writes what was given and ends the walk
    answers = {
      function()
        return 2 -- Stop at the first question (stale: value; its effort is set now)
      end,
    }
    asked = {}
    run("estimate lib.nvim --walk")
    eq(#asked, 1)
    has(said(), "nothing given, nothing changed")

    -- ── next: a dialog with the answer; Open jumps ──
    local shown = {}
    popup.chooser = function(msg, choices, cb)
      shown[#shown + 1] = { msg = msg, choices = choices }
      cb(shown[#shown].pick or 1)
    end
    run("next lib.nvim")
    eq(#shown, 1)
    has(shown[1].msg, "Next: " .. base.id)
    eq(shown[1].choices[1], "Not now", "the harmless choice comes first")
    has(shown[1].choices[2], "Open")
    shown = {}
    popup.chooser = function(msg, choices, cb)
      shown[#shown + 1] = { msg = msg, choices = choices }
      cb(2)
    end
    run("next lib.nvim")
    ok(
      vim.api.nvim_buf_get_name(0):find("cmd-base.md", 1, true) ~= nil,
      "Open jumps into the task file"
    )
    run("next --n=0")
    has(said(), "--n must be a whole number of at least 1")
    run("next --actor=robot")
    has(said(), "unknown actor")

    -- ── done: the dialog, the offer to open a task that still reads blocked ──
    local questions = {}
    confirm.yesno = function(msg, _, cb)
      questions[#questions + 1] = msg
      cb(true)
    end
    shown = {}
    popup.chooser = function(msg, choices, cb)
      shown[#shown + 1] = { msg = msg, choices = choices }
      cb(1)
    end
    run("done " .. base.id .. " --yes")
    eq(
      #questions >= 1,
      #vim.api.nvim_list_uis() > 0,
      "the offer needs somebody to answer: asked only with a UI"
    )
    eq(#shown, 1, "one dialog after the finish")
    has(shown[1].msg, "Done: " .. base.id)
    has(shown[1].msg, "freed: ")

    -- ── dashboard core: counts by the open blockers, the header, the hint ──
    local core = require("tasks_nvim.ui.dash_core")
    local gate = assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Dash gate", effort = "S" }))
    )
    local behind = assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Dash behind", effort = "M" }))
    )
    local freed_one =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Dash freed" })))
    local old_gate =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Dash old gate" })))
    assert(mutate.set(behind.id, { blocked_by = "[" .. gate.id .. "]" }, o))
    assert(mutate.set(freed_one.id, { blocked_by = "[" .. old_gate.id .. "]" }, o))
    assert(
      require("tasks_nvim.done_flow").run(
        old_gate.id,
        vim.tbl_extend("force", o, { pick_next = false })
      )
    )
    local open_now = assert(scan.open_tasks({ root = root, area = "lib.nvim" }))
    local ready = assert(core.readiness(open_now, root))
    eq(ready.states[gate.id], "ready")
    eq(ready.states[behind.id], "waiting")
    eq(ready.states[freed_one.id], "ready", "its only blocker is finished: no longer blocked")
    eq(ready.open_blockers[freed_one.id], {}, "and no hint about a blocker that is finished")
    eq(core.blocked_hint(open_now[1], {}), nil)
    local counts = core.counts(open_now, ready)
    ok(counts.blocked >= 1 and counts.ready >= 2)
    local plain_counts = core.counts(open_now)
    ok(
      plain_counts.blocked >= counts.blocked,
      "without readiness the old field-based count stays (a finished blocker still counts)"
    )
    eq(plain_counts.ready, nil)
    local header = core.header(open_now, {}, "lib.nvim", nil, ready)
    has(header, " ready")
    has(header, " d (", "the sum of the shown tasks, with how many of them it is made of")
    lacks(core.header(open_now, {}, "lib.nvim", nil), " ready", "no readiness, no ready count")
    has(core.line(open_now[1], { area = 10, effort = 3, status = 6 }, ready), "Cmd")
    ok(vim.tbl_contains(core.FILTER_DIMS, "unestimated"))
    eq(core.chips(core.set_dim({}, "unestimated", true)), { "unestimated" })
    eq(core.filter_to_options(core.set_dim({}, "unestimated", true)), { unestimated = true })
    eq(core.filter_from_stored({ unestimated = true }).unestimated, true)
    ok(
      core.signature(open_now, ready) ~= core.signature(open_now),
      "readiness is part of what a refresh compares"
    )

    -- headless / popup off: the same text as a plain message
    local quiet =
      assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Cmd quiet" })))
    require("tasks_nvim.config").merge({ next = { popup = false } })
    shown = {}
    run("done " .. quiet.id .. " --yes")
    eq(#shown, 0, "next.popup = false shows no dialog")
    has(said(), "Done: " .. quiet.id)
    require("tasks_nvim.config").merge({ next = { popup = true } })
  end)
  restore()
  if not good then
    error(failure, 0)
  end
end
