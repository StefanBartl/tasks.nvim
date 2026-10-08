-- TESTS/tasks_dash_refresh_spec.lua -- the dashboard's live refresh and frecency (plugin_repos/tasks_dash.lua)
-- on the real Snacks.picker, headless, against a fixture vault with REAL file watchers: a change made behind the
-- dashboard's back shows up by itself with cursor and marks on the same tasks, the dashboard's own writes cause no
-- second scan, closing releases every handle, the opt-out and a failing watcher fall back to `r`, and opening or
-- changing a task feeds the frecency sort. Skipped (reported, not failed) when snacks.nvim is not installed.

---@diagnostic disable: duplicate-set-field
-- Why: specs replace module functions with test doubles on purpose.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local dash = require("tasks_nvim.ui.dash")
  local core = require("tasks_nvim.ui.dash_core")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local frecency = require("tasks_nvim.frecency")
  local vault = require("tasks_nvim.vault")
  local uv = vim.uv or vim.loop

  local root = F.vault(H)
  vault.set_root(root)
  frecency.set_path(H.tmpdir() .. "/frecency.json")

  local orig = {
    notify = vim.notify,
    select = vim.ui.select,
    yesno = confirm.yesno,
    config = vim.deepcopy(dash.config),
    refresh_if_changed = dash.refresh_if_changed,
    load = core.load,
  }
  ---@type { msg: string, level: integer }[]
  local notes = {}
  local yesno_answer = true
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end
  vim.ui.select = function(_, _, cb)
    cb(nil)
  end
  confirm.yesno = function(_, _, cb)
    cb(yesno_answer)
  end
  local function said()
    local out = {}
    for _, n in ipairs(notes) do
      out[#out + 1] = n.msg
    end
    return table.concat(out, "\n")
  end

  local function wait_for(cond, ms)
    return vim.wait(ms or 4000, cond, 10)
  end
  local function flush(ms)
    vim.wait(ms or 60, function()
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
  })
  local beta = add("lib.nvim", "beta", "Beta bug", "open", { { "kind", "bug" }, { "prio", "2" } })
  local gamma = add("cascade.nvim", "gamma", "Gamma idea", "decision", { { "kind", "idea" } })
  local delta = add("cascade.nvim", "delta", "Delta task", "open", { { "kind", "task" } })
  local FIXTURE = { alpha, beta, gamma, delta }
  local fixture_text = {}
  for _, path in ipairs(FIXTURE) do
    fixture_text[path] = H.read(path)
  end
  local DEFAULT_ORDER =
    { "lib.nvim/alpha", "cascade.nvim/gamma", "lib.nvim/beta", "cascade.nvim/delta" }

  local function reset_fixture()
    for path, text in pairs(fixture_text) do
      H.write(path, text)
    end
    for _, extra in ipairs({ "lib.nvim/ROADMAP/tasks/aaa.md", "lib.nvim/ROADMAP/tasks/notes.txt" }) do
      os.remove(root .. "/" .. extra)
    end
    for _, area in ipairs({ "lib.nvim", "cascade.nvim" }) do
      os.remove(root .. "/" .. area .. "/ROADMAP/TASKS.md")
    end
  end

  ---@param kind string
  ---@return integer
  local function handles_of(kind)
    flush(50)
    local n = 0
    uv.walk(function(h)
      if h:get_type() == kind and not h:is_closing() then
        n = n + 1
      end
    end)
    return n
  end

  local function restore()
    vim.notify, vim.ui.select, confirm.yesno = orig.notify, orig.select, orig.yesno
    dash.config = orig.config
    dash.refresh_if_changed = orig.refresh_if_changed
    core.load = orig.load
    cmd.dashboard = nil
    vault.set_root(nil)
    frecency.set_path(nil)
    local loaded, S = pcall(require, "snacks")
    if loaded and type(S) == "table" and S.picker then
      for _, picker in ipairs(S.picker.get({ source = "tasks_nvim" })) do
        pcall(picker.close, picker)
      end
    end
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  local function find_snacks()
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

  local snacks_dir = find_snacks()
  local ok_run, err = pcall(function()
    if not snacks_dir then
      -- A silent skip made this spec pass with no picker assertion at all. CI sets TASKS_REQUIRE_SNACKS and
      -- checks snacks.nvim out into .deps/, so there a missing snacks is a failure; locally it is a visible skip
      -- (a line that starts with `skip`: testing.nvim reports the file as skipped, not as "made no assertions";
      -- that holds only while nothing was asserted before this line, so keep it ahead of the first assertion).
      -- scripts/test.sh finds snacks.nvim and hands it over in $SNACKS_DIR.
      if vim.env.TASKS_REQUIRE_SNACKS == "1" then
        error("snacks.nvim is required here (TASKS_REQUIRE_SNACKS=1) but was not found")
      end
      io.stdout:write(
        "skip  tasks_dash_refresh_spec.lua: snacks.nvim not found (set $SNACKS_DIR)\n"
      )
      return
    end
    vim.opt.rtp:append(snacks_dir)
    local Snacks = require("snacks")

    -- the dashboard uses the real watcher, with a short debounce
    dash.config.watch = true
    dash.config.watch_debounce_ms = 80

    local function current_picker()
      for _, p in ipairs(Snacks.picker.get({ source = "tasks_nvim" })) do
        if not p.closed then
          return p
        end
      end
      return nil
    end
    local function opened(n)
      ok(
        wait_for(function()
          local p = current_picker()
          return p ~= nil and p:count() == n and not p.finder.task:running()
        end),
        "the dashboard has " .. n .. " item(s)"
      )
      local p = assert(current_picker())
      flush()
      return p
    end
    local function ids(p)
      return vim.tbl_map(function(i)
        return i.task.id
      end, p:items())
    end
    local function marked_ids(p)
      local out = {}
      for _, item in ipairs(p:selected()) do
        out[#out + 1] = item.task.id
      end
      table.sort(out)
      return out
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

    ---Do `fn` (a change behind the dashboard's back) until `cond` holds: a watcher backend may need a
    ---moment before it is live.
    ---@param fn fun(i: integer)
    ---@param cond fun(): boolean
    ---@param what string
    local function change_until(fn, cond, what)
      local i = 0
      local done = wait_for(function()
        i = i + 1
        fn(i)
        return wait_for(cond, 600)
      end, 6000)
      ok(done, "the dashboard noticed: " .. what)
    end

    ---Count how often the watcher asked for a refresh and what came of it.
    local asked, changed = 0, 0
    dash.refresh_if_changed = function(state, picker)
      asked = asked + 1
      local refreshed = orig.refresh_if_changed(state, picker)
      if refreshed then
        changed = changed + 1
      end
      return refreshed
    end
    local loads = 0
    core.load = function(o)
      loads = loads + 1
      return orig.load(o)
    end

    local fs_base = handles_of("fs_event")

    -- ── a new task appears: the list follows, cursor and marks stay on their tasks ──
    cmd.list({ flags = {}, args = {} })
    local p = opened(4)
    eq(ids(p), DEFAULT_ORDER)
    ok(handles_of("fs_event") > fs_base, "the open dashboard watches folders")
    p:focus("list")
    flush()
    keys("<Tab>")
    keys("<Tab>")
    eq(marked_ids(p), { "cascade.nvim/gamma", "lib.nvim/alpha" }, "two tasks marked")
    local on = assert(p:current()).task.id
    eq(on, "lib.nvim/beta", "the cursor moved on to the third task")

    change_until(function()
      add("lib.nvim", "aaa", "Newcomer", "doing", { { "prio", "1" } })
    end, function()
      local pp = current_picker()
      return pp ~= nil and pp:count() == 5 and not pp.finder.task:running()
    end, "a new task file")
    p = opened(5)
    eq(ids(p)[1], "lib.nvim/aaa", "the newcomer sorts first")
    has(p.title, "5 open", "the header counts follow")
    ok(
      wait_for(function()
        return p:current() ~= nil and p:current().task.id == on
      end),
      "the cursor stays on the same task although its line moved"
    )
    eq(
      marked_ids(p),
      { "cascade.nvim/gamma", "lib.nvim/alpha" },
      "the marks stay on the same tasks"
    )

    -- an edit: status changes show without a key press
    reset_fixture()
    close_all()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    change_until(function(i)
      H.write(beta, (fixture_text[beta]:gsub("status: open", "status: doing")) .. (" "):rep(i % 2))
    end, function()
      local pp = current_picker()
      return pp ~= nil and ids(pp)[2] == "lib.nvim/beta" and not pp.finder.task:running()
    end, "a status edit")
    p = assert(current_picker())
    has(vim.api.nvim_buf_get_lines(p.list.win.buf, 1, 2, false)[1], "doing")
    reset_fixture()

    -- a deleted task: gone from the list, no error
    local errors_before = #vim.tbl_filter(function(n)
      return n.level >= vim.log.levels.ERROR
    end, notes)
    change_until(function()
      os.remove(delta)
    end, function()
      local pp = current_picker()
      return pp ~= nil and pp:count() == 3 and not pp.finder.task:running()
    end, "a deleted task file")
    eq(#vim.tbl_filter(function(n)
      return n.level >= vim.log.levels.ERROR
    end, notes), errors_before, "a vanished file is no error")
    reset_fixture()
    close_all()

    -- ── sort and filter survive a refresh ─────────────────────────────────
    cmd.list({ flags = { status = "open,doing,decision", sort = "prio-effort" }, args = {} })
    p = opened(4)
    has(p.title, "[sort: prio-effort]")
    local title_before = p.title
    change_until(function()
      add("lib.nvim", "aaa", "Newcomer", "doing", { { "prio", "1" } })
    end, function()
      local pp = current_picker()
      return pp ~= nil and pp:count() == 5 and not pp.finder.task:running()
    end, "a task while a filter and a sort are set")
    p = opened(5)
    has(p.title, "[status: open,doing,decision]", "the filter chip is still there")
    has(p.title, "[sort: prio-effort]", "the sort order too")
    ok(p.title ~= title_before, "while the counts changed")
    reset_fixture()

    -- ── no change, no redraw ──────────────────────────────────────────────
    close_all()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    local asked0, changed0 = asked, changed
    H.write(root .. "/lib.nvim/ROADMAP/tasks/notes.txt", "not a task")
    ok(
      wait_for(function()
        return asked > asked0
      end),
      "the watcher saw the file and asked for a refresh"
    )
    flush(200)
    eq(changed, changed0, "but the rescan found the same list, so nothing was redrawn")
    ok(current_picker() == p)
    os.remove(root .. "/lib.nvim/ROADMAP/tasks/notes.txt")

    -- ── the dashboard's own batch: one scan, no echo ──────────────────────
    close_all()
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    flush(300) -- let any start-up noise settle
    p:focus("list")
    flush()
    asked = 0
    local loads0 = loads
    keys("s")
    ok(
      wait_for(function()
        return loads > loads0
      end),
      "s rescanned once, in place"
    )
    flush(900) -- longer than the mute window and the debounce
    eq(loads - loads0, 1, "exactly one scan for the batch: the echo of its own writes is muted")
    eq(asked, 0, "the watcher did not even ask")
    has(said(), "status: 1 changed")
    eq(
      require("tasks_nvim.scan").find("lib.nvim/alpha", { root = root }).status,
      "decision",
      "the batch itself worked"
    )
    reset_fixture()

    -- ── closing releases everything ───────────────────────────────────────
    close_all()
    eq(
      handles_of("fs_event"),
      fs_base,
      "no fs_event handle is left after closing (the timer is checked in the watcher spec: snacks has its own)"
    )
    asked = 0
    H.write(alpha, fixture_text[alpha] .. "\n")
    flush(500)
    eq(asked, 0, "a change after closing asks for nothing")

    -- ... also when the picker is left by a detour (D) and reopened: never two sets of handles
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    local watching = handles_of("fs_event")
    ok(watching > fs_base)
    p:focus("list")
    flush()
    keys("D")
    p = opened(3)
    eq(
      handles_of("fs_event"),
      watching,
      "the reopened dashboard has its own set, the old one is gone"
    )
    close_all()
    eq(handles_of("fs_event"), fs_base, "and that one is released too")
    reset_fixture()
    os.remove(root .. "/lib.nvim/ROADMAP/tasks/aaa.md")

    -- ── opt-out: `r` is the only way ──────────────────────────────────────
    dash.config.watch = false
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    eq(handles_of("fs_event"), fs_base, "watch = false: no handle at all")
    add("lib.nvim", "aaa", "Newcomer", "doing", { { "prio", "1" } })
    flush(600)
    eq(p:count(), 4, "nothing refreshes by itself")
    p:focus("list")
    flush()
    keys("<Tab>")
    local before_r = marked_ids(p)
    local cursor_r = assert(p:current()).task.id
    keys("r")
    p = opened(5)
    eq(ids(p)[1], "lib.nvim/aaa", "r picks the new task up")
    eq(marked_ids(p), before_r, "r keeps the marks")
    ok(
      wait_for(function()
        return p:current() ~= nil and p:current().task.id == cursor_r
      end),
      "and the cursor"
    )
    close_all()
    reset_fixture()
    os.remove(root .. "/lib.nvim/ROADMAP/tasks/aaa.md")

    -- the same through the call option, config on
    dash.config.watch = true
    dash.open(
      { tasks = {}, root = root, filter = {}, sort = "default" },
      { persist = false, watch = false }
    )
    opened(4)
    eq(handles_of("fs_event"), fs_base, "opts.watch = false wins over the config")
    close_all()

    -- ── a watcher that cannot start: one message, `r` still works ─────────
    dash.config.watch_opts = {
      start = function()
        return nil, "fs_event start failed (simulated)"
      end,
    }
    notes = {}
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    has(said(), "no live refresh")
    has(said(), "press r")
    eq(#vim.tbl_filter(function(n)
      return n.msg:find("no live refresh", 1, true) ~= nil
    end, notes), 1, "said once")
    eq(handles_of("fs_event"), fs_base, "nothing was left watching")
    add("lib.nvim", "aaa", "Newcomer", "doing", { { "prio", "1" } })
    p:focus("list")
    flush()
    keys("r")
    opened(5)
    close_all()
    dash.config.watch_opts = nil
    reset_fixture()
    os.remove(root .. "/lib.nvim/ROADMAP/tasks/aaa.md")

    -- ── a handle factory that RAISES: the picker stays the only window ─────
    -- (it used to take the picker down with it: the plain list opened on top of the open picker)
    local selects = 0
    vim.ui.select = function(_, _, cb)
      selects = selects + 1
      cb(nil)
    end
    dash.config.watch_opts = {
      start = function()
        error("handle factory exploded")
      end,
    }
    notes = {}
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    has(said(), "no live refresh")
    has(said(), "handle factory exploded")
    lacks(said(), "snacks picker failed")
    eq(selects, 0, "no plain list on top of the picker")
    eq(handles_of("fs_event"), fs_base, "nothing was left watching")
    close_all()
    dash.config.watch_opts = nil

    -- ... and a picker that closed before the watcher was started leaves no watcher behind
    local real_snacks = package.loaded["snacks"]
    package.loaded["snacks"] = {
      picker = setmetatable({}, {
        __call = function(_, opts)
          opts.on_close() -- closed at once: `on_close` finds no watcher to stop yet
          return { closed = true }
        end,
      }),
    }
    dash.open({ tasks = {}, root = root, filter = {}, sort = "default" }, { persist = false })
    package.loaded["snacks"] = real_snacks
    eq(handles_of("fs_event"), fs_base, "a picker closed on its own leaves no handle")
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end

    -- ── frecency: opening and changing a task feeds the sort ──────────────
    dash.config.watch = false
    frecency.set_path(H.tmpdir() .. "/frecency2.json")
    notes = {}
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    keys("j")
    keys("j")
    keys("j") -- the cursor is on the last task of the default order: cascade.nvim/delta
    local visited = assert(p:current()).task.id
    eq(visited, "cascade.nvim/delta")
    eq(vim.tbl_count(frecency.load()), 0, "nothing is recorded before something happens")
    keys("<CR>")
    flush()
    ok(current_picker() == nil, "<CR> opened the file and closed the picker")
    local entries = frecency.load()
    ok(entries[visited] ~= nil, "opening a task records a visit")
    eq(vim.tbl_count(entries), 1)
    vim.cmd("silent! %bwipeout!")

    -- `s` on another task records it too, and `o` x3 reaches the frecency order
    cmd.list({ flags = {}, args = {} })
    p = opened(4)
    p:focus("list")
    flush()
    keys("s") -- alpha: doing -> decision
    entries = frecency.load()
    ok(entries["lib.nvim/alpha"] ~= nil, "changing a task records a visit")
    local before = entries["lib.nvim/alpha"].score
    keys("s")
    ok(frecency.load()["lib.nvim/alpha"].score > before, "every change counts")
    reset_fixture()
    for _ = 1, 3 do
      keys("o")
    end
    ok(
      wait_for(function()
        return p.title:find("[sort: frecency]", 1, true) ~= nil
      end),
      "o reaches the frecency order"
    )
    p = opened(4)
    eq(ids(p)[1], "lib.nvim/alpha", "the most visited task is first")
    eq(ids(p)[2], "cascade.nvim/delta", "then the one opened once")
    eq(ids(p)[3], "cascade.nvim/gamma", "the rest in the default order")
    eq(ids(p)[4], "lib.nvim/beta")
    -- the sort is remembered like the others, and the cursor follows a task that jumps
    p:focus("list")
    flush()
    keys("G")
    flush()
    local last = assert(p:current()).task.id
    eq(last, "lib.nvim/beta")
    -- Every change is a visit: alpha has two, so beta needs three to pass it. The cursor must
    -- follow beta each time, or the next press would change another task.
    for n = 1, 3 do
      keys("p")
      ok(
        wait_for(function()
          local pp = current_picker()
          return pp ~= nil
            and not pp.finder.task:running()
            and pp:current() ~= nil
            and pp:current().task.id == "lib.nvim/beta"
        end),
        "the cursor stays on the changed task after press " .. n
      )
      flush(150)
    end
    eq(ids(assert(current_picker()))[1], "lib.nvim/beta", "three visits: beta climbed to the top")
    eq(
      require("tasks_nvim.scan").find("lib.nvim/alpha", { root = root }).prio,
      1,
      "only beta was changed"
    )
    close_all()
    lacks(said(), "error")
  end)
  restore()
  if not ok_run then
    error(err, 0)
  end
end
