-- TESTS/tasks_area_groups_spec.lua -- area groups: a filter name for several areas (`<vault>/area-groups.json`).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local area_groups = require("tasks_nvim.area_groups")
  local cli = require("tasks_nvim.cli")
  local config = require("tasks_nvim.config")
  local contract = require("tasks_nvim.contract")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  config.merge({})
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, err = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  ---@param groups table
  local function write_groups(groups)
    H.write(root .. "/" .. area_groups.FILE, vim.json.encode({ version = 1, groups = groups }))
  end

  F.task(H, root, "lib.nvim", "lib-task", F.meta("Lib task", "open"))
  F.task(H, root, "cascade.nvim", "cascade-task", F.meta("Cascade task", "open"))
  F.task(H, root, "nvim-config", "config-task", F.meta("Config task", "open"))
  F.task(H, root, "ALL", "all-task", F.meta("All task", "open"))

  -- ── no file: no groups, nothing changes ─────────────────────────────────
  local groups, notes = area_groups.all(root)
  eq(#groups, 0, "no file, no groups")
  eq(#notes, 0)
  eq(area_groups.resolve(root, "nvim"), nil, "an unknown name is neither area nor group")
  local doc = assert(contract.areas({ root = root }))
  eq(doc.area_groups, nil, "a vault without groups keeps its areas document as it was")

  -- ── resolve: globs, exact names, exclude, overlap; an area wins ─────────
  write_groups({
    nvim = { include = { "*.nvim" }, desc = "the plugins" },
    cfg = { include = { "nvim-config", "ALL" }, exclude = { "ALL" } },
    ["lib.nvim"] = { include = { "ALL" } },
  })
  local scope = assert(vault.area_scope(root, "nvim"))
  ok(scope.group, "nvim is a group")
  eq(
    scope.areas,
    { "cascade.nvim", "lib.nvim", "migrate.nvim" },
    "a new *.nvim area joins by the glob"
  )
  scope = assert(vault.area_scope(root, "cfg"))
  eq(scope.areas, { "nvim-config" }, "exclude takes ALL out again")
  scope = assert(vault.area_scope(root, "lib.nvim"))
  eq(scope.group, false, "an area of the same name wins over a group")
  eq(scope.areas, { "lib.nvim" })
  local _, err = vault.area_scope(root, "nvi")
  has(err, "nvim", "the message names the group that comes close")
  ok(vault.has_area(root, "lib.nvim") and not vault.has_area(root, "nvim"), "has_area stays strict")

  -- ── scan: an area group stands for its members ──────────────────────────
  local open = assert(scan.open_tasks({ root = root, area = "nvim" }))
  local ids = vim.tbl_map(function(t)
    return t.id
  end, open)
  table.sort(ids)
  eq(ids, { "cascade.nvim/cascade-task", "lib.nvim/lib-task" })

  -- ── CLI: list, next, plans, areas; new refuses a group ──────────────────
  local r = run({ "list", "nvim", "--format=ids" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/lib-task")
  has(r.out, "cascade.nvim/cascade-task")
  lacks(r.out, "nvim-config/config-task", "nvim-config does not match *.nvim")
  r = run({ "list", "nope" })
  eq(r.code, 1)
  has(r.err, "unknown area: nope")
  r = run({ "list", "nvim", "--format=json" })
  eq(r.code, 0, r.err)
  has(r.out, "cascade.nvim/cascade-task")
  lacks(r.out, "all-task")
  r = run({ "next", "cfg", "--format=json" })
  eq(r.code, 0, r.err)
  has(r.out, "nvim-config/config-task", "the group's member ranks first")
  r = run({ "plans", "nvim" })
  eq(r.code, 0, r.err)
  r = run({ "plan", "nvim", "--format=ids" })
  eq(r.code, 0, r.err)
  has(r.out, "lib.nvim/lib-task")
  lacks(r.out, "config-task")
  r = run({ "new", "nvim", "A task in a group" })
  eq(r.code, 1, "a group is no place for a task")
  has(
    r.err,
    "'nvim' is an area group (members: cascade.nvim, lib.nvim, migrate.nvim): name one area"
  )
  r = run({ "areas" })
  lacks("\n" .. r.out, "\nnvim\n", "--format=names stays the plain area list")
  r = run({ "areas", "--format=tsv" })
  has(r.out, "nvim\t2\tgroup\tcascade.nvim,lib.nvim,migrate.nvim\n", "tsv marks the groups")
  has(r.out, "lib.nvim\t1\n")
  lacks(r.out, "lib.nvim\t1\tgroup", "a shadowed group is not listed")

  -- ── contract: list / areas / snapshot ───────────────────────────────────
  local listed = assert(contract.list({ area = "nvim" }, { root = root }))
  eq(#listed.items, 2)
  doc = assert(contract.areas({ root = root }))
  eq(#doc.area_groups, 2, "the groups in force: cfg and nvim")
  eq(doc.area_groups[2].name, "nvim")
  eq(doc.area_groups[2].open, 2)
  eq(doc.area_groups[2].desc, "the plugins")
  local snap = assert(contract.snapshot({ root = root }))
  eq(#snap.area_groups, 2)
  local _, nerr = contract.list({ area = "nope" }, { root = root })
  eq(nerr.code, "not_found")

  -- ── check: what misses its point ────────────────────────────────────────
  write_groups({
    nvim = { include = { "*.nvim" } },
    ghost = { include = { "no-such-area" } },
    nested = { include = { "nvim", "ALL" } },
    ["lib.nvim"] = { include = { "ALL" } },
    bad = { include = {} },
  })
  local res = assert(require("tasks_nvim.check").run({ root = root }))
  local codes = {}
  for _, f in ipairs(res.findings) do
    if f.code:match("^area%-group") then
      codes[#codes + 1] = f.code .. ":" .. f.severity
    end
  end
  table.sort(codes)
  eq(codes, {
    "area-group-empty:warn",
    "area-group-nested:warn",
    "area-group-shadowed:warn",
    "area-group-unknown-member:warn",
    "area-groups-invalid:error",
  })
  res = assert(require("tasks_nvim.check").run({ root = root, area = "lib.nvim" }))
  for _, f in ipairs(res.findings) do
    ok(not f.code:match("^area%-group"), "an area run leaves the vault file alone")
  end

  -- ── a broken file: no groups, the area still works ──────────────────────
  H.write(root .. "/" .. area_groups.FILE, "{ not json")
  groups, notes = area_groups.all(root)
  eq(#groups, 0)
  has(notes[1], "not valid JSON")
  ok(vault.area_scope(root, "lib.nvim"), "an area is found without the groups")

  -- ── setup({ area_groups }) adds and shadows by name ─────────────────────
  write_groups({ nvim = { include = { "lib.nvim" } } })
  config.merge({ area_groups = { nvim = { include = { "*.nvim" }, exclude = { "migrate.nvim" } } } })
  scope = assert(vault.area_scope(root, "nvim"))
  eq(scope.areas, { "cascade.nvim", "lib.nvim" }, "the config group wins by name")
  groups, notes = area_groups.all(root)
  eq(groups[1].source, "config")
  has(notes[1], "shadows the one in area-groups.json")
  -- the documented override is no problem: check stays clean of area-group errors
  local check = require("tasks_nvim.check")
  res = assert(check.run({ root = root }))
  for _, f in ipairs(res.findings) do
    ok(
      f.code ~= "area-groups-invalid",
      "a setup() group that replaces the file's is no error: " .. f.message
    )
  end
  -- a broken setup() group is a warning of the config, not an error of the (fine) file
  config.merge({ area_groups = { bad = { include = {} } } })
  res = assert(check.run({ root = root }))
  local config_warn = false
  for _, f in ipairs(res.findings) do
    ok(f.code ~= "area-groups-invalid", "the file is fine: " .. f.message)
    config_warn = config_warn or (f.code == "area-groups-config" and f.severity == "warn")
  end
  ok(config_warn, "the broken setup() group is named as a warning")
  config.merge({ area_groups = { 1, 2 } })
  has(table.concat(config.ignored(), "\n"), "area_groups", "a list is no table of groups")
  config.merge({})

  -- ── `all` is the keyword for every area: no group may take it ───────────
  local _, aerr = area_groups.normalize("all", { include = { "*.nvim" } })
  has(aerr, "reserved")

  -- ── an excluded area is still an area: no unknown-member warning ────────
  write_groups({ lonely = { include = { "lib.nvim" }, exclude = { "lib.nvim" } } })
  res = assert(check.run({ root = root }))
  codes = {}
  for _, f in ipairs(res.findings) do
    if f.code:match("^area%-group") then
      codes[#codes + 1] = f.code
    end
  end
  eq(codes, { "area-group-empty" }, "excluded again is empty, not unknown")

  -- ── a rewrite of the same size in the same timestamp tick is seen ───────
  write_groups({ aaaa = { include = { "lib.nvim" } } })
  local path = root .. "/" .. area_groups.FILE
  local st = assert(vim.uv.fs_stat(path))
  ok(area_groups.get(root, "aaaa"), "first version read")
  write_groups({ bbbb = { include = { "lib.nvim" } } })
  assert(vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec))
  local st2 = assert(vim.uv.fs_stat(path))
  eq({ st2.size, st2.mtime.sec }, { st.size, st.mtime.sec }, "same size and mtime (seconds)")
  ok(area_groups.get(root, "bbbb"), "the new content wins over a size+mtime cache")
  eq(area_groups.get(root, "aaaa"), nil)

  -- ── a bare marker key is an area or a plan, never a group ───────────────
  local plan_scope = require("tasks_nvim.plan_scope")
  write_groups({ nvim = { include = { "*.nvim" } } })
  H.write(
    root .. "/lib.nvim/ROADMAP/plans/nvim.md",
    "---\ntitle: The nvim plan\nstatus: planning\n---\n\nA plan named like a group.\n"
  )
  local target = assert(plan_scope.resolve_block("nvim", root))
  eq(target.plan_id, "lib.nvim/nvim", "the plan of that slug, as before the group existed")
  target = assert(plan_scope.resolve_block("nvim", root, { area = "nvim" }))
  eq(target.area, "nvim", "an explicit area= reaches the group")
  -- `plan <group> --write` records the area= it needs (a bare `nvim` would be the plan)
  local attrs = assert(plan_scope.marker_attrs({}, {}, { area = "nvim", root = root }, "nvim"))
  eq(attrs.area, "nvim")
  attrs = assert(plan_scope.marker_attrs({}, {}, { area = "lib.nvim", root = root }, "lib.nvim"))
  eq(attrs.area, nil, "an area that is the name needs no area=")
end
