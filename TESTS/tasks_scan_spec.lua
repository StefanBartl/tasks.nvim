-- TESTS/tasks/tasks_scan_spec.lua -- tasks.scan against a fixture vault.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "beta", F.meta("Beta", "open", { { "prio", "2" } }))
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "doing", { { "prio", "1" } }))
  F.task(H, root, "cascade.nvim", "gamma", F.meta("Gamma", "decision"))
  F.task(H, root, "ALL", "delta", F.meta("Delta", "parked"))
  -- a broken file next to good ones: no frontmatter at all
  H.write(root .. "/lib.nvim/ROADMAP/tasks/broken.md", "just prose, no frontmatter\n")
  -- not a task file at all: ignored
  H.write(root .. "/lib.nvim/ROADMAP/tasks/.gitkeep", "")
  H.write(root .. "/lib.nvim/ROADMAP/tasks/notes.txt", "x")
  -- nested file is returned, flagged
  H.write(root .. "/lib.nvim/ROADMAP/tasks/sub/nested.md", F.text(F.meta("Nested", "open")))
  -- non-roadmap files stay out of the open scan
  H.write(root .. "/lib.nvim/ROADMAP/ROADMAP.md", "prose\n")

  local function ids(tasks)
    local out = {}
    for _, t in ipairs(tasks) do
      out[#out + 1] = t.id
    end
    return out
  end

  -- ── one area ────────────────────────────────────────────────────────────
  local tasks, errors = scan.area("lib.nvim", { root = root })
  ok(tasks, "scan.area returns tasks")
  eq(errors, {}, "no walk errors")
  eq(
    ids(tasks),
    { "lib.nvim/alpha", "lib.nvim/beta", "lib.nvim/broken", "lib.nvim/nested" },
    "every *.md under tasks/, in path order; .gitkeep and .txt ignored"
  )
  for _, t in ipairs(tasks) do
    eq(t.location, "roadmap")
    ok(t.path:find("^" .. vim.pesc(root)), "absolute path, forward slashes: " .. t.path)
    ok(not t.path:find("\\", 1, true), "no backslash in " .. t.path)
  end
  local by_id = {}
  for _, t in ipairs(tasks) do
    by_id[t.id] = t
  end
  ok(by_id["lib.nvim/alpha"].valid)
  ok(
    not by_id["lib.nvim/broken"].valid,
    "a bad file does not abort the scan, it is returned invalid"
  )
  eq(by_id["lib.nvim/broken"].error_codes, { "frontmatter-missing" })
  ok(not by_id["lib.nvim/nested"].valid, "nested files are flagged")
  eq(by_id["lib.nvim/nested"].error_codes, { "slug" })

  -- ── areas without tasks ─────────────────────────────────────────────────
  local none, none_err = scan.area("migrate.nvim", { root = root })
  eq(none, {}, "no tasks/ folder is an empty result")
  eq(none_err, {})
  local empty = scan.area("nvim-config", { root = root })
  eq(empty, {})

  local bad, bad_err = scan.area("../etc", { root = root })
  eq(bad, nil, "a traversal area is refused")
  ok(bad_err:find("invalid area", 1, true))

  -- ── whole vault ─────────────────────────────────────────────────────────
  local all = scan.all({ root = root })
  eq(ids(all), {
    "ALL/delta",
    "cascade.nvim/gamma",
    "lib.nvim/alpha",
    "lib.nvim/beta",
    "lib.nvim/broken",
    "lib.nvim/nested",
  }, "areas in name order, files in path order")

  -- ── cached walk gives the same answer ───────────────────────────────────
  local cached = scan.area("lib.nvim", { root = root, ttl_seconds = 60 })
  eq(ids(cached), ids(tasks), "ttl_seconds path returns the same tasks")
  H.write(root .. "/lib.nvim/ROADMAP/tasks/late.md", F.text(F.meta("Late", "open")))
  eq(
    #scan.area("lib.nvim", { root = root, ttl_seconds = 60 }),
    #tasks,
    "inside the TTL the walk is reused"
  )
  eq(
    #scan.area("lib.nvim", { root = root, ttl_seconds = 60, refresh = true }),
    #tasks + 1,
    "refresh forces a new walk"
  )
  eq(#scan.area("lib.nvim", { root = root }), #tasks + 1, "uncached sees the new file at once")
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/late.md")

  -- ── find ────────────────────────────────────────────────────────────────
  local found = scan.find("lib.nvim/alpha", { root = root })
  eq(found.title, "Alpha")
  eq(found.prio, 1)
  local nf, nf_err = scan.find("lib.nvim/nope", { root = root })
  eq(nf, nil)
  ok(nf_err:find("no such open task", 1, true))
  local bad_id, bad_id_err = scan.find("lib.nvim", { root = root })
  eq(bad_id, nil, "an id needs a slug")
  ok(bad_id_err)

  -- ── Backlog ─────────────────────────────────────────────────────────────
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-09-01_finished.md",
    F.text(F.meta("Finished", "done", { { "kind", "task" } }))
  )
  H.write(
    root .. "/lib.nvim/Backlog/FEATURES/2026-09-02_shipped.md",
    F.text(F.meta("Shipped", "done", { { "kind", "feature" } }))
  )
  -- an old free-form document: no frontmatter, not a task
  H.write(root .. "/lib.nvim/Backlog/TASKS/old-audit.md", "# An old audit\n\nprose\n")
  -- frontmatter without status: not a task either
  H.write(root .. "/lib.nvim/Backlog/TASKS/jekyll.md", "---\nlayout: post\n---\nbody\n")
  -- a task file that is still open: returned, so check can flag it
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-09-03_misfiled.md",
    F.text(F.meta("Misfiled", "open"))
  )
  -- nested below Backlog is found too
  H.write(root .. "/lib.nvim/Backlog/TASKS/Sub/2026-09-04_deep.md", F.text(F.meta("Deep", "done")))

  local backlog = scan.backlog("lib.nvim", { root = root })
  local backlog_ids = ids(backlog)
  table.sort(backlog_ids)
  eq(
    backlog_ids,
    { "lib.nvim/deep", "lib.nvim/finished", "lib.nvim/misfiled", "lib.nvim/shipped" },
    "only Backlog files with frontmatter + status; the date prefix is not part of the id"
  )
  for _, t in ipairs(backlog) do
    eq(t.location, "backlog")
  end

  local done = scan.find_done("lib.nvim/finished", { root = root })
  ok(done, "find_done by id")
  eq(done.title, "Finished")
  eq(scan.find_done("lib.nvim/nothing", { root = root }), nil)
  eq(scan.find_done("lib.nvim", { root = root }), nil, "no slug, no result")

  local slugs = scan.backlog_slugs("lib.nvim", { root = root })
  ok(slugs["finished"] and slugs["shipped"] and slugs["deep"], "all dated Backlog files")
  ok(slugs["old-audit"], "free-form documents count too: the slug must stay unique")
  ok(slugs["jekyll"])
  ok(not slugs["alpha"], "open tasks are not Backlog slugs")

  -- CRLF files scan the same
  H.write(
    root .. "/cascade.nvim/ROADMAP/tasks/crlf.md",
    H.crlf(F.text(F.meta("Windows", "open", { { "prio", "2" } }), "\nSummary.\n"))
  )
  local crlf = scan.find("cascade.nvim/crlf", { root = root })
  ok(crlf.valid, vim.inspect(crlf.errors))
  eq(crlf.summary, "Summary.")
end
