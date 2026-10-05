-- TESTS/tasks_folder_spec.lua -- categories and folder tasks (concept section 12).

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")

  local TODAY = F.TODAY
  local cpdir = H.tmpdir() .. "/checkpoints"

  local function setup()
    local root = F.vault(H)
    return root, { root = root, today = TODAY, checkpoint_dir = cpdir }
  end

  ---@param t table
  ---@return string[]
  local function ids(t)
    local out = {}
    for _, task in ipairs(t) do
      out[#out + 1] = task.id
    end
    table.sort(out)
    return out
  end

  --- A small file to attach.
  ---@param name string
  ---@param content? string
  ---@return string path
  local function asset_file(name, content)
    local path = H.tmpdir() .. "/src/" .. name
    H.write(path, content or "x")
    return path
  end

  -- ── categories: model ───────────────────────────────────────────────────
  eq(model.CATEGORIES, { "bug", "security", "performance", "docs", "ruleset" })
  ok(model.is_category("security"))
  ok(not model.is_category("Security"))
  ok(not model.is_category(nil))

  local function parse(meta)
    return model.parse_text(F.text(meta), { path = "/v/a/ROADMAP/tasks/t.md", area = "a" })
  end

  local t1 = parse(F.meta("T", "open", { { "category", "[security, docs]" } }))
  ok(t1.valid, "category list parses")
  eq(t1.category, { "security", "docs" })
  eq(model.categories(t1), { "security", "docs" })

  local t2 = parse(F.meta("T", "open", { { "category", "security" } }))
  eq(t2.category, { "security" }, "a scalar counts as a one-item list")

  local bad = parse(F.meta("T", "open", { { "category", "[secuity]" } }))
  ok(not bad.valid, "an unknown category is an error")
  eq(bad.error_codes[1], "unknown-category")

  -- implied categories: kind bug, and a tag spelled like a category
  eq(model.categories({ kind = "bug", tags = {} }), { "bug" })
  eq(model.categories({ kind = "task", tags = { "docs", "windows", "performance" } }), {
    "performance",
    "docs",
  })
  eq(model.categories({ category = { "ruleset" }, kind = "bug", tags = { "security" } }), {
    "bug",
    "security",
    "ruleset",
  })
  eq(model.categories({ tags = {} }), {})

  -- filter and option parsing
  local list = {
    parse(F.meta("A", "open", { { "category", "[security]" } })),
    parse(F.meta("B", "open", { { "kind", "bug" } })),
    parse(F.meta("C", "open", { { "tags", "[docs]" } })),
    parse(F.meta("D", "open")),
  }
  for i, t in ipairs(list) do
    t.slug = "t" .. i
    t.id = "a/t" .. i
  end
  eq(ids(model.filter(list, { category = { "security" } })), { "a/t1" })
  eq(ids(model.filter(list, { category = { "bug" } })), { "a/t2" }, "kind bug counts as bug")
  eq(ids(model.filter(list, { category = { "docs", "security" } })), { "a/t1", "a/t3" })
  eq(#model.filter(list, {}), 4)
  local f = assert(require("tasks_nvim.filter_opts").parse({ category = "bug,docs" }))
  eq(f.category, { "bug", "docs" })
  local _, ferr = require("tasks_nvim.filter_opts").parse({ category = "nope" })
  has(ferr, "unknown category")

  -- the dashboard knows the dimension: chips, `f` menu, stored filter, search text
  local dash = require("tasks_nvim.ui.dash_core")
  ok(vim.tbl_contains(dash.FILTER_DIMS, "category"))
  eq(dash.dim_choices("category", {}), model.CATEGORIES)
  local df = dash.set_dim({}, "category", "security")
  eq(df.category, { "security" })
  eq(dash.chips(df), { "category: security" })
  ok(not dash.filter_is_empty(df))
  eq(dash.filter_to_options(df).category, "security")
  eq(dash.filter_from_stored({ category = "docs,bug" }).category, { "docs", "bug" })
  eq(
    dash.filter_from_stored({ category = "nope" }),
    {},
    "a stored filter that no longer parses is empty"
  )
  eq(dash.set_dim(df, "category", nil).category, nil)
  has(dash.search_text(list[2]), "bug", "the picker matcher searches the categories")

  -- ── categories: mutate (new / set) ──────────────────────────────────────
  local root, o = setup()
  local created = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend("force", o, { title = "Sec fix", category = "security,docs" })
    )
  )
  eq(scan.find(created.id, { root = root }).category, { "security", "docs" })
  local _, cerr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "X", category = "nope" }))
  has(cerr, "unknown category")
  assert(mutate.set(created.id, { category = "performance" }, o))
  eq(scan.find(created.id, { root = root }).category, { "performance" })
  assert(mutate.set(created.id, { category = mutate.REMOVE }, o))
  eq(scan.find(created.id, { root = root }).category, {})
  local _, serr = mutate.set(created.id, { category = "nope" }, o)
  has(serr, "unknown category")
  assert(mutate.set(created.id, { rules = "LLS-45, LLS-46" }, o))
  eq(scan.find(created.id, { root = root }).meta.rules, { "LLS-45", "LLS-46" })

  -- ── folder tasks: new / scan / index ────────────────────────────────────
  root, o = setup()
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain one" })))
  local folder = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Folder one", folder = true }))
  )
  ok(not plain.folder and folder.folder)
  eq(folder.path, root .. "/lib.nvim/ROADMAP/tasks/folder-one/folder-one.md")
  ok(H.exists(folder.path), "the folder task file exists")

  local tasks = assert(scan.area("lib.nvim", { root = root }))
  eq(ids(tasks), { "lib.nvim/folder-one", "lib.nvim/plain-one" })
  for _, t in ipairs(tasks) do
    ok(t.valid, t.id .. " is valid")
    eq(t.folder, t.slug == "folder-one")
  end
  eq(scan.find("lib.nvim/folder-one", { root = root }).folder, true)
  eq(scan.find("lib.nvim/plain-one", { root = root }).folder, false)

  -- other files in the folder are assets, never tasks (even other .md files)
  H.write(root .. "/lib.nvim/ROADMAP/tasks/folder-one/assets/notes.md", "# raw notes\n")
  H.write(root .. "/lib.nvim/ROADMAP/tasks/folder-one/other.md", "---\ntitle: x\n---\n")
  eq(
    ids(assert(scan.area("lib.nvim", { root = root }))),
    { "lib.nvim/folder-one", "lib.nvim/plain-one" }
  )
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/folder-one/other.md")

  -- a folder without its own task file is reported, as before for nested files
  H.write(root .. "/lib.nvim/ROADMAP/tasks/stray/readme.md", F.text(F.meta("Stray", "open")))
  local stray
  for _, t in ipairs(assert(scan.area("lib.nvim", { root = root }))) do
    if t.slug == "readme" then
      stray = t
    end
  end
  ok(stray and not stray.valid, "a nested file outside a task folder is flagged")
  eq(stray.error_codes[1], "slug")
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/stray", "rf")

  -- slug taken in either form
  local again = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Folder one" })))
  eq(again.slug, "folder-one-2", "a plain task does not reuse a folder task's slug")
  local again2 = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain one", folder = true }))
  )
  eq(again2.slug, "plain-one-2", "a folder task does not reuse a plain task's slug")
  local _, exists = mutate.new(
    "lib.nvim",
    vim.tbl_extend("force", o, { title = "T", slug = "folder-one", folder = false })
  )
  has(exists, "already exists")

  -- the index links to the right file
  local text = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  has(text, "(tasks/folder-one/folder-one.md)")
  has(text, "(tasks/plain-one.md)")

  -- ── folderize and attach ────────────────────────────────────────────────
  local fz = assert(mutate.folderize("lib.nvim/plain-one", o))
  ok(fz.changed)
  eq(fz.path, root .. "/lib.nvim/ROADMAP/tasks/plain-one/plain-one.md")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/plain-one.md"), "the old file is gone")
  ok(scan.find("lib.nvim/plain-one", { root = root }).folder)
  ok(not assert(mutate.folderize("lib.nvim/plain-one", o)).changed, "folderize is idempotent")
  has(H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"), "(tasks/plain-one/plain-one.md)")

  -- attach to a plain task folderizes it first
  local plain2 =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Needs shot" })))
  local shot = asset_file("Screen Shot 1.PNG", "png-bytes")
  local att = assert(mutate.attach(plain2.id, shot, o))
  ok(att.folderized)
  eq(att.rel, "assets/Screen-Shot-1.PNG")
  eq(att.link, "![Screen-Shot-1.PNG](assets/Screen-Shot-1.PNG)", "an image gets the image syntax")
  eq(H.read(att.asset), "png-bytes")
  ok(scan.find(plain2.id, { root = root }).folder)

  -- a non-image gets a plain link; a second attach does not folderize again
  local log = asset_file("trace.txt", "log")
  local att2 = assert(mutate.attach(plain2.id, log, o))
  ok(not att2.folderized)
  eq(att2.link, "[trace.txt](assets/trace.txt)")

  -- never replaces an asset; --name renames the copy
  local _, dup = mutate.attach(plain2.id, log, o)
  has(dup, "asset exists")
  eq(
    assert(mutate.attach(plain2.id, log, vim.tbl_extend("force", o, { name = "trace-2.txt" }))).rel,
    "assets/trace-2.txt"
  )
  local _, badname =
    mutate.attach(plain2.id, log, vim.tbl_extend("force", o, { name = "../evil.txt" }))
  has(badname, "asset name")
  local _, nofile = mutate.attach(plain2.id, H.tmpdir() .. "/missing.png", o)
  has(nofile, "not a file")
  local _, notask = mutate.attach("lib.nvim/nope", log, o)
  has(notask, "no such open task")

  -- ── check ───────────────────────────────────────────────────────────────
  assert(index.write_area("lib.nvim", { root = root }))
  local res = assert(check.run({ root = root }))
  local function codes(r)
    local out = {}
    for _, fnd in ipairs(r.findings) do
      out[#out + 1] = (fnd.severity == "warn" and "warn:" or "") .. fnd.code
    end
    table.sort(out)
    return out
  end
  eq(codes(res), {}, "folder tasks and assets pass the check")

  -- a dangling asset link is a warning
  local tp = root .. "/lib.nvim/ROADMAP/tasks/needs-shot/needs-shot.md"
  -- (a percent-encoded link to an existing file is not dangling)
  H.write(root .. "/lib.nvim/ROADMAP/tasks/needs-shot/assets/two words.txt", "x")
  H.write(
    tp,
    H.read(tp)
      .. "\n![gone](assets/gone.png)\n![here](assets/trace.txt)\n[spaced](assets/two%20words.txt)\n"
  )
  assert(index.write_area("lib.nvim", { root = root }))
  res = assert(check.run({ root = root }))
  eq(codes(res), { "warn:asset-dangling" })
  has(res.findings[1].message, "assets/gone.png")
  ok(res.ok, "a dangling asset is only a warning")

  -- a link that climbs out of the folder is dangling, even though the file it reaches exists
  -- (`assets/../needs-shot.md` is the task file itself, `%2e%2e` the same encoded)
  H.write(
    tp,
    H.read(tp) .. "\n![up](assets/../needs-shot.md)\n![enc](assets/%2e%2e/needs-shot.md)\n"
  )
  assert(index.write_area("lib.nvim", { root = root }))
  res = assert(check.run({ root = root }))
  local up = {}
  for _, fnd in ipairs(res.findings) do
    if fnd.code == "asset-dangling" then
      up[#up + 1] = fnd.message
    end
  end
  eq(#up, 3, "gone.png and both climbing links are dangling")
  local all_up = table.concat(up, "\n")
  has(all_up, "assets/../needs-shot.md")
  has(all_up, "assets/%2e%2e/needs-shot.md")

  -- the same slug as file and as folder is an error
  H.write(root .. "/lib.nvim/ROADMAP/tasks/needs-shot.md", F.text(F.meta("Twin", "open")))
  res = assert(check.run({ root = root }))
  ok(vim.tbl_contains(codes(res), "slug-conflict"), "file + folder of one slug conflict")
  ok(not res.ok)
  local _, rerr = scan.find("lib.nvim/needs-shot", { root = root })
  has(rerr, "file and as folder")
  vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/needs-shot.md")

  -- an unknown category is reported by check
  assert(mutate.set("lib.nvim/folder-one", { category = "docs" }, o))
  local fp = root .. "/lib.nvim/ROADMAP/tasks/folder-one/folder-one.md"
  H.write(fp, (H.read(fp):gsub("category: %[docs%]", "category: [docz]")))
  res = assert(check.run({ root = root }))
  ok(vim.tbl_contains(codes(res), "unknown-category"))
  H.write(fp, (H.read(fp):gsub("category: %[docz%]", "category: [docs]")))

  -- ── done moves the whole folder ─────────────────────────────────────────
  assert(index.write_area("lib.nvim", { root = root }))
  local done =
    assert(mutate.done("lib.nvim/needs-shot", vim.tbl_extend("force", o, { done_in = "abc123" })))
  local bdir = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_needs-shot"
  eq(done.to, bdir .. "/2026-10-03_needs-shot.md")
  ok(H.exists(done.to), "the task file moved")
  ok(H.exists(bdir .. "/assets/Screen-Shot-1.PNG"), "assets moved with it")
  eq(H.read(bdir .. "/assets/Screen-Shot-1.PNG"), "png-bytes")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/needs-shot"), "the open folder is gone")
  has(H.read(done.to), "status: done")
  has(H.read(done.to), "done_in: abc123")
  has(
    H.read(root .. "/lib.nvim/Backlog/README.md"),
    "(./TASKS/2026-10-03_needs-shot/2026-10-03_needs-shot.md)"
  )

  local fin = scan.find_done("lib.nvim/needs-shot", { root = root })
  ok(fin and fin.folder and fin.valid, "the finished folder task is found")
  eq(
    #assert(scan.backlog("lib.nvim", { root = root })),
    1,
    "the Backlog scan reads the folder task once"
  )
  eq(assert(mutate.done("lib.nvim/needs-shot", o)).already, true, "done twice changes nothing")
  eq(codes(assert(check.run({ root = root }))), {}, "the vault checks clean after done")

  -- a taken slug cannot be reused by a new task
  local reuse = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Needs shot" })))
  eq(reuse.slug, "needs-shot-2")

  -- done rolls the folder back when a later step fails
  local orig = require("tasks_nvim.fsio").write_atomic
  local fsio = require("tasks_nvim.fsio")
  local keep =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Keep me", folder = true })))
  assert(mutate.attach(keep.id, asset_file("k.txt", "keep"), o))
  local before = H.read(keep.path)
  ---@diagnostic disable-next-line: duplicate-set-field
  fsio.write_atomic = function(path, content)
    if path:match("TASKS%.md$") then
      return false, "stubbed write failure"
    end
    return orig(path, content)
  end
  local failed, ferr2 = mutate.done(keep.id, o)
  fsio.write_atomic = orig
  ok(failed == nil and ferr2, "a failing step fails done")
  ok(H.exists(keep.path), "the task file is back at its place")
  eq(H.read(keep.path), before, "byte-exact")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/keep-me/assets/k.txt"), "the asset is back")
  ok(not H.exists(root .. "/lib.nvim/Backlog/TASKS/2026-10-03_keep-me"), "nothing left in Backlog")
  ok(scan.find(keep.id, { root = root }).folder, "still an open folder task")

  -- ── CLI ─────────────────────────────────────────────────────────────────
  root = F.vault(H)
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return code, table.concat(out), table.concat(err)
  end
  local base = { "--vault=" .. root, "--today=" .. TODAY }
  local function cmd(...)
    local argv = { ... }
    for _, b in ipairs(base) do
      argv[#argv + 1] = b
    end
    return run(argv)
  end

  local code, out =
    cmd("new", "lib.nvim", "CLI folder", "--folder", "--category=security,performance")
  eq(code, 0)
  has(out, "created\tlib.nvim/cli-folder\t")
  has(out, "cli-folder/cli-folder.md")
  code = cmd("new", "lib.nvim", "CLI plain", "--kind=bug")
  eq(code, 0)

  code, out = cmd("list", "lib.nvim", "--category=security", "--format=ids")
  eq(code, 0)
  eq(out, "lib.nvim/cli-folder\n")
  _, out = cmd("list", "lib.nvim", "--category=bug", "--format=ids")
  eq(out, "lib.nvim/cli-plain\n", "kind bug is found by --category=bug")
  local err
  code, _, err = cmd("list", "--category=nope")
  eq(code, 2)
  has(err, "unknown category")

  local src = asset_file("cli.png", "img")
  code, out = cmd("attach", "lib.nvim/cli-plain", src)
  eq(code, 0)
  has(out, "attached\tlib.nvim/cli-plain\tassets/cli.png\t![cli.png](assets/cli.png)")
  has(out, "folderized\tlib.nvim/cli-plain")
  code, out = cmd("folderize", "lib.nvim/cli-plain")
  eq(code, 0)
  has(out, "unchanged\tlib.nvim/cli-plain")
  code = cmd("attach", "lib.nvim/cli-plain")
  eq(code, 2)
  code, _, err = cmd("attach", "lib.nvim/cli-plain", src)
  eq(code, 1)
  has(err, "asset exists")
  code, out = cmd("check")
  eq(code, 0, out)
end
