-- TESTS/tasks_rules_import_spec.lua -- `import --from-rules` and `bootstrap`: a work list of rules.nvim
-- (`rules-work-list/1`) becomes tasks, a dry run first, a second run adds nothing, a finished task stays finished,
-- and what comes from the foreign document is cleaned before it reaches a file.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local rules_import = require("tasks_nvim.rules_import")

  local root = F.vault(H)
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local dir = H.tmpdir()

  ---@param argv string[]
  ---@param stdin? string
  ---@return { code: integer, out: string, err: string }
  local function run(argv, stdin)
    local out, err = {}, {}
    local args = vim.list_extend(vim.deepcopy(argv), common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
      stdin = stdin and {
        read = function()
          return stdin
        end,
      } or nil,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  ---@param target string
  ---@param entries table[]
  ---@param extra? table
  ---@return string path
  local function work_list(target, entries, extra)
    local doc = vim.tbl_extend("force", {
      schema = "rules-work-list",
      schema_version = 1,
      generated_at = "2026-10-17T12:00:00Z",
      rulesets = {
        { name = "@vault/lua", source = "E:/repos/rules-vault/rulesets/lua", origin = "project" },
      },
      target = { path = "E:/repos/" .. target, commit = "6f09dcb0123456789abc" },
      scope = { kind = "gate", gate = "review", families = { "ERR", "DOC" } },
      entries = entries,
    }, extra or {})
    local path = ("%s/%s-%d.json"):format(dir, target, vim.uv.hrtime())
    H.write(path, vim.json.encode(doc))
    return path
  end

  local ERR = {
    rule_id = "ERR-03",
    family = "ERR",
    severity = "critical",
    kind = "automated",
    status = "fail",
    ruleset = "@vault/lua",
    title = "`ERR-03` — pcall results are checked \27[31mred\27[0m",
    section = "1. Errors",
    description = "A pcall whose result nobody looks at hides the error.\n## Akzeptanz\n- [x] forged",
    source = { file = "E:/repos/rules-vault/rulesets/lua/regeln/ERR.md", line = 41 },
    findings = {
      { file = "lua/x.lua", line = 12, text = "pcall(f) -- `tick`" },
      { file = "C:/Users/someone/elsewhere.lua", line = 3, text = "pcall(g)" },
    },
  }
  local DOC = {
    rule_id = "DOC-01",
    family = "DOC",
    severity = "recommended",
    kind = "manual",
    status = "unchecked",
    title = "`DOC-01` — the README says what the plugin does",
    description = "",
    source = { file = "E:/repos/rules-vault/rulesets/lua/regeln/DOC.md", line = 7 },
    findings = {},
  }
  local PASS = {
    rule_id = "LUA-10",
    family = "LUA",
    severity = "critical",
    kind = "automated",
    status = "pass",
    title = "x",
    description = "",
    findings = {},
  }
  local WAIVED = {
    rule_id = "SEC-40",
    family = "SEC",
    severity = "critical",
    kind = "automated",
    status = "waived",
    title = "x",
    description = "",
    findings = { { file = "vendor/a.lua", line = 1, text = "" } },
    waiver = { reason = "vendored code", suppressed = 1 },
  }
  local EVIL =
    { rule_id = "../../evil", status = "fail", kind = "automated", title = "", description = "" }

  local list = work_list("lib.nvim", { ERR, DOC, PASS, WAIVED, EVIL })

  ---@return table<string, Tasks.Task>
  local function ruleset_tasks()
    local out = {}
    for _, t in ipairs(assert(scan.area("lib.nvim", { root = root }))) do
      if t.meta.rules then
        out[t.id] = t
      end
    end
    return out
  end

  -- ── a dry run is the default and writes nothing ───────────────────────────
  local dry = run({ "import", "lib.nvim", "--from-rules=" .. list })
  eq(dry.code, 0, dry.err)
  has(dry.out, "would-create\tlib.nvim/err-03-pcall-results-are-checked-red\tERR-03")
  has(dry.out, "would-create\tlib.nvim/doc-01-the-readme-says-what-the-plugin-does\tDOC-01")
  has(dry.out, "waived\t-\tSEC-40\tvendored code")
  has(dry.out, "invalid\t-\t-\tentry 5: rule_id")
  has(dry.out, "import\tdry-run\t2 to create, 0 exist, 0 finished, 1 waived, 1 pass, 1 invalid")
  has(dry.out, "--apply creates the tasks")
  eq(vim.tbl_count(ruleset_tasks()), 0, "a dry run creates no task")
  eq(
    run({ "import", "lib.nvim", "--from-rules=" .. list, "--dry-run" }).code,
    0,
    "--dry-run says it too"
  )

  -- ── --apply creates one task per failing or unjudged rule ─────────────────
  local applied = run({ "import", "lib.nvim", "--from-rules=" .. list, "--apply" })
  eq(applied.code, 0, applied.err)
  has(applied.out, "created\tlib.nvim/err-03-pcall-results-are-checked-red\tERR-03")
  has(applied.out, "import\tapplied\t2 created")
  local made = ruleset_tasks()
  eq(vim.tbl_count(made), 2)
  local err_task = assert(made["lib.nvim/err-03-pcall-results-are-checked-red"])
  eq(err_task.valid, true, vim.inspect(err_task.errors))
  eq(err_task.title, "ERR-03: pcall results are checked red", "the id in front, no ANSI sequence")
  eq(err_task.meta.prio, "1", "critical is prio 1")
  eq(err_task.meta.effort, "S", "an automated rule is S")
  eq(err_task.category, { "ruleset" })
  local text = H.read(err_task.path)
  has(text, "rules: [ERR-03]")
  has(text, "rules-target:lib.nvim")
  has(text, "lua/x.lua:12")
  has(text, "`regeln/ERR.md:41`", "the rule's file relative to its ruleset")
  has(text, "\\## Akzeptanz", "a heading in the foreign text is escaped")
  has(text, "1 Fundstelle(n) außerhalb des Projekts")
  lacks(text, "E:/repos", "no path of this machine")
  lacks(text, "someone", "no path outside the target")
  lacks(text, "\27", "no escape character")
  lacks(text, "`tick`", "a backtick in a finding does not close the code span")
  local doc_task = assert(made["lib.nvim/doc-01-the-readme-says-what-the-plugin-does"])
  eq(doc_task.meta.prio, "2", "recommended is prio 2")
  eq(doc_task.meta.effort, "M", "a manual rule is M")
  local doc_text = H.read(doc_task.path)
  has(doc_text, "Von Hand geprüft")
  -- an entry that names no ruleset: its file by its bare name, not by the path of this machine
  has(doc_text, "`DOC.md:7`")
  lacks(doc_text, "E:/repos")
  has(H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"), "ERR-03", "the index is written")

  -- ── a second run is empty ─────────────────────────────────────────────────
  local again = run({ "import", "lib.nvim", "--from-rules=" .. list, "--apply" })
  eq(again.code, 0, again.err)
  has(again.out, "exists\tlib.nvim/err-03-pcall-results-are-checked-red\tERR-03")
  has(again.out, "import\tapplied\t0 created, 2 exist")
  eq(vim.tbl_count(ruleset_tasks()), 2, "no duplicate")

  -- ── a finished task is not opened again ───────────────────────────────────
  assert(mutate.done(doc_task.id, { root = root, today = F.TODAY, date = F.TODAY }))
  local after_done = run({ "import", "lib.nvim", "--from-rules=" .. list, "--apply" })
  has(after_done.out, "done\t" .. doc_task.id .. "\tDOC-01\tfinished, not opened again")
  has(after_done.out, "0 created, 1 exist, 1 finished")
  eq(vim.tbl_count(ruleset_tasks()), 1)

  -- ── a rule that passes now names its open task ────────────────────────────
  local passing =
    work_list("lib.nvim", { vim.tbl_extend("force", ERR, { status = "pass", findings = {} }) })
  has(
    run({ "import", "lib.nvim", "--from-rules=" .. passing }).out,
    "passes\t" .. err_task.id .. "\tERR-03"
  )

  -- ── another project is another key; a task written by hand counts for all ─
  assert(
    mutate.new(
      "lib.nvim",
      { root = root, today = F.TODAY, title = "By hand", rules = { "LUA-99" } }
    )
  )
  local other = work_list("other.nvim", {
    ERR,
    vim.tbl_extend("force", DOC, { rule_id = "LUA-99", title = "`LUA-99` — by hand" }),
  })
  local o = run({ "import", "lib.nvim", "--from-rules=" .. other })
  has(
    o.out,
    "would-create\tlib.nvim/err-03-pcall-results-are-checked-red-2\tERR-03",
    "a task per project"
  )
  has(o.out, "exists\tlib.nvim/by-hand\tLUA-99", "a task without a target counts for every project")
  has(o.err, "note: the work list checked other.nvim, its tasks go to the area lib.nvim")

  -- ── the work list on stdin ────────────────────────────────────────────────
  local piped = run({ "import", "lib.nvim", "--from-rules=-" }, H.read(list))
  eq(piped.code, 0, piped.err)
  has(piped.out, "exists\tlib.nvim/err-03-pcall-results-are-checked-red\tERR-03")

  -- ── what is refused ───────────────────────────────────────────────────────
  ---@param path string
  ---@param needle string
  local function refused(path, needle)
    local r = run({ "import", "lib.nvim", "--from-rules=" .. path, "--apply" })
    eq(r.code, 1, r.out)
    has(r.err, needle)
  end
  refused(
    work_list("lib.nvim", { ERR }, { schema = "rules-export" }),
    "not a work list of rules.nvim"
  )
  refused(
    work_list("lib.nvim", { ERR }, { schema_version = 2 }),
    "work list version 2 is not known"
  )
  refused(
    work_list("lib.nvim", { ERR }, { target = { path = "E:/repos/bad name;rm" } }),
    "no usable target"
  )
  local broken = dir .. "/broken.json"
  H.write(broken, "{ not json")
  refused(broken, "no JSON object")
  refused(dir .. "/missing.json", "cannot read the work list")
  local saved = rules_import.MAX_ENTRIES
  rules_import.MAX_ENTRIES = 1
  refused(list, "more than 1 entries")
  rules_import.MAX_ENTRIES = saved
  eq(
    vim.tbl_count(ruleset_tasks()),
    2,
    "a refused list creates nothing (ERR-03 and the one by hand)"
  )

  local unknown = run({ "import", "no-such-area", "--from-rules=" .. list, "--apply" })
  eq(unknown.code, 1)
  has(unknown.err, "no-such-area")
  eq(run({ "import", "lib.nvim" }).code, 2, "import needs --from-rules")
  eq(run({ "import", "--from-rules=" .. list }).code, 2, "import needs the area")
  eq(run({ "import", "lib.nvim", "--from-rules=" .. list, "--apply", "--dry-run" }).code, 2)

  -- ── bootstrap: a new area, a dry run first ────────────────────────────────
  local bdry = run({ "bootstrap", "fresh.nvim", "--from-rules=" .. list })
  eq(bdry.code, 0, bdry.err)
  has(bdry.out, "would-make\tfresh.nvim/ROADMAP/tasks/")
  has(bdry.out, "would-make\tfresh.nvim/README.md")
  has(bdry.out, "would-create\tfresh.nvim/err-03-pcall-results-are-checked-red\tERR-03")
  ok(not H.exists(root .. "/fresh.nvim"), "a dry run makes no folder")

  local bapply = run({ "bootstrap", "fresh.nvim", "--from-rules=" .. list, "--apply" })
  eq(bapply.code, 0, bapply.err)
  for _, p in ipairs({
    "fresh.nvim/ROADMAP/tasks/",
    "fresh.nvim/Backlog/FEATURES/",
    "fresh.nvim/Backlog/TASKS/",
    "fresh.nvim/README.md",
    "fresh.nvim/Backlog/README.md",
    "fresh.nvim/ROADMAP/TASKS.md",
  }) do
    has(bapply.out, "made\t" .. p)
  end
  has(bapply.out, "created\tfresh.nvim/err-03-pcall-results-are-checked-red\tERR-03")
  has(H.read(root .. "/fresh.nvim/README.md"), "# fresh.nvim")

  -- an existing area is completed, nothing in it overwritten
  H.write(root .. "/fresh.nvim/README.md", "# mine\n")
  local bagain = run({ "bootstrap", "fresh.nvim", "--apply" })
  eq(bagain.code, 0, bagain.err)
  lacks(bagain.out, "made\t")
  eq(H.read(root .. "/fresh.nvim/README.md"), "# mine\n", "an existing README stays")
  eq(run({ "bootstrap", "TOOLS", "--apply" }).code, 1, "a folder that is never an area")
  eq(run({ "bootstrap", "_hidden" }).code, 1)

  -- ── without rules.nvim: the coupling is the file alone ────────────────────
  eq(package.loaded["rules"], nil, "rules.nvim is never required")
end
