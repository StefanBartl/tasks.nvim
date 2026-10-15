-- TESTS/tasks_block_lists_spec.lua -- a task file whose list properties are YAML block lists (what Obsidian's
-- Properties editor writes) is a valid task: `check` has no `frontmatter-invalid`, the lists are read, and
-- `mutate.set` keeps the style of the lists it does not change.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")

  local root = F.vault(H)
  local opts = { root = root }

  F.task(H, root, "lib.nvim", "dep-a", F.meta("Dep A", "open"))
  F.task(H, root, "lib.nvim", "dep-b", F.meta("Dep B", "open"))

  local path = root .. "/lib.nvim/ROADMAP/tasks/obsidian.md"
  local text = table.concat({
    "---",
    "title: Obsidian task",
    "status: blocked",
    "tags:",
    "  - app",
    '  - "watcher"',
    "blocked_by:",
    "  - lib.nvim/dep-a",
    "  - lib.nvim/dep-b",
    "refs:",
    "  - ALL/Concept.md",
    "---",
    "",
    "A summary line.",
    "",
  }, "\n")
  H.write(path, text)
  assert(index.write_area("lib.nvim", opts))

  -- ── read ────────────────────────────────────────────────────────────────
  local t = model.parse_text(text, { path = path, area = "lib.nvim", slug = "obsidian" })
  ok(t.valid, "block lists are valid: " .. vim.inspect(t.error_codes))
  eq(t.tags, { "app", "watcher" }, "tags read from a block list")
  eq(t.blocked_by, { "lib.nvim/dep-a", "lib.nvim/dep-b" }, "blocked_by read from a block list")
  eq(t.refs, { "ALL/Concept.md" }, "refs read from a block list")

  -- ── check ───────────────────────────────────────────────────────────────
  local res, err = check.run(opts)
  ok(res, "check.run failed: " .. tostring(err))
  for _, f in ipairs(res.findings) do
    ok(f.code ~= "frontmatter-invalid", "no frontmatter-invalid finding: " .. vim.inspect(f))
  end

  -- ── set: untouched lists keep their lines, a changed list keeps its style ─
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/checkpoints" }
  assert(
    mutate.set("lib.nvim/obsidian", { status = "open", tags = { "app", "watcher", "new" } }, o)
  )
  local after = H.read(path)
  ok(
    after:find('tags:\n  - app\n  - "watcher"\n  - "new"\nblocked_by:\n', 1, true),
    "tags stay a block list, the new item copies the style:\n" .. after
  )
  ok(
    after:find(
      "blocked_by:\n  - lib.nvim/dep-a\n  - lib.nvim/dep-b\nrefs:\n  - ALL/Concept.md\nupdated:",
      1,
      true
    ),
    "lists that were not touched are byte-identical:\n" .. after
  )
  ok(after:find("status: open\n", 1, true), "the scalar changed")
  ok(not after:find("[", 1, true), "nothing was rewritten inline")

  assert(mutate.set("lib.nvim/obsidian", { blocked_by = { "lib.nvim/dep-b" } }, o))
  after = H.read(path)
  ok(
    after:find("blocked_by:\n  - lib.nvim/dep-b\nrefs:", 1, true)
      and not after:find("dep-a", 1, true),
    "a shortened block list stays a block list:\n" .. after
  )

  -- review of fa26a31: only blocked_by/after keep the list style; a scalar field the file holds as a list is repaired
  local bad_path = root .. "/lib.nvim/ROADMAP/tasks/malformed.md"
  H.write(bad_path, "---\ntitle: Malformed\nstatus:\n  - open\nsummary:\n  - old\n---\n\nBody.\n")
  assert(index.write_area("lib.nvim", opts))
  assert(mutate.set("lib.nvim/malformed", { status = "doing", summary = "new" }, o))
  local fixed = H.read(bad_path)
  ok(fixed:find("status: doing\n", 1, true), "status is written as a scalar again:\n" .. fixed)
  ok(fixed:find("summary: new\n", 1, true), "so is the summary:\n" .. fixed)
  ok(not fixed:find("  - doing", 1, true), "no list item for a scalar field")
end
