-- TESTS/tasks/tasks_vault_spec.lua -- tasks.vault: root resolution, areas, paths, validators.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)

  -- ── root resolution ─────────────────────────────────────────────────────
  local saved_env = vim.env.TASKS_VAULT
  vault.set_root(nil)
  vim.env.TASKS_VAULT = nil

  eq(select(1, vault.root({ root = root })), root, "explicit opts.root wins")
  eq(select(1, vault.root({ root = root .. "/" })), root, "trailing slash stripped")
  eq(select(1, vault.root({ root = (root:gsub("/", "\\")) })), root, "backslashes normalised")

  local none, err = vault.root({ root = root .. "/does-not-exist" })
  eq(none, nil, "missing root is an error")
  ok(err:find("not a directory", 1, true), "error names the problem: " .. tostring(err))

  vim.env.TASKS_VAULT = root
  eq(select(1, vault.root()), root, "$TASKS_VAULT")

  local other = H.tmpdir()
  vault.set_root(other)
  eq(select(1, vault.root()), other, "set_root beats $TASKS_VAULT")
  eq(select(1, vault.root({ root = root })), root, "opts.root beats set_root")
  vault.set_root(nil)

  -- configure() sits between set_root and $TASKS_VAULT; there is no built-in default path
  local configured = H.tmpdir()
  vault.configure({ vault = configured })
  eq(select(1, vault.root()), configured, "configure beats $TASKS_VAULT")
  vault.set_root(other)
  eq(select(1, vault.root()), other, "set_root beats configure")
  vault.set_root(nil)
  vault.configure({ vault = "" })
  eq(select(1, vault.root()), root, "an empty configured vault clears it")
  vim.env.TASKS_VAULT = nil
  local nothing, no_env = vault.root()
  eq(nothing, nil, "no root at all")
  ok(no_env:find("TASKS_VAULT", 1, true), "error says what to set")

  vim.env.TASKS_VAULT = saved_env

  -- ── areas ───────────────────────────────────────────────────────────────
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    names[#names + 1] = a.name
    eq(a.path, root .. "/" .. a.name, "area path")
  end
  eq(
    names,
    { "ALL", "cascade.nvim", "lib.nvim", "migrate.nvim", "nvim-config" },
    "ROADMAP/Backlog folders and the named extras, sorted; _Telemetry/TEMPLATES/TOOLS/empty skipped"
  )
  ok(vault.has_area(root, "lib.nvim"))
  ok(vault.has_area(root, "ALL"))
  ok(not vault.has_area(root, "filetreepicker.nvim"), "an empty folder is not an area")
  ok(not vault.has_area(root, "TOOLS"))
  ok(not vault.has_area(root, "../x"), "traversal is no area")

  -- ── paths ───────────────────────────────────────────────────────────────
  eq(vault.tasks_dir(root, "lib.nvim"), root .. "/lib.nvim/ROADMAP/tasks")
  eq(vault.index_path(root, "lib.nvim"), root .. "/lib.nvim/ROADMAP/TASKS.md")
  eq(vault.backlog_dir(root, "lib.nvim", "FEATURES"), root .. "/lib.nvim/Backlog/FEATURES")
  eq(vault.backlog_readme(root, "lib.nvim"), root .. "/lib.nvim/Backlog/README.md")
  eq(vault.task_path(root, "lib.nvim", "x-y"), root .. "/lib.nvim/ROADMAP/tasks/x-y.md")

  -- ── validators ──────────────────────────────────────────────────────────
  for _, good in ipairs({ "lib.nvim", "ALL", "nvim-config", "migrate.nvim", "a_b" }) do
    ok(vault.valid_area(good), "valid area " .. good)
  end
  for _, bad in ipairs({ "", "..", ".hidden", "-x", "a/b", "a\\b", "a..b", "a b", 5 }) do
    ok(not vault.valid_area(bad), "invalid area " .. tostring(bad))
  end
  for _, good in ipairs({ "a", "cycle-count", "x2", "0-first", "a-b-c" }) do
    ok(vault.valid_slug(good), "valid slug " .. good)
  end
  for _, bad in ipairs({ "", "-a", "a-", "a--b", "A", "a_b", "a b", "ä", "a.md", 1 }) do
    ok(not vault.valid_slug(bad), "invalid slug " .. tostring(bad))
  end

  local a, s = vault.parse_id("lib.nvim/cycle-count")
  eq(a, "lib.nvim")
  eq(s, "cycle-count")
  a, s = vault.parse_id("lib.nvim")
  eq(a, "lib.nvim")
  eq(s, nil, "a bare area has no slug")
  for _, bad in ipairs({ "", "a/b/c", "/x", "x/", "lib.nvim/Bad Slug", "../x/y" }) do
    local pa, _, perr = vault.parse_id(bad)
    eq(pa, nil, "bad id " .. bad)
    ok(perr, "bad id carries an error: " .. bad)
  end

  eq(vault.BUCKET_OF_KIND.feature, "FEATURES")
  eq(vault.BUCKET_OF_KIND.idea, "FEATURES")
  eq(vault.BUCKET_OF_KIND.research, "FEATURES")
  eq(vault.BUCKET_OF_KIND.task, "TASKS")
  eq(vault.BUCKET_OF_KIND.bug, "TASKS")

  -- ── an area is spelled exactly like its folder ──────────────────────────
  -- On Windows and macOS `stat` resolves `LIB.NVIM` and (Windows) `lib.nvim.` to the
  -- folder `lib.nvim`, so these used to pass and a task was created under the
  -- wrong id in the right folder (and its index named the wrong area).
  ok(vault.has_area(root, "lib.nvim"), "the exact spelling is an area")
  for _, alias in ipairs({ "LIB.NVIM", "Lib.Nvim", "lib.nvim." }) do
    ok(not vault.has_area(root, alias), "not an area, whatever the file system says: " .. alias)
    ok(not vault.dir_listed(root, alias), "not listed: " .. alias)
  end
  ok(vault.dir_listed(root, "lib.nvim"), "listed")
  eq(vault.dir_listed(root .. "/does-not-exist", "lib.nvim"), false, "no folder, nothing listed")
  F.task(H, root, "lib.nvim", "real-one", F.meta("Real", "open"))
  local scan = require("tasks_nvim.scan")
  local found = scan.find("lib.nvim/real-one", { root = root })
  ok(found, "the exact id is found")
  local wrong, werr = scan.find("LIB.NVIM/real-one", { root = root })
  eq(wrong, nil, "an id with the area in the wrong case is not found")
  ok(werr and werr:find("no such open task", 1, true), "and says so: " .. tostring(werr))
  eq(scan.find_done("LIB.NVIM/real-one", { root = root }), nil)
  local created, cerr =
    require("tasks_nvim.mutate").new("LIB.NVIM", { root = root, title = "Wrong" })
  eq(created, nil, "new refuses a wrongly spelled area")
  ok(cerr and cerr:find("unknown area", 1, true), "with the usual message: " .. tostring(cerr))
end
