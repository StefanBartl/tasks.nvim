-- TESTS/tasks_dash_watch_spec.lua -- the dashboard's file watcher (plugin_repos/tasks_dash_watch.lua):
-- which folders it watches, filtering of editor noise, the single debounce, quiet during the dashboard's own
-- batches (`hold`), clean stop, sync after a refresh, failure to start -- all against a fake handle factory,
-- a fake timer and a fake clock -- and then once against real `fs_event` handles in a temp vault.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local watch = require("tasks_nvim.ui.dash_watch")
  local uv = vim.uv or vim.loop

  local root = F.vault(H)

  ---@param area string
  ---@param slug string
  local function add(area, slug)
    return F.task(H, root, area, slug, F.meta("Task " .. slug, "open", {}))
  end

  ---@param list { path: string, only?: string }[]
  ---@return string[]
  local function rel(list)
    return vim.tbl_map(function(d)
      return d.path:sub(#root + 2) .. (d.only and ("|" .. d.only) or "")
    end, list)
  end

  -- ── relevant: editor droppings do not count ─────────────────────────────
  for _, name in ipairs({ "task.md", "folder-task", "sub/task.md", "\\0\\task.md", "x.md.bak" }) do
    ok(watch.relevant(name), name .. " matters")
  end
  ok(watch.relevant(nil), "an event without a name is assumed to matter")
  for _, name in ipairs({
    ".task.md.swp",
    ".task.md.swx",
    "task.md~",
    "4913",
    "task.md.tasks-tmp.123.456",
    "sub/.hidden",
  }) do
    ok(not watch.relevant(name), name .. " is noise")
  end

  -- ── dirs: what gets watched ─────────────────────────────────────────────
  eq(
    rel(watch.dirs(root, "lib.nvim")),
    { "lib.nvim/ROADMAP|tasks", "lib.nvim/Backlog/FEATURES", "lib.nvim/Backlog/TASKS" },
    "no tasks/ yet: ROADMAP is watched for it, plus the two Backlog buckets"
  )
  eq(
    rel(watch.dirs(root, "lib.nvim", { backlog = false })),
    { "lib.nvim/ROADMAP|tasks" },
    "backlog = false leaves the Backlog out"
  )
  add("lib.nvim", "alpha")
  add("cascade.nvim", "beta")
  H.write(root .. "/lib.nvim/ROADMAP/tasks/folder-task/folder-task.md", "---\n---\n")
  eq(rel(watch.dirs(root, "lib.nvim")), {
    "lib.nvim/ROADMAP/tasks",
    "lib.nvim/ROADMAP/tasks/folder-task",
    "lib.nvim/Backlog/FEATURES",
    "lib.nvim/Backlog/TASKS",
  }, "with tasks/: it and each folder-task folder, non-recursive")
  -- lib.nvim 4, cascade.nvim 3 (tasks/ + 2 buckets), ALL 2, nvim-config 2; migrate.nvim has neither
  eq(#watch.dirs(root, nil), 11, "all areas")
  local all = rel(watch.dirs(root, nil))
  ok(vim.tbl_contains(all, "cascade.nvim/ROADMAP/tasks"), "all: every area with tasks")
  ok(vim.tbl_contains(all, "lib.nvim/ROADMAP/tasks"))
  ok(vim.tbl_contains(all, "ALL/Backlog/TASKS"), "all: areas with a Backlog only are watched there")
  ok(vim.tbl_contains(all, "nvim-config/Backlog/FEATURES"))
  for _, p in ipairs(all) do
    ok(
      not p:find("TEMPLATES", 1, true) and not p:find("TOOLS", 1, true),
      "never the skipped folders: " .. p
    )
  end
  eq(watch.dirs(root, "no/such"), {}, "an invalid area name watches nothing")
  eq(watch.dirs(root, "nonexistent.nvim"), {}, "an area that is not there watches nothing")

  -- ── a fake backend ──────────────────────────────────────────────────────
  ---@class FakeWorld
  local function world(overrides)
    local w = { handles = {}, starts = {}, timers = {}, clock = 1000, refreshes = 0 }
    ---@param path string
    ---@param cb fun(path: string, filename: string|nil, events: table)
    w.start = function(path, cb, opts)
      w.starts[#w.starts + 1] = { path = path, opts = opts }
      if w.fail and w.fail(path) then
        return nil, "fs_event start failed for path: " .. path
      end
      local h = { path = path, cb = cb, stopped = 0 }
      h.stop = function()
        h.stopped = h.stopped + 1
      end
      w.handles[path] = h
      return h, nil
    end
    w.schedule = function(ms, fn)
      local t = { ms = ms, fn = fn, cancelled = false, fired = false }
      w.timers[#w.timers + 1] = t
      return function()
        t.cancelled = true
      end
    end
    w.now = function()
      return w.clock
    end
    ---Deliver a raw event on a watched folder.
    w.event = function(path, filename)
      local h = assert(w.handles[path], "not watched: " .. path)
      h.cb(path, filename, { change = true })
    end
    ---Run the pending (not cancelled) timers, as the loop would after the debounce.
    w.fire = function()
      local n = 0
      for _, t in ipairs(w.timers) do
        if not t.cancelled and not t.fired then
          t.fired = true
          t.fn()
          n = n + 1
        end
      end
      return n
    end
    w.pending = function()
      local n = 0
      for _, t in ipairs(w.timers) do
        if not t.cancelled and not t.fired then
          n = n + 1
        end
      end
      return n
    end
    w.new = function(opts)
      return watch.new(vim.tbl_extend("force", {
        root = root,
        area = "lib.nvim",
        on_refresh = function()
          w.refreshes = w.refreshes + 1
        end,
        start = w.start,
        schedule = w.schedule,
        now = w.now,
      }, opts or {}, overrides or {}))
    end
    return w
  end

  local tasks_dir = root .. "/lib.nvim/ROADMAP/tasks"

  -- start: one handle per folder, a short raw debounce for each
  local w = world()
  local d = w.new()
  eq(d:active(), false, "not started yet")
  eq({ d:start() }, { true })
  eq(d:active(), true)
  eq(d:count(), 4, "tasks/, folder-task/ and the two Backlog buckets")
  eq(
    w.starts[1].opts.debounce_ms,
    watch.DEFAULTS.raw_debounce_ms,
    "each handle debounces briefly itself"
  )
  eq({ d:start() }, { true }, "starting twice is harmless")
  eq(#w.starts, 4, "and starts nothing again")

  -- many events, one refresh
  w.event(tasks_dir, "a.md")
  w.event(tasks_dir, "b.md")
  w.event(root .. "/lib.nvim/Backlog/TASKS", "2026-10-04_c.md")
  w.event(tasks_dir .. "/folder-task", "folder-task.md")
  eq(w.pending(), 1, "events from four folders share one debounce timer")
  eq(w.timers[#w.timers].ms, watch.DEFAULTS.debounce_ms)
  eq(w.refreshes, 0, "nothing happens before the quiet period is over")
  eq(w.fire(), 1)
  eq(w.refreshes, 1, "one refresh for the burst")
  eq(w.fire(), 0, "and nothing left over")

  -- the debounce restarts on every event: only the last timer counts
  local before = #w.timers
  w.event(tasks_dir, "a.md")
  w.event(tasks_dir, "a.md")
  eq(#w.timers - before, 2)
  eq(w.pending(), 1, "the earlier timer was cancelled")
  w.fire()
  eq(w.refreshes, 2)

  -- noise is dropped before it arms anything
  w.event(tasks_dir, ".a.md.swp")
  w.event(tasks_dir, "4913")
  w.event(tasks_dir, "a.md~")
  eq(w.pending(), 0, "swap files, probes and backups arm nothing")
  w.event(tasks_dir, nil)
  eq(w.pending(), 1, "an event without a name does")
  w.fire()
  eq(w.refreshes, 3)

  -- a refresh that throws does not stop the watcher
  local boom = world()
  local bd = boom.new({
    on_refresh = function()
      boom.refreshes = boom.refreshes + 1
      error("render failed")
    end,
  })
  bd:start()
  boom.event(tasks_dir, "a.md")
  boom.fire()
  boom.event(tasks_dir, "a.md")
  eq(boom.fire(), 1, "still watching after a failed refresh")
  eq(boom.refreshes, 2)
  bd:stop()

  -- ── hold: the dashboard's own writes are not echoed back ────────────────
  w.event(tasks_dir, "a.md") -- a refresh is pending ...
  eq(w.pending(), 1)
  local r1, r2 = d:hold(function()
    -- ... and the dashboard writes: events during the batch are dropped
    w.event(tasks_dir, "a.md")
    return "x", "y"
  end)
  eq({ r1, r2 }, { "x", "y" }, "hold returns what the batch returns")
  eq(w.pending(), 0, "the pending refresh is cancelled: the caller rescans right after the batch")
  w.clock = w.clock + 100
  w.event(tasks_dir, "a.md")
  eq(w.pending(), 0, "the echo of the batch's writes shortly after it is dropped too")
  w.clock = w.clock + watch.DEFAULTS.mute_ms + 1
  w.event(tasks_dir, "a.md")
  eq(w.pending(), 1, "later changes count again")
  w.fire()
  local refreshes = w.refreshes

  -- an error in the batch is re-raised, the watcher is back to normal
  local hok, herr = pcall(function()
    d:hold(function()
      error("batch failed", 0)
    end)
  end)
  eq(hok, false)
  eq(herr, "batch failed")
  eq(d.held, false, "held is released after an error")
  w.clock = w.clock + watch.DEFAULTS.mute_ms + 1
  w.event(tasks_dir, "a.md")
  eq(w.pending(), 1)
  w.fire()
  eq(w.refreshes, refreshes + 1)

  -- nested hold: only the outermost ends the batch
  d:hold(function()
    d:hold(function() end)
    ok(d.held, "still held inside the outer batch")
  end)
  eq(d.held, false)

  -- ── stop: nothing left running ──────────────────────────────────────────
  w.clock = w.clock + watch.DEFAULTS.mute_ms + 1
  w.event(tasks_dir, "a.md")
  eq(w.pending(), 1)
  d:stop()
  eq(d:active(), false)
  eq(d:count(), 0, "no handle kept")
  eq(w.pending(), 0, "the pending timer is cancelled")
  for path, h in pairs(w.handles) do
    eq(h.stopped, 1, "handle stopped exactly once: " .. path)
  end
  local at_stop = w.refreshes
  for _, t in ipairs(w.timers) do
    if t.cancelled and not t.fired then
      t.fn() -- a timer callback that was already queued when stop ran
    end
  end
  w.event(tasks_dir, "a.md")
  eq(w.pending(), 0, "events after stop arm nothing")
  eq(w.refreshes, at_stop, "and a queued timer callback does nothing")
  d:stop()
  for _, h in pairs(w.handles) do
    eq(h.stopped, 1, "stop twice does not close twice")
  end

  -- ── ROADMAP-only watch, and sync after a refresh ────────────────────────
  local fresh_root = H.tmpdir() .. "/vault"
  H.write(fresh_root .. "/p.nvim/ROADMAP/ROADMAP.md", "# R\n")
  local sw = world()
  local sd = sw.new({ root = fresh_root, area = "p.nvim", backlog = false })
  eq({ sd:start() }, { true })
  eq(sd:count(), 1, "ROADMAP only: waiting for tasks/ to appear")
  local roadmap = fresh_root .. "/p.nvim/ROADMAP"
  sw.event(roadmap, "TASKS.md")
  sw.event(roadmap, "ROADMAP.md")
  eq(sw.pending(), 0, "the index and the ROADMAP.md arm nothing")
  H.write(roadmap .. "/tasks/first.md", "x")
  sw.event(roadmap, "tasks")
  eq(sw.pending(), 1, "the tasks folder appearing does")
  sw.event(roadmap, "\\0\\tasks")
  eq(sw.pending(), 1, "a Windows folder prefix on the name is ignored")
  sw.fire()
  eq(sw.refreshes, 1)
  ok(sw.handles[roadmap .. "/tasks"] ~= nil, "after the refresh tasks/ is watched")
  eq(sw.handles[roadmap].stopped, 1, "and the ROADMAP handle is released")
  eq(sd:count(), 1)
  -- a folder task appears: its folder gets a handle at the next refresh; a vanished one is released
  H.write(roadmap .. "/tasks/ft/ft.md", "x")
  sw.event(roadmap .. "/tasks", "ft")
  sw.fire()
  ok(sw.handles[roadmap .. "/tasks/ft"] ~= nil, "a new folder task is watched")
  eq(sd:count(), 2)
  vim.fn.delete(roadmap .. "/tasks/ft", "rf")
  sw.event(roadmap .. "/tasks", "ft")
  sw.fire()
  eq(sw.handles[roadmap .. "/tasks/ft"].stopped, 1, "a vanished folder is released")
  eq(sd:count(), 1)
  sd:stop()

  -- lib.nvim.fs.watch debounces per handle and reports only the LAST name of a burst: the first task
  -- of an area is `tasks`, then (a few ms later) `TASKS.md`. Waiting for tasks/ must not hang on the name.
  H.write(fresh_root .. "/q.nvim/ROADMAP/ROADMAP.md", "# R\n")
  local qw = world()
  local qd = qw.new({ root = fresh_root, area = "q.nvim", backlog = false })
  eq({ qd:start() }, { true })
  local q_roadmap = fresh_root .. "/q.nvim/ROADMAP"
  qw.event(q_roadmap, "TASKS.md")
  eq(qw.pending(), 0, "no tasks/ yet: an index event arms nothing")
  H.write(q_roadmap .. "/tasks/first.md", "x")
  qw.event(q_roadmap, "TASKS.md")
  eq(qw.pending(), 1, "tasks/ is there now: the burst counts although its last name was TASKS.md")
  qw.fire()
  ok(qw.handles[q_roadmap .. "/tasks"] ~= nil, "and the refresh aims a handle at tasks/")
  qd:stop()

  -- ── start failures ──────────────────────────────────────────────────────
  local fw = world()
  fw.fail = function()
    return true
  end
  local fd = fw.new()
  local started, err = fd:start()
  eq(started, false, "nothing could be watched")
  ok(err and err:find("fs_event start failed", 1, true), "the reason is reported")
  eq(fd:active(), false, "a failed start leaves nothing active")
  eq(fd:count(), 0)

  local pw = world()
  pw.fail = function(path)
    return path:find("Backlog/TASKS", 1, true) ~= nil
  end
  local pd = pw.new()
  eq({ pd:start() }, { true }, "some folders failing is not a failure")
  eq(pd:count(), 3)
  eq(pd.partial.started, 3)
  eq(pd.partial.wanted, 4)
  ok(pd.partial.err:find("Backlog/TASKS", 1, true))
  pd:stop()

  local nw = world()
  local nd = nw.new({ root = fresh_root, area = "nonexistent.nvim" })
  eq({ nd:start() }, { true }, "nothing to watch is not a failure either")
  eq(nd:count(), 0)
  nd:stop()

  -- the default handle factory reports a missing lib.nvim.fs.watch instead of raising
  local saved = package.loaded["lib.nvim.fs.watch"]
  package.loaded["lib.nvim.fs.watch"] = nil
  local saved_preload = package.preload["lib.nvim.fs.watch"]
  package.preload["lib.nvim.fs.watch"] = function()
    error("module gone")
  end
  local dd = watch.new({ root = root, area = "lib.nvim", on_refresh = function() end })
  local dstarted, derr = dd:start()
  package.preload["lib.nvim.fs.watch"] = saved_preload
  package.loaded["lib.nvim.fs.watch"] = saved
  eq(dstarted, false)
  ok(derr and derr:find("not available", 1, true), "reported, not raised: " .. tostring(derr))

  -- ── real fs_event handles ───────────────────────────────────────────────
  ---@param kind string
  ---@return integer
  local function handles_of(kind)
    vim.wait(50, function()
      return false
    end)
    local n = 0
    uv.walk(function(h)
      if h:get_type() == kind and not h:is_closing() then
        n = n + 1
      end
    end)
    return n
  end

  local real_root = H.tmpdir() .. "/real"
  local function real_task(slug)
    return F.task(H, real_root, "lib.nvim", slug, F.meta("Task " .. slug, "open", {}))
  end
  real_task("one")
  H.write(real_root .. "/lib.nvim/Backlog/README.md", "# B\n")
  vim.fn.mkdir(real_root .. "/lib.nvim/Backlog/TASKS", "p")

  local fs_before, timers_before = handles_of("fs_event"), handles_of("timer")
  local seen = 0
  local rw = watch.new({
    root = real_root,
    area = "lib.nvim",
    debounce_ms = 60,
    on_refresh = function()
      seen = seen + 1
    end,
  })
  eq({ rw:start() }, { true })
  eq(rw:count(), 2, "tasks/ and Backlog/TASKS")
  eq(handles_of("fs_event"), fs_before + 2, "two real fs_event handles")

  ---Change something until the watcher reports it (a backend may need a moment to be live).
  ---@param n integer  # refreshes to wait for
  ---@param touch fun(i: integer)
  local function until_seen(n, touch)
    local i = 0
    local done = vim.wait(5000, function()
      if seen >= n then
        return true
      end
      i = i + 1
      touch(i)
      vim.wait(120, function()
        return seen >= n
      end, 10)
      return seen >= n
    end, 20)
    ok(done, "the watcher reported the change (seen " .. seen .. ")")
  end

  until_seen(1, function(i)
    H.write(real_root .. "/lib.nvim/ROADMAP/tasks/new-" .. i .. ".md", "x")
  end)
  local after_first = seen
  -- a task moves to the Backlog
  until_seen(after_first + 1, function(i)
    H.write(real_root .. "/lib.nvim/Backlog/TASKS/done-" .. i .. ".md", "x")
  end)
  -- a folder task, then a change inside it: the folder is picked up by the sync after the first refresh
  H.write(real_root .. "/lib.nvim/ROADMAP/tasks/ft/ft.md", "x")
  vim.wait(600, function()
    return rw:count() >= 3
  end, 20)
  ok(rw:count() >= 3, "the new folder-task folder got its own handle")
  local after_folder = seen
  until_seen(after_folder + 1, function(i)
    H.write(real_root .. "/lib.nvim/ROADMAP/tasks/ft/ft.md", "x" .. i)
  end)

  -- stop: no handle, no timer left, no late refresh
  rw:stop()
  eq(rw:count(), 0)
  eq(handles_of("fs_event"), fs_before, "every fs_event handle is closed")
  -- <=, not ==: a timer of an earlier spec (a debounce still running when this spec began) may close meanwhile.
  ok(handles_of("timer") <= timers_before, "and no timer is left")
  local at_end = seen
  H.write(real_root .. "/lib.nvim/ROADMAP/tasks/after-stop.md", "x")
  vim.wait(500, function()
    return false
  end)
  eq(seen, at_end, "nothing is reported after stop")
  rw:stop()

  -- ── real handles: the first task of an area that has no tasks/ yet ───────
  -- `mutate.new` makes tasks/, the task file, then ROADMAP/TASKS.md: the burst on the ROADMAP handle
  -- ends on `TASKS.md`. A name filter dropped it, and the dashboard never noticed the first task.
  local first_root = F.vault(H)
  local first_seen = 0
  local first_w = watch.new({
    root = first_root,
    area = "cascade.nvim",
    debounce_ms = 60,
    on_refresh = function()
      first_seen = first_seen + 1
    end,
  })
  eq({ first_w:start() }, { true })
  eq(first_w:count(), 3, "ROADMAP (waiting for tasks/) and the two Backlog buckets")
  local made = 0
  local noticed = vim.wait(5000, function()
    if first_seen >= 1 then
      return true
    end
    made = made + 1
    local r, merr = require("tasks_nvim.mutate").new(
      "cascade.nvim",
      { title = "First task " .. made, root = first_root }
    )
    ok(r, merr)
    vim.wait(250, function()
      return first_seen >= 1
    end, 10)
    return first_seen >= 1
  end, 20)
  ok(noticed, "the watcher noticed a task created in an area without tasks/ (after " .. made .. ")")
  ok(
    vim.wait(1000, function()
      return first_w.handles[first_root .. "/cascade.nvim/ROADMAP/tasks"] ~= nil
    end, 20),
    "and the refresh aimed a handle at the new tasks/ folder"
  )
  first_w:stop()
end
