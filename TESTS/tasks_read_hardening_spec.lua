-- TESTS/tasks_read_hardening_spec.lua -- the read side stays inside the vault: network and device refs are no refs,
-- an absolute ref only reaches the places it was told to look in, and a link (symbolic link, junction) is no way out
-- of the vault (a linked task file, a linked folder, a linked area).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local fsio = require("tasks_nvim.fsio")
  local staleness = require("tasks_nvim.staleness")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")
  local check = require("tasks_nvim.check")
  local contract = require("tasks_nvim.contract")
  local json = require("tasks_nvim.json")
  local plans_mod = require("tasks_nvim.plans")
  local uv = vim.uv or vim.loop
  local on_windows = require("lib.nvim.cross.platform.is_windows")()

  -- ── fsio.is_inside ───────────────────────────────────────────────────────
  ok(fsio.is_inside("C:/a/b", "C:/a/b"), "a folder is inside itself")
  ok(fsio.is_inside("C:/a/b", "C:/a/b/c.lua"), "a file below it")
  ok(fsio.is_inside("C:/a/b/", "C:/a/b/c/d.lua"), "a trailing slash of the parent does not matter")
  ok(not fsio.is_inside("C:/a/b", "C:/a/bc/d.lua"), "a longer folder name is not inside")
  ok(not fsio.is_inside("C:/a/b", "C:/a"), "the parent is not inside its child")
  ok(fsio.is_inside("/", "/x"), "the root of a POSIX path holds everything")
  ok(fsio.is_inside("C:/", "C:/x"), "a drive root holds its files")
  eq(
    fsio.is_inside("C:/A/B", "c:/a/b/x.lua"),
    on_windows,
    "case counts only where the file system ignores it"
  )

  -- ── fsio.is_link ─────────────────────────────────────────────────────────
  local outside = H.tmpdir() .. "/outside"
  vim.fn.mkdir(outside, "p")

  --- Make `path` point at `target`. False when this machine does not allow it (a file symlink on Windows needs
  --- developer mode); a folder gets a junction there, which needs no right.
  ---@param target string
  ---@param path string
  ---@param is_dir boolean
  ---@return boolean
  local function link(target, path, is_dir)
    return uv.fs_symlink(target, path, { dir = is_dir, junction = is_dir }) == true
  end

  --- Take a link away without touching what it points at.
  ---@param path string
  local function unlink(path)
    if not uv.fs_unlink(path) then
      uv.fs_rmdir(path)
    end
  end

  eq(fsio.is_link(outside), false, "a real folder is no link")
  eq(fsio.is_link(outside .. "/missing"), false, "a missing path is no link")
  H.write(outside .. "/real.md", "x\n")
  eq(fsio.is_link(outside .. "/real.md"), false, "a real file is no link")

  -- ── staleness.classify: network and device paths are no refs ─────────────
  for _, ref in ipairs({
    "//server/share/a.lua",
    "\\\\server\\share\\a.lua",
    "\\\\?\\C:\\repos\\a.lua",
    "//?/C:/repos/a.lua",
    "\\\\.\\pipe\\x",
    "//./pipe/x",
    "///x/y",
    "  //server/share/a.lua:12  ",
  }) do
    eq((staleness.classify(ref)), "skip", "not a ref: " .. ref)
  end
  eq(
    { staleness.classify("/etc/hosts") },
    { "path", "/etc/hosts" },
    "one slash is an absolute path"
  )
  eq(
    { staleness.classify("C:\\repos\\a.lua") },
    { "path", "C:/repos/a.lua" },
    "a drive letter is a path"
  )
  eq(
    { staleness.classify("docs//a.md") },
    { "path", "docs//a.md" },
    "a double slash inside is not a network path"
  )

  -- ── staleness: an absolute ref reaches only the places it was told to look in ──
  do
    local top = H.tmpdir()
    local root = F.vault(H)
    local repos = top .. "/repos"
    local cfg = top .. "/cfg"
    H.write(repos .. "/lib.nvim/lua/a.lua", "return 1\n")
    H.write(cfg .. "/docs/x.md", "x\n")
    local secret = H.tmpdir() .. "/secret/key.txt"
    H.write(secret, "not for refs\n")

    local function add(slug, refs)
      local m = F.meta(slug, "open")
      m[#m + 1] = { "created", "2026-09-15" }
      m[#m + 1] = { "updated", "2026-09-15" }
      m[#m + 1] = { "refs", "[" .. table.concat(refs, ", ") .. "]" }
      F.task(H, root, "lib.nvim", slug, m)
    end
    add("inside-repo", { repos .. "/lib.nvim/lua/a.lua" })
    add("inside-config", { cfg .. "/docs/x.md" })
    add("inside-dotdot", { repos .. "/lib.nvim/lua/../lua/a.lua" })
    add("outside", { secret })
    add("escape-by-dotdot", {
      repos
        .. "/../"
        .. vim.fs.basename(vim.fs.dirname(vim.fs.dirname(secret)))
        .. "/secret/key.txt",
    })

    local tasks = assert(scan.area("lib.nvim", { root = root }))
    local opts = {
      root = root,
      repo_bases = { repos },
      config_dir = cfg,
      git_dates = function()
        return nil, "no git in this spec"
      end,
    }
    staleness.reset_cache()
    local rep = staleness.compute(tasks, opts)
    eq(
      rep.files,
      2,
      "the two files inside the allowed places are looked at (repo file once, config file once)"
    )
    eq(rep.unresolved, 2, "the file outside and the one reached by `..` are found nowhere")

    local key_of = assert(staleness.file_key(opts))
    local by_slug = {}
    for _, t in ipairs(tasks) do
      by_slug[t.id:match("[^/]+$")] = t
    end
    local inside = key_of(by_slug["inside-repo"], repos .. "/lib.nvim/lua/a.lua")
    local dotted = key_of(by_slug["inside-dotdot"], repos .. "/lib.nvim/lua/../lua/a.lua")
    eq(inside, dotted, "`..` is resolved before two refs are compared")
    eq(
      key_of(by_slug["outside"], secret),
      on_windows and secret:lower() or secret,
      "a ref outside the places keeps its own spelling as its key (lower case where the file system ignores case)"
    )
  end

  -- ── a linked task file is not read ───────────────────────────────────────
  do
    local root = F.vault(H)
    F.task(H, root, "lib.nvim", "real", F.meta("Real", "open"))
    local secret = outside .. "/secret.md"
    H.write(secret, F.text(F.meta("From outside", "open")))
    local tasks_dir = root .. "/lib.nvim/ROADMAP/tasks"
    if link(secret, tasks_dir .. "/linked.md", false) then
      eq(fsio.is_link(tasks_dir .. "/linked.md"), true, "the file is a link")
      local tasks = assert(scan.area("lib.nvim", { root = root }))
      local linked
      for _, t in ipairs(tasks) do
        if t.path:match("/linked%.md$") then
          linked = t
        end
      end
      ok(linked, "the link is listed (so `check` can name it)")
      eq(linked.valid, false, "a linked task file is no task")
      eq(linked.error_codes, { "symlink-task" })
      eq(linked.meta.title, nil, "nothing of the target is read")
      eq(linked.etag, nil, "no version tag of a file that was not read")
      local res = assert(check.run({ root = root, area = "lib.nvim" }))
      local found = false
      for _, f in ipairs(res.findings) do
        found = found or (f.code == "symlink-task" and f.severity == "error")
      end
      ok(found, "check reports `symlink-task` as an error")
      eq(H.read(secret), F.text(F.meta("From outside", "open")), "the target is untouched")

      -- the contract documents say the same and never hash or show the target
      local snap = assert(contract.snapshot({ root = root }))
      eq(#snap.tasks, 1, "only the real task is an open task")
      eq(snap.unlisted, { { id = "lib.nvim/linked", status = "", code = "no-status" } })
      local doc = assert(contract.task("lib.nvim/linked", { root = root }))
      eq(doc.task.valid, false)
      eq(doc.task.problems[1].code, "symlink-task")
      eq(doc.task.etag, nil, "no version tag of a file that was not read")
      eq(doc.body, "", "the body of the target is not shown")
      unlink(tasks_dir .. "/linked.md")
    else
      print(
        "tasks_read_hardening_spec: file symlinks are not allowed here; the linked-file case is skipped"
      )
    end
  end

  -- ── a linked folder that leaves the vault is not read ────────────────────
  do
    local root = F.vault(H)
    local elsewhere = H.tmpdir() .. "/elsewhere"
    H.write(elsewhere .. "/ROADMAP/tasks/stolen.md", F.text(F.meta("Stolen", "open")))
    vim.fn.delete(root .. "/cascade.nvim/ROADMAP", "rf")
    ok(
      link(elsewhere .. "/ROADMAP", root .. "/cascade.nvim/ROADMAP", true),
      "a junction can be made"
    )
    local tasks, errors = scan.area("cascade.nvim", { root = root })
    eq(tasks, {}, "nothing is read through a link that leaves the vault")
    eq(#errors, 1, "and the scan says why")
    has(errors[1], "leaves the vault")
    has(errors[1], "cascade.nvim/ROADMAP/tasks")
    -- the contract says so too: the document is what could be read, and it names what could not
    local snap = assert(contract.snapshot({ root = root }))
    eq(#snap.incomplete, 1)
    has(snap.incomplete[1], "leaves the vault")
    has(snap.incomplete[1], "cascade.nvim/ROADMAP/tasks")
    eq(
      json.encode(snap):find(elsewhere, 1, true),
      nil,
      "and no path of this machine is in the document"
    )
    unlink(root .. "/cascade.nvim/ROADMAP")
    eq(H.read(elsewhere .. "/ROADMAP/tasks/stolen.md") ~= nil, true, "the target is still there")
  end

  -- ── a linked plans folder that leaves the vault is not read ─────────────────
  do
    local root = F.vault(H)
    local elsewhere = H.tmpdir() .. "/elsewhere-plans"
    H.write(
      elsewhere .. "/stolen.md",
      F.text({ { "title", "Stolen" }, { "status", "open" }, { "areas", "[lib.nvim]" } })
    )
    ok(link(elsewhere, root .. "/lib.nvim/ROADMAP/plans", true), "a junction can be made")
    local plans, errors = plans_mod.area("lib.nvim", { root = root })
    eq(plans, {}, "no plan is read through a link that leaves the vault")
    eq(#errors, 1)
    has(errors[1], "leaves the vault")
    unlink(root .. "/lib.nvim/ROADMAP/plans")
  end

  -- ── a link that stays inside the vault is read as before ─────────────────
  do
    local root = F.vault(H)
    F.task(H, root, "lib.nvim", "plain", F.meta("Plain", "open"))
    local tasks = assert(scan.area("lib.nvim", { root = root }))
    eq(#tasks, 1, "an ordinary area is read")
    eq(tasks[1].valid, true)
  end

  -- ── a linked folder is no area ───────────────────────────────────────────
  do
    local root = F.vault(H)
    local elsewhere = H.tmpdir() .. "/elsewhere-area"
    vim.fn.mkdir(elsewhere .. "/ROADMAP/tasks", "p")
    ok(link(elsewhere, root .. "/linked.nvim", true), "a junction can be made")
    ok(
      link(root .. "/lib.nvim", root .. "/alias.nvim", true),
      "a junction to a folder of the vault itself"
    )
    local names = {}
    for _, a in ipairs(vault.areas(root)) do
      names[#names + 1] = a.name
    end
    eq(vim.tbl_contains(names, "lib.nvim"), true, "the real area is listed")
    eq(vim.tbl_contains(names, "linked.nvim"), false, "a link to a folder outside is no area")
    eq(vim.tbl_contains(names, "alias.nvim"), false, "nor is a second name for an area")
    eq(vault.has_area(root, "linked.nvim"), false)
    unlink(root .. "/linked.nvim")
    unlink(root .. "/alias.nvim")
  end
end
