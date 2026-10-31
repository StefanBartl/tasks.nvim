-- TESTS/tasks_staleness_async_spec.lua -- `--stale=refs` without blocking the editor: `staleness.compute_async` and
-- `git_dates_async` (git answers held back by a stubbed spawn: nothing waits for them), the chunk halving, the
-- deadline, cancel and fail-open of the async path, and the dashboard that shows the list first and redraws it when
-- the background check answers.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body; specs replace module functions with test doubles.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local staleness = require("tasks_nvim.staleness")
  local scan = require("tasks_nvim.scan")
  local uv = vim.uv or vim.loop

  local have_git = vim.fn.executable("git") == 1

  local root = F.vault(H)
  local top = H.tmpdir()
  local repos = top .. "/repos"
  local lib_repo = repos .. "/lib.nvim"
  local cfg = top .. "/cfg"
  vim.fn.mkdir(cfg, "p")
  vim.fn.mkdir(lib_repo, "p")

  ---@param args string[]
  ---@param date? string
  local function git(args, date)
    local cmd = { "git", "-C", lib_repo, "-c", "user.name=t", "-c", "user.email=t@example.org" }
    vim.list_extend(cmd, args)
    local env = date and { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } or nil
    local res = vim.system(cmd, { text = true, env = env }):wait()
    eq(res.code, 0, "git " .. table.concat(args, " ") .. ": " .. tostring(res.stderr))
  end
  ---@param rel string
  ---@param text string
  ---@param date string
  local function commit(rel, text, date)
    H.write(lib_repo .. "/" .. rel, text)
    git({ "add", "--", rel })
    git({ "commit", "-q", "-m", "touch " .. rel }, date)
  end
  if have_git then
    git({ "init", "-q" })
    commit("lua/a.lua", "return 1\n", "2026-09-01T12:00:00")
    commit("lua/b.lua", "return 2\n", "2026-09-01T12:00:00")
    commit("lua/a.lua", "return 11\n", "2026-10-01T12:00:00")
  else
    H.write(lib_repo .. "/lua/a.lua", "x\n")
    H.write(lib_repo .. "/lua/b.lua", "x\n")
  end
  H.write(cfg .. "/docs/x.md", "x\n")

  ---@param slug string
  ---@param updated string
  ---@param refs string[]
  local function add(slug, updated, refs)
    F.task(
      H,
      root,
      "lib.nvim",
      slug,
      F.meta(slug, "open", {
        { "created", updated },
        { "updated", updated },
        { "refs", "[" .. table.concat(refs, ", ") .. "]" },
      })
    )
  end
  add("stale-git", "2026-09-15", { "lua/a.lua" })
  add("fresh", "2026-09-15", { "lua/b.lua" })
  add("config-file", "2026-09-15", { "docs/x.md" })
  local tasks = assert(scan.area("lib.nvim", { root = root }))
  ---@type Tasks.StalenessOpts
  local opts = { root = root, repo_bases = { repos }, config_dir = cfg }

  ---@param map table<string, any>
  ---@return string[]
  local function ids(map)
    local out = vim.tbl_keys(map)
    table.sort(out)
    return out
  end

  -- ── git through the non-blocking spawn, its answers held back ───────────
  local orig_spawn = staleness.spawn
  local spawned = 0
  ---@type fun()[]
  local held = {}
  local function hold_git()
    spawned, held = 0, {}
    staleness.spawn = function(cmd, sopts, on_exit)
      spawned = spawned + 1
      return orig_spawn(cmd, sopts, function(res)
        held[#held + 1] = function()
          on_exit(res)
        end
      end)
    end
  end
  local function release_all()
    while #held > 0 do
      table.remove(held, 1)()
    end
  end

  if have_git then
    staleness.reset_cache()
    local sync = staleness.compute(tasks, opts)
    eq(ids(sync.stale), { "lib.nvim/config-file", "lib.nvim/stale-git" }, "the blocking path")

    staleness.reset_cache()
    hold_git()
    local got
    local t0 = uv.hrtime()
    local job = staleness.compute_async(tasks, opts, function(r)
      got = r
    end)
    local took_ms = (uv.hrtime() - t0) / 1e6
    ok(type(job) == "table" and type(job.cancel) == "function", "a job comes back")
    eq(got, nil, "the answer never comes before compute_async returned")
    ok(took_ms < 2000, "compute_async returns without waiting for git (" .. took_ms .. " ms)")
    -- git has answered, but its answer is held back: nothing in the check may wait for it
    ok(
      vim.wait(10000, function()
        return #held > 0
      end, 5),
      "the git lookup runs through the non-blocking spawn"
    )
    eq(got, nil, "no report while a git answer is outstanding")
    ok(spawned >= 1, "git was started through staleness.spawn")
    ok(
      vim.wait(20000, function()
        release_all()
        return got ~= nil
      end, 5),
      "the report arrives once git answered"
    )
    eq(ids(got.stale), ids(sync.stale), "the same answer as the blocking path")
    eq(got.stale["lib.nvim/stale-git"][1].source, "git")
    eq(got.stale["lib.nvim/stale-git"][1].date, "2026-10-01")
    eq(got.stale["lib.nvim/config-file"][1].source, "mtime", "a non-git base falls back to mtime")
    eq({ got.tasks, got.files }, { sync.tasks, sync.files })
    has(table.concat(got.notes, "\n"), "not a git repository", "the notes are the same")

    -- one path git refuses: the chunk is halved, the other path keeps its git date
    staleness.reset_cache()
    hold_git()
    local dates, derr
    local done = false
    staleness.git_dates_async(lib_repo, { "lua/a.lua", "../outside.lua" }, nil, function(d, e)
      dates, derr, done = d, e, true
    end)
    ok(
      vim.wait(20000, function()
        release_all()
        return done
      end, 5),
      "the halving finishes"
    )
    eq(dates["lua/a.lua"].date, "2026-10-01", "the good path is dated by git")
    eq(dates["../outside.lua"], nil)
    has(derr, "1 path(s) not dated by git")
    ok(spawned >= 4, "whole chunk, the repo probe and both halves (" .. spawned .. " spawns)")
    local sync_dates, sync_err = staleness.git_dates(lib_repo, { "lua/a.lua", "../outside.lua" })
    eq(dates, sync_dates, "the same dates as the blocking lookup")
    eq(derr, sync_err)

    -- a folder that is no repository: remembered, like the blocking path does
    staleness.reset_cache()
    hold_git()
    done = false
    staleness.git_dates_async(cfg, { "docs/x.md" }, nil, function(d, e)
      dates, derr, done = d, e, true
    end)
    ok(vim.wait(20000, function()
      release_all()
      return done
    end, 5))
    eq(dates, nil)
    eq(derr, "not a git repository")
    staleness.spawn = orig_spawn
  end

  -- ── the deadline, cancel and fail-open, without git ─────────────────────
  staleness.reset_cache()
  hold_git()
  local dates, derr
  staleness.git_dates_async(
    lib_repo,
    { "lua/a.lua" },
    { deadline = uv.hrtime() - 1 },
    function(d, e)
      dates, derr = d, e
    end
  )
  ok(vim.wait(5000, function()
    return derr ~= nil
  end, 5))
  eq(spawned, 0, "after the deadline no git call is started")
  eq(dates, {})
  has(derr, "time budget used up")
  staleness.spawn = orig_spawn

  -- an empty list answers too (on the loop, never inline)
  local answered = false
  staleness.git_dates_async(lib_repo, {}, nil, function()
    answered = true
  end)
  eq(answered, false, "never before git_dates_async returned")
  ok(vim.wait(2000, function()
    return answered
  end, 5))

  -- an async stub: the dater holds its answer; cancel drops the run
  local pending = {}
  local stub = function(_, rels, _, cb)
    pending[#pending + 1] = function()
      local out = {}
      for _, rel in ipairs(rels) do
        out[rel] = { date = "2030-01-01", file = rel }
      end
      cb(out, nil)
    end
  end
  local cancelled_got = nil
  local job = staleness.compute_async(
    tasks,
    vim.tbl_extend("force", opts, { git_dates_async = stub }),
    function(r)
      cancelled_got = r
    end
  )
  job.cancel()
  while #pending > 0 do
    table.remove(pending, 1)()
  end
  vim.wait(100)
  eq(cancelled_got, nil, "a cancelled check never calls back")

  -- a synchronous `git_dates` stub (what the existing specs inject) is called from the loop
  local got_sync_stub
  staleness.compute_async(
    tasks,
    vim.tbl_extend("force", opts, {
      git_dates = function(_, rels)
        local out = {}
        for _, rel in ipairs(rels) do
          out[rel] = { date = "2030-01-01", file = rel }
        end
        return out
      end,
    }),
    function(r)
      got_sync_stub = r
    end
  )
  ok(vim.wait(5000, function()
    return got_sync_stub ~= nil
  end, 5))
  eq(ids(got_sync_stub.stale), {
    "lib.nvim/config-file",
    "lib.nvim/fresh",
    "lib.nvim/stale-git",
  })

  -- a dater that raises: fail open, every task with refs kept as unverified
  local got_err
  staleness.compute_async(
    tasks,
    vim.tbl_extend("force", opts, {
      git_dates_async = function()
        error("dater exploded")
      end,
    }),
    function(r)
      got_err = r
    end
  )
  ok(vim.wait(5000, function()
    return got_err ~= nil
  end, 5))
  has(got_err.notes[1], "dater exploded")
  eq(got_err.stale["lib.nvim/fresh"][1].source, "unverified")

  -- ── the dashboard: the list first, the refs answer redraws it ──────────
  do
    local dash = require("tasks_nvim.ui.dash")
    local was_watch = dash.config.watch
    dash.config.watch = false
    local orig_notify = vim.notify
    local said = {}
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    pending = {}
    local partial = function(_, rels, _, cb)
      pending[#pending + 1] = function()
        local out = {}
        for _, rel in ipairs(rels) do
          -- only a.lua changed after the tasks' date
          out[rel] = { date = rel == "lua/a.lua" and "2030-01-01" or "2000-01-01", file = rel }
        end
        cb(out, nil)
      end
    end
    local filter = {
      stale_refs = true,
      ref_opts = vim.tbl_extend("force", opts, { git_dates_async = partial }),
    }
    local t0 = uv.hrtime()
    local state = dash.open(
      { root = root, area = "lib.nvim", filter = filter },
      { backend = "kit", persist = false }
    )
    local took_ms = (uv.hrtime() - t0) / 1e6
    ok(state ~= nil, "the dashboard opened")
    ok(took_ms < 5000, "opening did not wait for the refs check (" .. took_ms .. " ms)")
    local results
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "lib-kit-picker-results" and vim.api.nvim_buf_is_loaded(buf) then
        results = buf
      end
    end
    ok(results ~= nil, "the kit picker opened")
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(results, 0, -1, false), "\n")
    end
    ok(state.ref_job ~= nil, "the refs check runs in the background")
    has(text(), "fresh", "before the answer: every task the other filters keep")
    has(text(), "stale-git")
    has(table.concat(said, "\n"), "checking the refs in the background")
    ok(
      vim.wait(5000, function()
        return #pending > 0
      end, 5),
      "the check asked its dater"
    )
    while #pending > 0 do
      table.remove(pending, 1)()
    end
    ok(
      vim.wait(5000, function()
        return state.ref_stale ~= nil and not text():find("fresh", 1, true)
      end, 5),
      "the answer redraws the list: " .. text()
    )
    has(text(), "stale-git", "the stale task stays")
    eq(state.ref_job, nil, "the redraw did not start another check")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
    vim.cmd("stopinsert")
    vim.notify = orig_notify
    dash.config.watch = was_watch
  end
end
