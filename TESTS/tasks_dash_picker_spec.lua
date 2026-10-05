-- TESTS/tasks_dash_picker_spec.lua -- the dashboard window itself (plugin_repos/tasks_dash.lua):
-- opens the real Snacks.picker headless against a fixture vault, feeds keys with nvim_feedkeys and
-- asserts the resulting file changes, notifications and re-opened pickers. Prompts (confirm, select,
-- input) are stubbed with scripted answers. Skipped (reported, not failed) when snacks.nvim is not
-- installed; the plain vim.ui.select fallback is covered either way.

---@diagnostic disable: duplicate-set-field, param-type-mismatch
-- Why: specs replace module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local dash = require("tasks_nvim.ui.dash")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  -- This spec drives the picker by hand and rewrites task files behind its back;
  -- the live refresh has its own spec (tasks_dash_refresh_spec.lua).
  local watch_was = dash.config.watch
  dash.config.watch = false

  -- ── scripted prompts and captured notifications ─────────────────────────
  local orig = {
    notify = vim.notify,
    select = vim.ui.select,
    input = vim.ui.input,
    yesno = confirm.yesno,
  }
  ---@type { msg: string, level: integer }[]
  local notes = {}
  ---@type table[]  prompts the stubs were asked, in order
  local asked = {}
  ---@type (fun(items: any[], opts: table): any)[]
  local select_queue = {}
  ---@type string[]
  local input_queue = {}
  local yesno_answer = true

  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end
  vim.ui.select = function(items, opts, cb)
    asked[#asked + 1] = { kind = "select", items = items, opts = opts }
    local answer = table.remove(select_queue, 1)
    cb(answer and answer(items, opts) or nil)
  end
  vim.ui.input = function(opts, cb)
    asked[#asked + 1] = { kind = "input", opts = opts }
    cb(table.remove(input_queue, 1))
  end
  confirm.yesno = function(msg, label, cb)
    asked[#asked + 1] = { kind = "confirm", msg = msg, label = label }
    cb(yesno_answer)
  end

  ---@param value string
  ---@return fun(items: any[]): any
  local function pick(value)
    return function(items)
      for _, item in ipairs(items) do
        local label = type(item) == "table" and (item.label or item.id) or item
        if label == value then
          return item
        end
      end
      error("the prompt has no entry " .. vim.inspect(value) .. " in " .. vim.inspect(items), 0)
    end
  end

  local function said()
    local out = {}
    for _, n in ipairs(notes) do
      out[#out + 1] = n.msg
    end
    return table.concat(out, "\n")
  end

  local function reset()
    notes, asked, select_queue, input_queue, yesno_answer = {}, {}, {}, {}, true
  end

  local function wait_for(cond, ms)
    return vim.wait(ms or 3000, cond, 10)
  end

  local function flush()
    vim.wait(60, function()
      return false
    end)
  end

  -- ── fixture ─────────────────────────────────────────────────────────────
  local today = os.date("%Y-%m-%d") --[[@as string]]
  local function add(area, slug, title, status, extra)
    local m = F.meta(title, status, extra)
    m[#m + 1] = { "created", today }
    m[#m + 1] = { "updated", "2026-01-01" }
    return F.task(H, root, area, slug, m)
  end
  local alpha = add("lib.nvim", "alpha", "Alpha feature", "doing", {
    { "kind", "feature" },
    { "prio", "1" },
    { "effort", "M" },
    { "tags", "[ui]" },
  })
  local beta = add("lib.nvim", "beta", "Beta bug", "open", { { "kind", "bug" }, { "prio", "2" } })
  local gamma = add("cascade.nvim", "gamma", "Gamma idea", "decision", { { "kind", "idea" } })
  add("cascade.nvim", "delta", "Delta task", "open", {
    { "kind", "task" },
    { "tags", "[x]" },
  })

  local FIXTURE = { alpha, beta, gamma, root .. "/cascade.nvim/ROADMAP/tasks/delta.md" }
  local fixture_text = {}
  for _, path in ipairs(FIXTURE) do
    fixture_text[path] = H.read(path)
  end

  ---Back to the starting state: the four task files as written above, no index.
  local function reset_fixture()
    for path, text in pairs(fixture_text) do
      H.write(path, text)
    end
    os.remove(root .. "/lib.nvim/ROADMAP/TASKS.md")
    os.remove(root .. "/cascade.nvim/ROADMAP/TASKS.md")
  end

  local function status_of(id)
    local t = scan.find(id, { root = root })
    return t and t.status or nil
  end

  -- ── the plain fallback (vim.ui.select), no snacks needed ────────────────
  local function fallback_checks()
    reset()
    -- pick the first row (alpha, doing), advance its prio 1 -> 2, then leave the reopened list
    select_queue = {
      function(items)
        eq(#items, 4, "the plain list shows every open task")
        eq(items[1].id, "lib.nvim/alpha", "sorted like the dashboard")
        return items[1]
      end,
      pick("advance prio"),
      function()
        return nil
      end,
    }
    dash.open({ tasks = {}, root = root, filter = {} }, { persist = false, backend = "select" })
    flush()
    has(H.read(alpha), "prio: 2", "the fallback advanced the prio of the chosen task")
    has(said(), "prio: 1 changed", "one summary notification")
    eq(#asked, 3, "list, menu, list again")
    has(asked[1].opts.prompt, "4 open", "the prompt carries the header")

    -- the menu offers the single-task actions
    reset()
    select_queue = {
      function(items)
        return items[1]
      end,
      function(items)
        local labels = vim.tbl_map(function(m)
          return m.label
        end, items)
        eq(labels, {
          "open the file",
          "preview the file (mdview)",
          "advance status",
          "advance prio",
          "finish",
          "filter ...",
          "next sort order",
          "export the list ...",
          "Backlog of the area",
          "ROADMAP.md of the area",
        })
        return nil
      end,
    }
    dash.open({ tasks = {}, root = root, filter = {} }, { persist = false, backend = "select" })
    flush()

    -- an empty result says so instead of opening an empty list
    reset()
    dash.open({ tasks = {}, root = root, filter = { status = { "parked" } } }, {
      persist = false,
      backend = "select",
    })
    flush()
    has(said(), "no open task matches")
    eq(#asked, 0)

    -- the default seam: `tasks_cmd.dashboard == nil` opens the dashboard, `false` the scratch buffer
    reset()
    local opened
    local orig_open = dash.open
    dash.open = function(v)
      opened = v
    end
    cmd.dashboard = nil
    cmd.list({ flags = {}, args = {} })
    ok(opened, "no --to/--format: the dashboard opens by default")
    eq(opened.root, root)
    eq(#opened.tasks, 4)
    opened = nil
    cmd.list({ flags = { to = "buffer" }, args = {} })
    eq(opened, nil, "--to=buffer keeps the old behaviour")
    vim.cmd("silent! bwipeout!")
    cmd.dashboard = false
    cmd.list({ flags = {}, args = {} })
    eq(opened, nil, "dashboard = false means the scratch buffer")
    vim.cmd("silent! bwipeout!")
    dash.open = orig_open
    cmd.dashboard = nil

    -- ── export: the path typed at the prompt goes as typed ───────────────
    -- `vim.fn.expand` on it would turn the wildcard in `report[1].csv` into the existing
    -- `report1.csv` (which the export then overwrote), run backticks through the shell, ...
    reset()
    local out_dir = H.tmpdir()
    H.write(out_dir .. "/report1.csv", "precious\n")
    local export_state = { root = root, filter = {}, sort = "default" }
    local export_tasks = scan.all({ root = root })
    local delivered
    select_queue = { pick("File ... (CSV)") }
    input_queue = { out_dir .. "/report[1].csv" }
    dash.export(export_state, export_tasks, function(d)
      delivered = d
    end)
    eq(delivered, true, "the export went through: " .. said())
    eq(
      H.read(out_dir .. "/report1.csv"),
      "precious\n",
      "the file the wildcard matches is untouched"
    )
    has(H.read(out_dir .. "/report[1].csv") or "", "Task,Status", "the literal name was written")

    -- ── an unexpected error in a batch still ends the progress it started ──
    -- (a statusline progress that is never finished keeps its timer running for good)
    local core = require("tasks_nvim.ui.dash_core")
    local progress = require("lib.nvim.progress")
    local real_create, real_apply_set, real_apply_done =
      progress.create, core.apply_set, core.apply_done
    local finished = {}
    progress.create = function()
      return {
        update = function() end,
        finish = function(_, text)
          finished[#finished + 1] = text
        end,
      }
    end
    core.apply_set = function()
      error("engine exploded", 0)
    end
    core.apply_done = function()
      error("engine exploded again", 0)
    end
    local alpha_task = assert(scan.find("lib.nvim/alpha", { root = root }))
    local raised, raised_err = pcall(dash.cycle, export_state, { alpha_task }, "status")
    eq(raised, false, "the error still propagates")
    has(raised_err, "engine exploded")
    eq(#finished, 1, "but the progress of `s` was finished")
    yesno_answer = true
    local fin_raised, fin_err = pcall(dash.finish, export_state, { alpha_task }, function() end)
    eq(fin_raised, false)
    has(fin_err, "engine exploded again")
    eq(#finished, 2, "and the progress of `D` too")
    progress.create, core.apply_set, core.apply_done = real_create, real_apply_set, real_apply_done
  end

  -- ── locate snacks ───────────────────────────────────────────────────────
  local function find_snacks()
    -- No ipairs: the first candidate is nil when $SNACKS_DIR is unset.
    local candidates = {
      vim.env.SNACKS_DIR or "",
      vim.fn.stdpath("data") .. "/lazy/snacks.nvim",
      vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))) .. "/.deps/snacks.nvim",
    }
    for _, dir in ipairs(candidates) do
      if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/snacks/picker") == 1 then
        return dir
      end
    end
    return nil
  end

  local function restore()
    vim.notify, vim.ui.select, vim.ui.input = orig.notify, orig.select, orig.input
    confirm.yesno = orig.yesno
    cmd.dashboard = nil
    vault.set_root(nil)
    dash.config.watch = watch_was
    local loaded, S = pcall(require, "snacks")
    if loaded and type(S) == "table" and S.picker then
      for _, picker in ipairs(S.picker.get({ source = "tasks_nvim" })) do
        pcall(picker.close, picker)
      end
    end
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  local snacks_dir = find_snacks()
  local ok_run, err = pcall(function()
    fallback_checks()
    reset_fixture()
    if not snacks_dir then
      -- A silent skip made this spec pass with no picker assertion at all. CI sets TASKS_REQUIRE_SNACKS and
      -- checks snacks.nvim out into .deps/, so there a missing snacks is a failure; locally it is a visible skip.
      if vim.env.TASKS_REQUIRE_SNACKS == "1" then
        error("snacks.nvim is required here (TASKS_REQUIRE_SNACKS=1) but was not found")
      end
      io.stdout:write("      (snacks.nvim not found: the picker part of this spec is skipped)\n")
      return
    end
    vim.opt.rtp:append(snacks_dir)
    local Snacks = require("snacks")
    ok(Snacks.picker, "Snacks.picker loads")

    ---@return table|nil
    local function current_picker()
      for _, p in ipairs(Snacks.picker.get({ source = "tasks_nvim" })) do
        if not p.closed then
          return p
        end
      end
      return nil
    end

    ---Wait until a dashboard picker is open and has listed `n` items.
    ---@param n integer
    ---@return table picker
    local function opened(n)
      ok(
        wait_for(function()
          local p = current_picker()
          return p ~= nil and p:count() == n and not p.finder.task:running()
        end),
        "the dashboard opens with " .. n .. " item(s)"
      )
      local p = assert(current_picker())
      flush()
      return p
    end

    ---@param p table
    ---@return string[] ids
    local function ids(p)
      return vim.tbl_map(function(i)
        return i.task.id
      end, p:items())
    end

    local function keys(k)
      vim.api.nvim_feedkeys(vim.keycode(k), "mx", false)
      flush()
    end

    local function close_all()
      for _, p in ipairs(Snacks.picker.get({ source = "tasks_nvim" })) do
        p:close()
      end
      flush()
    end

    -- ── open: lines, header, order ────────────────────────────────────────
    reset()
    cmd.dashboard = nil
    cmd.list({ flags = {}, args = {} })
    local p = opened(4)
    eq(
      ids(p),
      { "lib.nvim/alpha", "cascade.nvim/gamma", "lib.nvim/beta", "cascade.nvim/delta" },
      "doing, decision, then open by prio"
    )
    has(p.title, "Tasks \194\183 4 open \194\183 1 decision \194\183 0 blocked")
    local lines = vim.api.nvim_buf_get_lines(p.list.win.buf, 0, 4, false)
    has(lines[1], "P1 doing")
    has(lines[1], "Alpha feature")
    has(lines[2], "decision")
    has(lines[2], "cascade.nvim")
    ok(p.opts.preview == "file", "the task file is the preview")
    eq(p:items()[1].file, alpha, "an item points at its task file")

    -- ── s: advance status of the current task, in place ───────────────────
    p:focus("list")
    flush()
    keys("s")
    eq(status_of("lib.nvim/alpha"), "decision", "s advanced doing -> decision")
    has(said(), "status: 1 changed, 0 unchanged, 0 failed (1 index regenerated)")
    ok(H.exists(root .. "/lib.nvim/ROADMAP/TASKS.md"), "the index was regenerated")
    eq(#vim.tbl_filter(function(n)
      return n.msg:find("status:", 1, true) ~= nil
    end, notes), 1, "exactly one notification")
    p = opened(4)
    eq(ids(p)[1], "lib.nvim/alpha", "the open picker refreshed in place (still first)")
    ok(current_picker() == p, "the same picker stayed open")

    -- ── <Tab> marks, p advances the marked ones as one batch ──────────────
    reset()
    p:focus("list")
    flush()
    -- cursor on item 1 (alpha, prio 1): mark it and the next (gamma, no prio)
    keys("<Tab>")
    keys("<Tab>")
    eq(#p:selected(), 2, "two tasks are marked")
    keys("p")
    has(H.read(alpha), "prio: 2", "alpha 1 -> 2")
    has(H.read(gamma), "prio: 1", "gamma none -> 1")
    lacks(H.read(beta), "prio: 3", "an unmarked task is untouched")
    has(said(), "prio: 2 changed")
    eq(#p:selected(), 0, "the marks are cleared by the refresh")

    -- a second, larger batch: status of three marked tasks -> one summary
    reset()
    p = opened(4)
    p:focus("list")
    flush()
    keys("<Tab>")
    keys("<Tab>")
    keys("<Tab>")
    keys("s")
    has(said(), "status: 3 changed")
    eq(#vim.tbl_filter(function(n)
      return n.msg:find("changed", 1, true) ~= nil
    end, notes), 1, "one summary for the whole batch")

    -- ── <CR> opens the file under the cursor ──────────────────────────────
    reset()
    p = opened(4)
    p:focus("list")
    flush()
    local first = assert(p:current(), "the cursor is on an item")
    keys("<CR>")
    flush()
    eq(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
      first.task.path,
      "<CR> opens the task file of the current line"
    )
    ok(current_picker() == nil, "the picker closed")
    vim.cmd("silent! %bwipeout!")

    -- ── gp previews the task file through mdview (seams: no browser) ──────
    reset()
    local previewed = {}
    local preview = require("tasks_nvim.ui.preview")
    preview.probe = function()
      return true
    end
    preview.opener = function(path)
      previewed[#previewed + 1] = path
      return true
    end
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    local under_cursor = assert(p:current(), "the cursor is on an item")
    keys("gp")
    ok(
      wait_for(function()
        return #previewed == 1
      end),
      "gp hands the file to the mdview opener"
    )
    eq(previewed[1], under_cursor.task.path, "gp previews the task under the cursor")
    ok(current_picker() == nil, "the picker closed")

    -- without mdview the key says so instead of failing
    reset()
    previewed = {}
    preview.probe = function()
      return false, "mdview.nvim is not available (test)"
    end
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    keys("gp")
    ok(
      wait_for(function()
        return said():find("not available", 1, true) ~= nil
      end),
      "a missing mdview is reported"
    )
    eq(#previewed, 0, "nothing was opened")
    preview.probe, preview.opener = nil, nil
    vim.cmd("silent! %bwipeout!")

    reset_fixture()

    -- ── g? help float closes again on any key ─────────────────────────────
    reset()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    local wins_before = #vim.api.nvim_list_wins()
    p:focus("list")
    flush()
    keys("g?")
    eq(#vim.api.nvim_list_wins(), wins_before + 1, "g? opens a help float")
    keys("<C-l>")
    flush()
    eq(#vim.api.nvim_list_wins(), wins_before, "any key closes the help")
    ok(current_picker() == p, "the picker survived the help")

    -- ── o: sort order cycles, shows a chip, is remembered ─────────────────
    reset()
    assert(
      require("tasks_nvim.mutate").set("cascade.nvim/delta", { severity = "high" }, { root = root })
    )
    close_all()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    eq(ids(p)[1], "lib.nvim/alpha", "default order first")
    lacks(p.title, "sort:", "the default order shows no chip")
    p:focus("list")
    flush()
    keys("o")
    ok(
      wait_for(function()
        return p.title:find("[sort: prio-effort]", 1, true) ~= nil
      end),
      "o switches to prio-effort and the title says so"
    )
    keys("o")
    ok(
      wait_for(function()
        return p.title:find("[sort: severity]", 1, true) ~= nil
      end),
      "o again: severity"
    )
    p = opened(4)
    eq(ids(p)[1], "cascade.nvim/delta", "the high-severity task comes first")
    has(vim.api.nvim_buf_get_lines(p.list.win.buf, 0, 1, false)[1], "[high]")
    -- the sort is remembered like the filter: a fresh dashboard starts in it
    close_all()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    has(p.title, "[sort: severity]")
    eq(ids(p)[1], "cascade.nvim/delta", "a new dashboard starts in the remembered order")
    p:focus("list")
    flush()
    keys("o")
    ok(
      wait_for(function()
        return p.title:find("[sort: frecency]", 1, true) ~= nil
      end),
      "the third press goes on to frecency"
    )
    keys("o")
    ok(
      wait_for(function()
        return p.title:find("sort:", 1, true) == nil
      end),
      "the fourth press wraps around to the default"
    )
    p = opened(4)
    eq(ids(p)[1], "lib.nvim/alpha")
    -- f: the effort and severity dimensions are in the menu
    reset()
    select_queue = { pick("severity"), pick("high") }
    keys("f")
    p = opened(1)
    has(p.title, "[severity: high]")
    eq(ids(p), { "cascade.nvim/delta" })
    eq(asked[1].items[3], "effort", "the f menu offers effort after prio")
    ok(vim.tbl_contains(asked[1].items, "severity"))
    reset()
    select_queue = { pick("severity"), pick("(any)") }
    p:focus("list")
    flush()
    keys("f")
    p = opened(4)
    reset_fixture()
    p:focus("list")
    flush()

    -- ── the input window: Alt chords, plain letters stay text/editing ─────
    reset()
    p:focus("input")
    flush()
    keys("<M-s>")
    eq(status_of("lib.nvim/alpha"), "decision", "<M-s> in the input window advanced the status")
    eq(p.input:get(), "", "the Alt chord typed nothing into the search")
    reset_fixture()
    keys("<M-r>")
    p = opened(4)
    eq(status_of("lib.nvim/alpha"), "doing", "fixture restored")
    p:focus("input")
    flush()
    keys("s")
    eq(status_of("lib.nvim/alpha"), "doing", "a plain `s` in the input window is not an action")
    p.input:set("", "")
    p:focus("list")
    flush()

    -- ── f: filter chip, picker reopens filtered, filter persists in state ─
    reset()
    select_queue = { pick("status"), pick("open") }
    p:focus("list")
    flush()
    keys("f")
    p = opened(2)
    eq(#asked, 2, "dimension, then value")
    eq(asked[1].items[1], "status")
    ok(vim.tbl_contains(asked[1].items, "(clear all filters)"))
    ok(vim.tbl_contains(asked[2].items, "(any)"), "a value menu offers the clearing entry")
    has(p.title, "[status: open]", "the chip is in the title")
    has(p.title, "2 open", "the counts follow the filter")
    for _, id in ipairs(ids(p)) do
      eq(status_of(id), "open")
    end

    -- a second dimension; tags come from the tasks of the scope
    reset()
    select_queue = { pick("tag"), pick("x") }
    p:focus("list")
    flush()
    keys("f")
    p = opened(1)
    ok(vim.tbl_contains(asked[2].items, "ui") and vim.tbl_contains(asked[2].items, "x"))
    has(p.title, "[status: open] [tag: x]", "chips accumulate")
    eq(ids(p), { "cascade.nvim/delta" })

    -- clear all
    reset()
    select_queue = { pick("(clear all filters)") }
    p:focus("list")
    flush()
    keys("f")
    p = opened(4)
    lacks(p.title, "[status")

    -- blocked toggles
    reset()
    select_queue = { pick("blocked") }
    p:focus("list")
    flush()
    keys("f")
    opened(0)
    has(assert(current_picker()).title, "[blocked]")
    reset()
    select_queue = { pick("blocked") }
    assert(current_picker()):focus("list")
    flush()
    keys("f")
    p = opened(4)

    -- ── e: export the marked (or all shown) tasks ─────────────────────────
    reset()
    select_queue = { pick("Scratch buffer (Markdown)") }
    p:focus("list")
    flush()
    keys("e")
    flush()
    ok(
      wait_for(function()
        return current_picker() == nil
      end),
      "e closes the picker"
    )
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    has(text, "# Open tasks")
    has(text, "lib.nvim/alpha")
    has(text, "cascade.nvim/delta", "no marks: every shown task is exported")
    eq(#asked, 1)
    vim.cmd("silent! %bwipeout!")

    -- marked tasks only, to a file, with the file's own prompt
    reset()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    keys("<Tab>")
    keys("<Tab>")
    local out_file = H.tmpdir() .. "/export.csv"
    select_queue = { pick("File ... (CSV)") }
    input_queue = { out_file }
    keys("e")
    ok(
      wait_for(function()
        return H.exists(out_file)
      end),
      "the CSV file is written"
    )
    local csv = H.read(out_file)
    has(csv, "Task,Status,Prio")
    has(csv, "lib.nvim/alpha")
    has(csv, "cascade.nvim/gamma")
    lacks(csv, "lib.nvim/beta", "an unmarked task is not exported")
    eq(select(2, csv:gsub("\n", "\n")), 3, "header + two rows")

    -- cancelling the export prompt reopens the picker
    reset()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    select_queue = {
      function()
        return nil
      end,
    }
    keys("e")
    opened(4)

    -- the browser preview entry writes a temp Markdown file and hands it to mdview
    reset()
    local export_seen = {}
    local export_preview = require("tasks_nvim.ui.preview")
    export_preview.probe = function()
      return true
    end
    export_preview.temp_root = function()
      return H.tmpdir()
    end
    export_preview.opener = function(path)
      export_seen[#export_seen + 1] = { path = path, text = H.read(path) }
      return true
    end
    p = opened(4) -- still open from the cancelled export above
    p:focus("list")
    flush()
    select_queue = { pick("Preview in browser (mdview)") }
    keys("e")
    ok(
      wait_for(function()
        return #export_seen == 1
      end),
      "the preview entry reaches the mdview opener"
    )
    has(export_seen[1].path, "tasks-all.md", "the temp file is named after the scope")
    has(export_seen[1].text, "# Open tasks")
    has(export_seen[1].text, "lib.nvim/alpha")
    export_preview.cleanup_all()
    export_preview.probe, export_preview.opener, export_preview.temp_root = nil, nil, nil
    -- the next block expects an open picker
    reset()
    cmd.list({ flags = {}, args = {} })
    opened(4)

    -- ── D: confirm, finish the marked batch, picker reopens ───────────────
    reset()
    p = opened(4)
    p:focus("list")
    flush()
    keys("<Tab>")
    keys("<Tab>")
    local marked = {}
    for _, item in ipairs(p:selected()) do
      marked[#marked + 1] = item.task.id
    end
    eq(#marked, 2)
    yesno_answer = false
    keys("D")
    p = opened(4)
    eq(asked[1].kind, "confirm")
    has(asked[1].msg, "Finish 2 tasks?")
    has(asked[1].msg, marked[1])
    for _, id in ipairs(marked) do
      ok(status_of(id), "declined: " .. id .. " stays open")
    end
    has(said(), "cancelled")

    reset()
    p:focus("list")
    flush()
    keys("<Tab>")
    keys("<Tab>")
    marked = {}
    for _, item in ipairs(p:selected()) do
      marked[#marked + 1] = item.task.id
    end
    keys("D")
    p = opened(2)
    has(said(), "done: 2 finished, 0 already finished, 0 failed")
    for _, id in ipairs(marked) do
      eq(status_of(id), nil, id .. " left ROADMAP/tasks")
      ok(scan.find_done(id, { root = root }), id .. " is in Backlog/")
    end
    eq(#vim.tbl_filter(function(n)
      return n.msg:find("done:", 1, true) ~= nil
    end, notes), 1, "one summary for the finish batch")

    -- ── gr / gb: the area's ROADMAP.md and Backlog ────────────────────────
    reset()
    p:focus("list")
    flush()
    keys("gr")
    flush()
    has(said(), "has no ROADMAP/ROADMAP.md", "gr without a ROADMAP.md warns")
    local area_of_first = p:items()[1] and p:items()[1].task.area or "?"
    ok(
      wait_for(function()
        return current_picker() == nil
      end),
      "gr closes the picker"
    )

    cmd.list({ flags = {}, args = {} })
    p = opened(2)
    local cursor_task = p:items()[1].task
    H.write(root .. "/" .. cursor_task.area .. "/ROADMAP/ROADMAP.md", "# Roadmap\n")
    reset()
    p:focus("list")
    flush()
    keys("gr")
    flush()
    eq(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
      root .. "/" .. cursor_task.area .. "/ROADMAP/ROADMAP.md",
      "gr opens ROADMAP.md of the area under the cursor"
    )
    vim.cmd("silent! %bwipeout!")
    ok(area_of_first ~= nil)

    cmd.list({ flags = {}, args = {} })
    p = opened(2)
    reset()
    p:focus("list")
    flush()
    local area_now = assert(p:current()).task.area
    local sink = require("lib.nvim.harvest").sink
    local orig_sink_select = sink.select
    local chooser_calls = {}
    sink.select = function(items, sopts)
      chooser_calls[#chooser_calls + 1] = { items = items, opts = sopts }
    end
    local gb_ok, gb_err = pcall(function()
      keys("gb")
      flush()
    end)
    sink.select = orig_sink_select
    ok(gb_ok, tostring(gb_err))
    -- pickers.nvim is not on this runtime path, so :Tasks folder falls back to a
    -- chooser over the Markdown files of Backlog/ (at least the README).
    eq(#chooser_calls, 1, "gb goes through :Tasks folder <area> backlog")
    eq(chooser_calls[1].opts.prompt, area_now .. "/backlog")
    ok(vim.tbl_contains(vim.tbl_map(vim.fs.basename, chooser_calls[1].items), "README.md"))
    ok(
      chooser_calls[1].items[1]:find("/" .. area_now .. "/Backlog/", 1, true),
      "the area's Backlog folder"
    )
    vim.cmd("silent! %bwipeout!")

    -- ── r rescans: a task added behind the dashboard's back shows up ──────
    cmd.list({ flags = {}, args = {} })
    p = opened(2)
    add("lib.nvim", "late", "Late arrival", "open", {})
    p:focus("list")
    flush()
    keys("r")
    opened(3)
    close_all()

    -- a filter given on the command line wins over nothing remembered
    reset()
    cmd.list({ flags = { status = "decision" }, args = {} })
    p = opened(0)
    has(p.title, "[status: decision]")
    close_all()
  end)
  restore()
  if not ok_run then
    error(err, 0)
  end
end
