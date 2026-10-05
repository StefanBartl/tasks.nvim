-- TESTS/tasks_staleness_spec.lua -- `--stale=refs`: tasks.staleness (ref classification, resolution,
-- git and mtime dating, caps), the filter option, the CLI `list --stale-refs` and the dashboard filter state.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local staleness = require("tasks_nvim.staleness")
  local model = require("tasks_nvim.model")
  local uv = vim.uv or vim.loop

  -- ── classify ────────────────────────────────────────────────────────────
  ---@param ref string
  ---@param kind string
  ---@param rel? string
  local function classified(ref, kind, rel)
    local k, r = staleness.classify(ref)
    eq(k, kind, "kind of " .. ref)
    if rel then
      eq(r, rel, "path of " .. ref)
    end
  end
  classified("lua/ai/config/init.lua", "path", "lua/ai/config/init.lua")
  classified("  docs/a.md  ", "path", "docs/a.md")
  classified("lua\\ai\\init.lua", "path", "lua/ai/init.lua")
  classified("./README.md", "path", "README.md")
  classified("docs/ROADMAP/reports/", "path", "docs/ROADMAP/reports")
  classified("lua/a.lua:42", "path", "lua/a.lua")
  classified("docs/a.md#heading", "path", "docs/a.md")
  classified("C:\\repos\\x\\a.lua", "path", "C:/repos/x/a.lua")
  classified("lib.nvim@803de65", "skip")
  classified("filetree.nvim:cheatsheet-paged", "skip")
  classified("https://example.org/x", "skip")
  classified("", "skip")
  classified("   ", "skip")
  eq((staleness.classify(42)), "skip", "a non-string is skipped")

  -- ── fixture: a vault, a git repo per area, a non-git config dir ─────────
  local root = F.vault(H)
  local top = H.tmpdir()
  local repos = top .. "/repos"
  local cfg = top .. "/cfg"
  local lib_repo = repos .. "/lib.nvim"
  vim.fn.mkdir(cfg, "p")

  local have_git = vim.fn.executable("git") == 1

  ---@param args string[]
  ---@param date string|nil  `YYYY-MM-DDTHH:MM:SS` local time for the commit
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

  vim.fn.mkdir(lib_repo, "p")
  if have_git then
    git({ "init", "-q" })
    commit("lua/a.lua", "return 1\n", "2026-09-01T12:00:00")
    commit("lua/b.lua", "return 2\n", "2026-09-01T12:00:00")
    commit("lua/sub/c.lua", "return 3\n", "2026-09-01T12:00:00")
    -- a.lua and sub/c.lua change again on 2026-10-01; b.lua stays at 2026-09-01
    commit("lua/a.lua", "return 11\n", "2026-10-01T12:00:00")
    commit("lua/sub/c.lua", "return 33\n", "2026-10-01T12:00:00")
  else
    for _, rel in ipairs({ "lua/a.lua", "lua/b.lua", "lua/sub/c.lua" }) do
      H.write(lib_repo .. "/" .. rel, "x\n")
    end
  end
  -- untracked file in the repo: dated by its mtime (2026-10-05)
  H.write(lib_repo .. "/notes.txt", "n\n")
  local day = 86400
  local t_oct5 = os.time({ year = 2026, month = 10, day = 5, hour = 12 })
  uv.fs_utime(lib_repo .. "/notes.txt", t_oct5, t_oct5)
  -- a file of the (non-git) config dir
  H.write(cfg .. "/docs/x.md", "x\n")
  uv.fs_utime(cfg .. "/docs/x.md", t_oct5, t_oct5)
  -- the same relative name in the repo and in the vault: the repo wins
  H.write(lib_repo .. "/README.md", "repo\n")
  uv.fs_utime(lib_repo .. "/README.md", t_oct5 - 30 * day, t_oct5 - 30 * day)
  H.write(root .. "/README.md", "vault\n")
  uv.fs_utime(root .. "/README.md", t_oct5, t_oct5)

  local function meta(title, updated, refs)
    local m = F.meta(title, "open")
    if updated then
      m[#m + 1] = { "created", updated }
      m[#m + 1] = { "updated", updated }
    end
    if refs then
      m[#m + 1] = { "refs", "[" .. table.concat(refs, ", ") .. "]" }
    end
    return m
  end
  local scan = require("tasks_nvim.scan")
  local function add(slug, updated, refs)
    F.task(H, root, "lib.nvim", slug, meta(slug, updated, refs))
  end
  add("stale-git", "2026-09-15", { "lua/a.lua" })
  add("fresh-after", "2026-10-02", { "lua/a.lua" })
  add("old-file", "2026-09-15", { "lua/b.lua" })
  add("dir-ref", "2026-09-15", { "lua/sub" })
  add("backslash", "2026-09-15", { "lua\\a.lua" })
  add("line-suffix", "2026-09-15", { "lua/a.lua:7" })
  add("mtime-untracked", "2026-10-01", { "notes.txt" })
  add("config-file", "2026-09-30", { "docs/x.md" })
  add("repo-wins", "2026-10-01", { "README.md" })
  add("noise-only", "2026-09-15", { "lib.nvim@803de65", "https://x.org", "filetree.nvim:anchor" })
  add("missing-file", "2026-09-15", { "lua/gone.lua" })
  add("undated", nil, { "lua/a.lua" })
  add("no-refs", "2026-09-15", nil)
  add("two-changed", "2026-09-15", { "lua/a.lua", "lua/b.lua", "lua/sub/c.lua" })

  local tasks = assert(scan.area("lib.nvim", { root = root }))
  ---@type Tasks.StalenessOpts
  local opts = { root = root, repo_bases = { repos }, config_dir = cfg }

  local function ids(map)
    local out = vim.tbl_keys(map)
    table.sort(out)
    return out
  end

  -- ── real git ────────────────────────────────────────────────────────────
  if have_git then
    staleness.reset_cache()
    local rep = staleness.compute(tasks, opts)
    eq(ids(rep.stale), {
      "lib.nvim/backslash",
      "lib.nvim/config-file",
      "lib.nvim/dir-ref",
      "lib.nvim/line-suffix",
      "lib.nvim/mtime-untracked",
      "lib.nvim/stale-git",
      "lib.nvim/two-changed",
      "lib.nvim/undated",
    }, "which tasks are stale by refs")
    local c = rep.stale["lib.nvim/stale-git"][1]
    eq(c.ref, "lua/a.lua")
    eq(c.date, "2026-10-01")
    eq(c.source, "git")
    eq(c.file, lib_repo .. "/lua/a.lua", "the changed file is named with its full path")
    eq(
      rep.stale["lib.nvim/dir-ref"][1].file,
      lib_repo .. "/lua/sub/c.lua",
      "a directory ref names the file inside"
    )
    eq(
      rep.stale["lib.nvim/backslash"][1].file,
      lib_repo .. "/lua/a.lua",
      "a backslash ref resolves"
    )
    eq(
      rep.stale["lib.nvim/mtime-untracked"][1].source,
      "mtime",
      "an untracked file falls back to mtime"
    )
    eq(rep.stale["lib.nvim/config-file"][1].source, "mtime", "a file of a non-git base uses mtime")
    eq(
      #rep.stale["lib.nvim/two-changed"],
      2,
      "b.lua did not change after updated; a.lua and sub/c.lua did"
    )
    ok(rep.unresolved >= 1, "the missing file is counted, not fatal")
    ok(rep.skipped >= 3, "commit, URL and anchor are skipped")
    ok(
      not rep.stale["lib.nvim/repo-wins"],
      "README.md resolved to the repo's old file, not the vault's new one"
    )
    local joined = table.concat(rep.notes, "\n")
    has(joined, "not a git repository", "the non-git base is mentioned")
    ok(staleness.last == nil, "there is no module-level report any more: the filter hands it back")
    has(staleness.describe(rep.stale["lib.nvim/stale-git"]), "lua/a.lua (2026-10-01, git)")
    has(staleness.describe(rep.stale["lib.nvim/two-changed"], 1), "+1 more")
  end

  -- ── fake git: batching, cap, no repo, failures ──────────────────────────
  local calls = {}
  local fake = function(base, rels)
    calls[#calls + 1] = { base = base, rels = vim.deepcopy(rels) }
    local out = {}
    for _, rel in ipairs(rels) do
      out[rel] = { date = "2030-01-01", file = rel }
    end
    return out
  end
  staleness.reset_cache()
  local rep = staleness.compute(tasks, vim.tbl_extend("force", opts, { git_dates = fake }))
  local per_base = {}
  for _, call in ipairs(calls) do
    per_base[call.base] = (per_base[call.base] or 0) + 1
  end
  eq(per_base[lib_repo], 1, "one git lookup per repo, however many tasks and refs")
  local seen = {}
  for _, rel in ipairs(calls[1] and calls[1].rels or {}) do
    ok(not seen[rel], "a file is looked up once (" .. rel .. ")")
    seen[rel] = true
  end
  ok(rep.stale["lib.nvim/old-file"], "the fake says every file changed in 2030")
  ok(
    rep.stale["lib.nvim/undated"],
    "a task without a date counts as stale (like --stale=N): an unknowable answer is not fresh"
  )
  ok(not rep.stale["lib.nvim/noise-only"], "commits, URLs and anchors are no files")

  -- the cap
  calls = {}
  rep = staleness.compute(tasks, vim.tbl_extend("force", opts, { git_dates = fake, max_refs = 2 }))
  eq(rep.files, 2, "at most max_refs distinct files are looked at")
  ok(rep.capped > 0, "the rest is counted")
  has(table.concat(rep.notes, "\n"), "beyond the limit of 2")

  -- git unavailable or failing: mtime, plus a note, never an error
  rep = staleness.compute(
    tasks,
    vim.tbl_extend("force", opts, {
      git_dates = function()
        return nil, "git exploded"
      end,
    })
  )
  has(table.concat(rep.notes, "\n"), "git exploded")
  eq(
    rep.stale["lib.nvim/mtime-untracked"][1].source,
    "mtime",
    "file times take over when git fails"
  )

  -- no base holds the repo: every ref is "found nowhere", nothing raises
  rep = staleness.compute(tasks, {
    root = root,
    repo_bases = { top .. "/nowhere" },
    config_dir = top .. "/nope",
    git_dates = fake,
  })
  ok(rep.unresolved >= 1)
  eq(rep.tasks >= 0, true)

  -- a vault that does not exist
  local ok_call, empty =
    pcall(staleness.compute, tasks, { root = top .. "/no-vault", git_dates = fake })
  ok(ok_call and type(empty.stale) == "table", "a missing vault root does not raise")

  -- ── model.filter ────────────────────────────────────────────────────────
  local from, ferr = model.filter_from_options({ stale = "refs" })
  eq(ferr, nil)
  ok(from and from.stale_refs and not from.stale, "--stale=refs is the refs mode, not a day count")
  from = assert(model.filter_from_options({ stale = "30", stale_refs = true }))
  eq(from.stale, 30)
  ok(from.stale_refs, "days and refs combine")
  local bad, berr = model.filter_from_options({ stale = "soon" })
  eq(bad, nil)
  has(berr, "refs")

  local f = assert(model.filter_from_options({ stale = "refs" }))
  f.ref_opts = vim.tbl_extend("force", opts, { git_dates = fake })
  local kept = model.filter(tasks, f)
  ok(#kept > 0 and #kept < #tasks, "refs filter keeps only tasks with changed refs")
  for _, t in ipairs(kept) do
    ok(#t.refs > 0, t.id .. " has refs")
  end
  -- an injected answer wins over any lookup
  local f2 = {
    stale_refs = true,
    ref_stale = { ["lib.nvim/no-refs"] = { { ref = "x", file = "x", date = "d", source = "git" } } },
  }
  eq(
    vim.tbl_map(function(t)
      return t.id
    end, model.filter(tasks, f2)),
    { "lib.nvim/no-refs" }
  )

  -- ── CLI ─────────────────────────────────────────────────────────────────
  if have_git then
    local old_repos, old_cfg = vim.env.REPOS_DIR, vim.env.NVIM_CONFIG_DIR
    vim.env.REPOS_DIR, vim.env.NVIM_CONFIG_DIR = repos, cfg
    -- lib.nvim.system.env memoises its snapshot: recompute after changing $REPOS_DIR.
    require("lib.nvim.system.env").get({ refresh = true })
    staleness.reset_cache()
    local cli = require("tasks_nvim.cli")
    local out, err = {}, {}
    local code = cli.run(
      { "list", "lib.nvim", "--stale=refs", "--vault=" .. root, "--today=" .. F.TODAY },
      {
        out = function(t)
          out[#out + 1] = t
        end,
        err = function(t)
          err[#err + 1] = t
        end,
      }
    )
    vim.env.REPOS_DIR, vim.env.NVIM_CONFIG_DIR = old_repos, old_cfg
    -- lib.nvim.system.env memoises its snapshot: recompute after changing $REPOS_DIR.
    require("lib.nvim.system.env").get({ refresh = true })
    local text = table.concat(out)
    eq(code, 0)
    has(text, "lib.nvim/stale-git")
    has(text, "changed: lua/a.lua (2026-10-01, git)", "the line names the changed file")
    lacks(text, "lib.nvim/fresh-after")
    lacks(text, "lib.nvim/no-refs")
    has(table.concat(err), "--stale=refs checked", "the summary goes to stderr")

    -- the spelled-out flag does the same; ids format stays machine-readable
    vim.env.REPOS_DIR, vim.env.NVIM_CONFIG_DIR = repos, cfg
    -- lib.nvim.system.env memoises its snapshot: recompute after changing $REPOS_DIR.
    require("lib.nvim.system.env").get({ refresh = true })
    staleness.reset_cache()
    out = {}
    cli.run({ "list", "--stale-refs", "--format=ids", "--vault=" .. root }, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function() end,
    })
    vim.env.REPOS_DIR, vim.env.NVIM_CONFIG_DIR = old_repos, old_cfg
    -- lib.nvim.system.env memoises its snapshot: recompute after changing $REPOS_DIR.
    require("lib.nvim.system.env").get({ refresh = true })
    has(table.concat(out), "lib.nvim/stale-git\n")
    lacks(table.concat(out), "changed:")

    -- unknown value still exits 2
    code = cli.run({ "list", "--stale=whenever", "--vault=" .. root }, {
      out = function() end,
      err = function() end,
    })
    eq(code, 2)
  end

  -- ── dashboard filter state ──────────────────────────────────────────────
  local core = require("tasks_nvim.ui.dash_core")
  eq(core.chips({ stale_refs = true }), { "stale: refs" })
  ok(not core.filter_is_empty({ stale_refs = true }))
  local opts_out = core.filter_to_options({ stale_refs = true })
  eq(opts_out.stale_refs, true)
  ok(core.filter_from_stored(opts_out).stale_refs, "the chip survives a restart")
  ok(core.set_dim({}, "stale-refs", true).stale_refs)
  eq(core.set_dim({ stale_refs = true }, "stale-refs", nil).stale_refs, nil)
  ok(vim.tbl_contains(core.FILTER_DIMS, "stale-refs"))

  -- ── one bad ref must not cost the dates of the others ───────────────────
  -- git refuses a pathspec outside its work tree and fails the WHOLE call, so
  -- `../other.nvim/lua/o.lua` used to send every file of the repo (and with
  -- it every task) to the mtime fallback.
  if have_git then
    local other_repo = repos .. "/other.nvim"
    ---@param args string[]
    ---@param date? string
    local function git_other(args, date)
      local cmd = { "git", "-C", other_repo, "-c", "user.name=t", "-c", "user.email=t@example.org" }
      vim.list_extend(cmd, args)
      local env = date and { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } or nil
      local res = vim.system(cmd, { text = true, env = env }):wait()
      eq(res.code, 0, "git " .. table.concat(args, " ") .. ": " .. tostring(res.stderr))
    end
    vim.fn.mkdir(other_repo, "p")
    git_other({ "init", "-q" })
    H.write(other_repo .. "/lua/o.lua", "return 1\n")
    git_other({ "add", "--", "lua/o.lua" })
    git_other({ "commit", "-q", "-m", "o" }, "2026-10-02T12:00:00")

    add("leaves-repo", "2026-09-15", { "../other.nvim/lua/o.lua", "lua/a.lua" })
    add("dotdot-inside", "2026-09-15", { "lua/sub/../a.lua" })
    local rescanned = assert(scan.area("lib.nvim", { root = root }))
    staleness.reset_cache()
    local report = staleness.compute(rescanned, opts)

    local by_ref = {}
    for _, change in ipairs(report.stale["lib.nvim/leaves-repo"] or {}) do
      by_ref[change.ref] = change
    end
    local far = by_ref["../other.nvim/lua/o.lua"]
    ok(far, "a ref into a sibling repo is dated")
    eq(far.source, "git", "from that repo's git, not from the file time")
    eq(far.date, "2026-10-02")
    eq(far.file, other_repo .. "/lua/o.lua", "the file is named with its real path")
    eq(by_ref["lua/a.lua"].source, "git", "the other ref of the task keeps its git date")
    eq(
      report.stale["lib.nvim/stale-git"][1].source,
      "git",
      "other tasks of the repo keep their git date"
    )
    local inside = report.stale["lib.nvim/dotdot-inside"]
    ok(inside, "a ref with .. that stays in the repo is found")
    eq(inside[1].source, "git")
    eq(inside[1].file, lib_repo .. "/lua/a.lua", "collapsed to the file itself")
    eq(
      table.concat(report.notes, "\n"):find("git log failed", 1, true),
      nil,
      "no failed git call is reported"
    )

    -- git_dates alone: the refused path costs only its own date
    staleness.reset_cache()
    local dates, derr =
      staleness.git_dates(lib_repo, { "lua/a.lua", "../other.nvim/lua/o.lua", "lua/b.lua" })
    ok(dates, "the dates git could give are returned")
    eq(dates["lua/a.lua"].date, "2026-10-01")
    eq(dates["lua/b.lua"].date, "2026-09-01")
    eq(dates["../other.nvim/lua/o.lua"], nil, "the refused path has no date")
    has(derr, "1 path(s) not dated by git", "and is counted")
    -- across chunk borders too: the bad path sits in the second of two chunks
    local many = {}
    for i = 1, staleness.GIT_CHUNK do
      many[#many + 1] = "lua/none-" .. i .. ".lua"
    end
    many[#many + 1] = "../other.nvim/lua/o.lua"
    many[#many + 1] = "lua/a.lua"
    local dated = staleness.git_dates(lib_repo, many)
    ok(dated and dated["lua/a.lua"], "a file next to the refused path is still dated")
  end

  -- ── the time budget ─────────────────────────────────────────────────────
  do
    local started = 0
    local counting = function()
      started = started + 1
      return {}
    end
    local late = staleness.compute(
      tasks,
      vim.tbl_extend("force", opts, { budget_ms = 0, git_dates = counting })
    )
    eq(started, 0, "no git call starts once the budget is used up")
    has(table.concat(late.notes, "\n"), "time budget", "the run says so")
    ok(late.stale["lib.nvim/mtime-untracked"], "file times decide for the rest")

    local gone, gerr = staleness.git_dates(
      lib_repo,
      { "lua/a.lua" },
      { deadline = uv.hrtime() - 1 }
    )
    eq(gone and next(gone), nil, "git_dates starts no call after its deadline")
    has(gerr, "time budget")
  end

  -- ── model.filter looks up only the tasks the other criteria kept ────────
  do
    local looked_up = {}
    local recording = function(_, rels)
      vim.list_extend(looked_up, rels)
      return {}
    end
    local only_doing = {
      stale_refs = true,
      status = { "doing" },
      ref_opts = vim.tbl_extend("force", opts, { git_dates = recording }),
    }
    eq(#model.filter(tasks, only_doing), 0, "no open task is doing")
    eq(looked_up, {}, "so no ref was looked at")
    local all_open = {
      stale_refs = true,
      status = { "open" },
      ref_opts = vim.tbl_extend("force", opts, { git_dates = recording }),
    }
    local _, handed_back = model.filter(tasks, all_open)
    ok(#looked_up > 0, "the open tasks are looked up")
    ok(
      handed_back and handed_back.tasks > 0,
      "model.filter hands the report back as its second result"
    )
  end
end
