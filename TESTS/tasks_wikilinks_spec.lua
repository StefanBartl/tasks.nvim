-- TESTS/tasks_wikilinks_spec.lua -- Obsidian wikilinks in `blocked_by`, `after` and `plan` (`tasks_nvim.wikilinks`):
-- every form is read as its id, a bare `[[slug]]` is resolved over all areas (`wikilink-ambiguous` /
-- `wikilink-dangling` otherwise), `plan` / `next` / `estimate` and the index are the same as with plain ids, and
-- `set`, `new`, the dashboard's assign and `done --unblock` write references in the form `links` asks for while a
-- value the file holds keeps its form.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local config = require("tasks_nvim.config")
  local index = require("tasks_nvim.index")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local wikilinks = require("tasks_nvim.wikilinks")

  -- ── read: every form ──────────────────────────────────────────────────────
  local forms = {
    { "lib.nvim/dep-a", "plain", "lib.nvim/dep-a" },
    { "[[lib.nvim/dep-a]]", "id", "lib.nvim/dep-a" },
    { "[[lib.nvim/dep-a|Dep A]]", "id", "lib.nvim/dep-a" },
    { "[[lib.nvim/dep-a#Kontext]]", "id", "lib.nvim/dep-a" },
    { "[[ lib.nvim/dep-a | Dep A ]]", "id", "lib.nvim/dep-a" },
    { "[[dep-a]]", "slug", "dep-a" },
    { "[[dep-a|Alias]]", "slug", "dep-a" },
    { "[[2026-09-01_old]]", "slug", "old" },
    { "[[lib.nvim/ROADMAP/tasks/dep-a]]", "id", "lib.nvim/dep-a" },
    { "[[lib.nvim/ROADMAP/tasks/dep-a.md|x]]", "id", "lib.nvim/dep-a" },
    { "[[lib.nvim/ROADMAP/tasks/folder-dep/folder-dep]]", "id", "lib.nvim/folder-dep" },
    { "[[lib.nvim/ROADMAP/plans/big]]", "id", "lib.nvim/big" },
    { "[[lib.nvim/Backlog/TASKS/2026-09-01_old]]", "id", "lib.nvim/old" },
    { "[[lib.nvim/Backlog/FEATURES/2026-09-01_f/2026-09-01_f]]", "id", "lib.nvim/f" },
  }
  for _, f in ipairs(forms) do
    local kind, value = wikilinks.read(f[1])
    eq({ kind, value }, { f[2], f[3] }, "read " .. f[1])
  end
  for _, bad in ipairs({
    "[[]]",
    "[[|alias]]",
    "[[Bad Slug]]",
    "[[lib.nvim/Bad]]",
    "[[a/b/c]]",
    "[[lib.nvim/ROADMAP/tasks/a/b]]",
    "[[x]y]]",
  }) do
    eq(wikilinks.read(bad), "bad", "not an id: " .. bad)
  end

  -- a typed list (CLI `set blocked_by=...`): `[[...]]` and quotes are atoms, one pair of list brackets is dropped
  eq(wikilinks.split("[[dep-a]]"), { "[[dep-a]]" }, "one link keeps its brackets")
  eq(wikilinks.split("[[dep-a]], lib.nvim/x"), { "[[dep-a]]", "lib.nvim/x" }, "a link and an id")
  eq(
    wikilinks.split('["[[dep-a]]", "lib.nvim/x"]'),
    { "[[dep-a]]", "lib.nvim/x" },
    "the file's form"
  )
  eq(
    wikilinks.split("[[[dep-a]], [[b|B, c]]]"),
    { "[[dep-a]]", "[[b|B, c]]" },
    "a comma inside a link does not split"
  )
  eq(wikilinks.split("[a/b, c/d]"), { "a/b", "c/d" }, "plain ids as before")

  -- parse_text: an id-wikilink is its id at once, a bare slug is left for the scan
  local parsed = model.parse_text(
    F.text(F.meta("P", "open", {
      { "blocked_by", '["[[lib.nvim/dep-a|A]]", "[[dep-b]]", cascade.nvim/x]' },
      { "after", '"[[lib.nvim/ROADMAP/tasks/old]]"' },
      { "plan", '"[[big]]"' },
    })),
    { path = "/v/lib.nvim/ROADMAP/tasks/p.md", area = "lib.nvim" }
  )
  ok(parsed.valid, "wikilinks are valid values: " .. vim.inspect(parsed.errors))
  eq(parsed.blocked_by, { "lib.nvim/dep-a", "[[dep-b]]", "cascade.nvim/x" }, "blocked_by")
  eq(parsed.after, { "lib.nvim/old" }, "after: a vault path")
  eq(parsed.plan, nil, "a bare plan slug waits for the vault")
  eq(#parsed.wikilinks, 2, "two references to resolve")
  local broken = model.parse_text(
    F.text(F.meta("B", "open", { { "blocked_by", '"[[a/b/c]]"' }, { "plan", '"[[Bad X]]"' } })),
    { path = "/v/lib.nvim/ROADMAP/tasks/b.md", area = "lib.nvim" }
  )
  eq(broken.error_codes, { "bad-blocked-by", "bad-plan" }, "a malformed link is a bad value")

  -- ── two vaults: the same tasks, once with wikilinks, once with plain ids ──
  ---@param wiki boolean
  ---@return string root
  local function build(wiki)
    local root = F.vault(H)
    local function ref(plain, link)
      return wiki and link or plain
    end
    F.task(H, root, "lib.nvim", "dep-a", F.meta("Dep A", "open", { { "effort", "S" } }))
    F.task(H, root, "cascade.nvim", "dep-b", F.meta("Dep B", "open", { { "effort", "M" } }))
    H.write(
      root .. "/lib.nvim/ROADMAP/tasks/folder-dep/folder-dep.md",
      F.text(F.meta("Folder dep", "doing", { { "value", "4" } }))
    )
    H.write(root .. "/lib.nvim/Backlog/TASKS/2026-09-01_old.md", F.text(F.meta("Old", "done")))
    H.write(
      root .. "/lib.nvim/ROADMAP/plans/big.md",
      "---\ntitle: Big\nstatus: planning\nareas: [lib.nvim, cascade.nvim]\n---\n\nGoal.\n"
    )
    F.task(
      H,
      root,
      "lib.nvim",
      "linked",
      F.meta("Linked", "blocked", {
        { "effort", "L" },
        {
          "blocked_by",
          ref(
            "[lib.nvim/dep-a, cascade.nvim/dep-b, lib.nvim/folder-dep]",
            '["[[dep-a]]", "[[cascade.nvim/dep-b|Dep B]]", "[[lib.nvim/ROADMAP/tasks/folder-dep/folder-dep]]"]'
          ),
        },
        { "after", ref("lib.nvim/old", '"[[old]]"') },
        { "plan", ref("lib.nvim/big", '"[[big]]"') },
      })
    )
    local second = root .. "/cascade.nvim/ROADMAP/tasks/second.md"
    H.write(
      second,
      table.concat({
        "---",
        "title: Second",
        "status: open",
        "value: 5",
        "blocked_by:",
        ref("  - lib.nvim/linked", '  - "[[linked]]"'),
        "after:",
        ref("  - lib.nvim/dep-a", '  - "[[lib.nvim/dep-a]]"'),
        "plan: " .. ref("lib.nvim/big", '"[[lib.nvim/big|Big]]"'),
        "---",
        "",
        "A summary line.",
        "",
      }, "\n")
    )
    for _, area in ipairs({ "lib.nvim", "cascade.nvim" }) do
      assert(index.write_area(area, { root = root }))
    end
    return root
  end
  local wiki_root, plain_root = build(true), build(false)

  local linked = assert(scan.find("lib.nvim/linked", { root = wiki_root }))
  eq(
    linked.blocked_by,
    { "lib.nvim/dep-a", "cascade.nvim/dep-b", "lib.nvim/folder-dep" },
    "every form of blocked_by is its id after the scan"
  )
  eq(linked.after, { "lib.nvim/old" }, "a slug of a finished task resolves")
  eq(linked.plan, "lib.nvim/big", "a plan slug resolves to the plan file")
  eq(linked.link_problems, nil, "nothing left unresolved")
  local open = assert(scan.open_tasks({ root = wiki_root }))
  local by_id = {}
  for _, t in ipairs(open) do
    by_id[t.id] = t
  end
  eq(by_id["cascade.nvim/second"].blocked_by, { "lib.nvim/linked" }, "a block list item resolves")

  ---@param root string
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(root, argv)
    local out, err = {}, {}
    local args = vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. F.TODAY })
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return {
      code = code,
      out = table.concat(out):gsub(vim.pesc(root), "<root>"),
      err = table.concat(err),
    }
  end
  for _, argv in ipairs({
    { "plan" },
    { "plan", "--for=cascade.nvim/second" },
    { "plan", "--plan=lib.nvim/big" },
    { "next", "--n=5" },
    { "estimate" },
    { "list" },
    { "list", "--ready" },
    { "list", "--waiting" },
  }) do
    local w, p = run(wiki_root, argv), run(plain_root, argv)
    eq(w.code, p.code, table.concat(argv, " ") .. ": exit code")
    eq(w.out, p.out, table.concat(argv, " ") .. ": the same output as with plain ids")
  end
  for _, area in ipairs({ "lib.nvim", "cascade.nvim" }) do
    local rel = "/" .. area .. "/ROADMAP/TASKS.md"
    eq(H.read(wiki_root .. rel), H.read(plain_root .. rel), area .. ": the index is byte-identical")
  end
  local wiki_check = assert(check.run({ root = wiki_root }))
  local plain_check = assert(check.run({ root = plain_root }))
  local function codes(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      out[#out + 1] = f.code
    end
    return out
  end
  eq(codes(wiki_check), codes(plain_check), "check finds the same with wikilinks as with ids")

  -- ── check: ambiguous and dangling slugs; existing codes on the resolved id ─
  F.task(H, wiki_root, "lib.nvim", "common", F.meta("Common", "open"))
  F.task(H, wiki_root, "cascade.nvim", "common", F.meta("Common too", "open"))
  local odd = F.task(
    H,
    wiki_root,
    "lib.nvim",
    "odd",
    F.meta("Odd", "open", {
      { "blocked_by", '["[[common]]", "[[nowhere]]", "[[odd]]", "[[old]]"]' },
      { "after", '"[[gone]]"' },
      { "plan", '"[[no-plan]]"' },
    })
  )
  assert(index.write_area("lib.nvim", { root = wiki_root }))
  local res = assert(check.run({ root = wiki_root }))
  local mine = {}
  for _, f in ipairs(res.findings) do
    if f.path == odd then
      mine[#mine + 1] = f
    end
  end
  table.sort(mine, function(a, b)
    return a.message < b.message
  end)
  local summary = {}
  for _, f in ipairs(mine) do
    summary[#summary + 1] = f.code .. " | " .. f.message
  end
  eq(summary, {
    "wikilink-dangling | after [[gone]] names no task or plan",
    "wikilink-ambiguous | blocked_by [[common]] names several tasks, write one of them: cascade.nvim/common, lib.nvim/common",
    "wikilink-dangling | blocked_by [[nowhere]] names no task or plan",
    "blocked-by-done | blocked_by lib.nvim/old is already finished",
    "blocked-by-self | blocked_by names the task itself",
    "wikilink-dangling | plan [[no-plan]] names no task or plan",
  }, "the findings of the odd task")
  local odd_task = assert(scan.find("lib.nvim/odd", { root = wiki_root }))
  eq(
    odd_task.blocked_by,
    { "[[common]]", "[[nowhere]]", "lib.nvim/odd", "lib.nvim/old" },
    "an unresolved link stays as written, a resolved one is its id"
  )
  local wait = run(wiki_root, { "list", "--waiting", "--format=ids" })
  has(wait.out, "lib.nvim/odd", "an unresolved blocker holds the task like a dangling id")
  vim.fn.delete(odd)
  vim.fn.delete(wiki_root .. "/cascade.nvim/ROADMAP/tasks/common.md")
  assert(index.write_area("lib.nvim", { root = wiki_root }))
  assert(index.write_area("cascade.nvim", { root = wiki_root }))

  -- ── set: existing values keep their form, new ones follow `links` ─────────
  local o = { root = wiki_root, today = F.TODAY }
  local linked_path = wiki_root .. "/lib.nvim/ROADMAP/tasks/linked.md"
  local r = assert(
    mutate.set(
      "lib.nvim/linked",
      { blocked_by = { "lib.nvim/dep-a", "cascade.nvim/dep-b", "lib.nvim/folder-dep" } },
      o
    )
  )
  eq(r.changed, false, "the same ids are no change: every link keeps its form")
  assert(
    mutate.set(
      "lib.nvim/linked",
      { blocked_by = "lib.nvim/dep-a, lib.nvim/folder-dep, lib.nvim/common", status = "open" },
      o
    )
  )
  local text = H.read(linked_path)
  has(
    text,
    'blocked_by: ["[[dep-a]]", "[[lib.nvim/ROADMAP/tasks/folder-dep/folder-dep]]", lib.nvim/common]\n',
    "plain mode: the kept links unchanged, the new id plain"
  )
  has(text, 'after: "[[old]]"\nplan: "[[big]]"\n', "the fields not in the patch are untouched")
  linked = assert(scan.find("lib.nvim/linked", { root = wiki_root }))
  eq(
    linked.blocked_by,
    { "lib.nvim/dep-a", "lib.nvim/folder-dep", "lib.nvim/common" },
    "and it reads back as ids"
  )

  local wo = { root = wiki_root, today = F.TODAY, links = "wikilink" }
  assert(
    mutate.set(
      "lib.nvim/linked",
      { blocked_by = { "lib.nvim/dep-a", "lib.nvim/common", "cascade.nvim/dep-b" } },
      wo
    )
  )
  text = H.read(linked_path)
  has(
    text,
    'blocked_by: ["[[dep-a]]", lib.nvim/common, "[[dep-b]]"]\n',
    "wikilink mode: a plain id the file holds stays plain, the new id is [[slug]]"
  )
  -- a slug in two areas: the vault path with the id as alias (Obsidian resolves it, so does the reader)
  F.task(H, wiki_root, "cascade.nvim", "dep-a", F.meta("Another dep-a", "open"))
  assert(mutate.set("lib.nvim/linked", { after = "lib.nvim/dep-a" }, wo))
  has(
    H.read(linked_path),
    'after: "[[lib.nvim/ROADMAP/tasks/dep-a|lib.nvim/dep-a]]"\n',
    "an ambiguous slug is written as the path"
  )
  linked = assert(scan.find("lib.nvim/linked", { root = wiki_root }))
  eq(linked.after, { "lib.nvim/dep-a" }, "the path form reads back")
  eq(linked.link_problems, {
    {
      code = "wikilink-ambiguous",
      field = "blocked_by",
      raw = "[[dep-a]]",
      candidates = { "cascade.nvim/dep-a", "lib.nvim/dep-a" },
    },
  }, "the old [[dep-a]] is ambiguous now")
  vim.fn.delete(wiki_root .. "/cascade.nvim/ROADMAP/tasks/dep-a.md")

  -- a value given as a wikilink is written as given; a bare slug in the patch is resolved, an ambiguous one refused
  assert(mutate.set("lib.nvim/linked", { after = "[[cascade.nvim/dep-b|B]]" }, o))
  has(H.read(linked_path), 'after: "[[cascade.nvim/dep-b|B]]"\n', "a typed link is kept as typed")
  local _, aerr = mutate.set("lib.nvim/linked", { after = "[[common]]" }, o)
  eq(aerr, nil, "[[common]] names one task now")
  F.task(H, wiki_root, "cascade.nvim", "common", F.meta("Common too", "open"))
  local none, serr = mutate.set("lib.nvim/linked", { blocked_by = "[[common]]" }, o)
  eq(none, nil, "an ambiguous slug is refused")
  has(serr, "cascade.nvim/common, lib.nvim/common", "with the candidates")
  none, serr = mutate.set("lib.nvim/linked", { plan = "[[nope]]" }, o)
  eq(none, nil, "a dangling plan slug is refused")
  has(serr, "wikilink-dangling")
  vim.fn.delete(wiki_root .. "/cascade.nvim/ROADMAP/tasks/common.md")
  -- a compare-and-set on `plan` compares the id the caller was shown, not the link the file holds
  local cas, cas_err = mutate.set(
    "lib.nvim/linked",
    { summary = "Checked" },
    { root = wiki_root, today = F.TODAY, expect = { key = "plan", value = "lib.nvim/big" } }
  )
  ok(cas, "expect on a [[slug]] plan: " .. tostring(cas_err))
  -- the CLI takes the same values
  local c = run(wiki_root, { "set", "lib.nvim/linked", "after=[[dep-a]],[[old]]" })
  eq(c.code, 0, c.err)
  has(H.read(linked_path), 'after: ["[[dep-a]]", "[[old]]"]\n', "CLI: the links as typed")
  linked = assert(scan.find("lib.nvim/linked", { root = wiki_root }))
  eq(linked.after, { "lib.nvim/dep-a", "lib.nvim/old" }, "CLI: read back as ids")
  -- the write door of the app (tasks-ops/1): a bare slug is resolved before the edges are judged
  local door_text = require("tasks_nvim.api").call(
    "ops",
    vim.json.encode({
      ops = { { op = "set", id = "lib.nvim/linked", patch = { after = { "[[dep-b]]" } } } },
    }),
    { root = wiki_root, today = F.TODAY }
  )
  local door = vim.json.decode(door_text)
  eq(door.results[1].ok, true, "ops set with [[dep-b]]: " .. door_text)
  has(H.read(linked_path), 'after: "[[dep-b]]"\n', "ops: written as given")

  -- the switch from setup(): the same writer
  config.merge({ links = "wikilink" })
  assert(mutate.set("lib.nvim/linked", { after = { "cascade.nvim/dep-b", "lib.nvim/old" } }, o))
  config.merge({ links = "plain" })
  has(H.read(linked_path), 'after: ["[[dep-b]]", "[[old]]"]\n', "setup({ links }) is read")
  eq(wikilinks.mode({}), "plain", "back to plain")
  config.merge({ links = "wiki" })
  eq(config.get().links, "plain", "a wrong word is ignored, the default stays")
  has(table.concat(config.ignored(), "\n"), '`links` must be one of "plain", "wikilink"')

  -- ── new: after and plan in the form asked for ────────────────────────────
  local made = assert(mutate.new("lib.nvim", {
    root = wiki_root,
    today = F.TODAY,
    title = "Made",
    after = "lib.nvim/dep-a",
    plan = "lib.nvim/big",
    links = "wikilink",
    index = false,
  }))
  text = H.read(made.path)
  has(text, 'after: ["[[dep-a]]"]\n', "new: after as a wikilink")
  has(text, 'plan: "[[big]]"\n', "new: plan as a wikilink")
  local made_plain = assert(mutate.new("lib.nvim", {
    root = wiki_root,
    today = F.TODAY,
    title = "Made plain",
    after = "[[dep-a]]",
    plan = "[[big]]",
    index = false,
  }))
  text = H.read(made_plain.path)
  has(text, 'after: ["[[dep-a]]"]\nplan: "[[big]]"\n', "new: typed links kept in plain mode")
  local made_ids = assert(mutate.new("lib.nvim", {
    root = wiki_root,
    today = F.TODAY,
    title = "Made ids",
    after = "lib.nvim/dep-a",
    plan = "lib.nvim/big",
    index = false,
  }))
  has(H.read(made_ids.path), "after: [lib.nvim/dep-a]\nplan: lib.nvim/big\n", "new: plain ids")

  -- ── new: a slug another area has turns the bare [[slug]] links into ambiguous ones, named at once ─
  eq(made_ids.ambiguous, nil, "a slug new to the vault makes nothing ambiguous")
  local twin = assert(mutate.new("cascade.nvim", {
    root = wiki_root,
    today = F.TODAY,
    title = "Another dep-a",
    slug = "dep-a",
    index = false,
  }))
  eq(twin.ambiguous, {
    slug = "dep-a",
    ids = { "cascade.nvim/dep-a", "lib.nvim/dep-a" },
    tasks = { "lib.nvim/linked", "lib.nvim/made", "lib.nvim/made-plain" },
  }, "new names the tasks whose [[dep-a]] is ambiguous now")
  local amb_check = assert(check.run({ root = wiki_root }))
  local amb_paths = {}
  for _, f in ipairs(amb_check.findings) do
    if f.code == "wikilink-ambiguous" then
      amb_paths[#amb_paths + 1] = vim.fs.basename(f.path)
    end
  end
  table.sort(amb_paths)
  eq(amb_paths, { "linked.md", "made-plain.md", "made.md" }, "the same tasks check reports")
  vim.fn.delete(twin.path)
  local cli_new =
    run(wiki_root, { "new", "cascade.nvim", "Another dep-a", "--slug=dep-a", "--no-index" })
  eq(cli_new.code, 0, cli_new.err)
  has(
    cli_new.err,
    "warn: [[dep-a]] now names cascade.nvim/dep-a and lib.nvim/dep-a: wikilink-ambiguous in lib.nvim/linked, lib.nvim/made, lib.nvim/made-plain",
    "CLI: the warning names them"
  )
  -- a slug another area has, but no task names it as [[slug]]: nothing to say
  F.task(H, wiki_root, "lib.nvim", "third-home", F.meta("Third home", "open"))
  local third = assert(mutate.new("cascade.nvim", {
    root = wiki_root,
    today = F.TODAY,
    title = "Third home",
    index = false,
  }))
  eq(third.ambiguous, nil, "no task names [[third-home]]: nothing to warn about")
  vim.fn.delete(third.path)
  vim.fn.delete(wiki_root .. "/lib.nvim/ROADMAP/tasks/third-home.md")
  vim.fn.delete(wiki_root .. "/cascade.nvim/ROADMAP/tasks/dep-a.md")

  -- ── move: a bare [[slug]] still names the moved task, an [[area/slug]] is rewritten ─
  F.task(H, wiki_root, "lib.nvim", "mover", F.meta("Mover", "open"))
  local fan1 = F.task(
    H,
    wiki_root,
    "lib.nvim",
    "fan-one",
    F.meta("Fan one", "open", { { "blocked_by", '"[[mover]]"' } })
  )
  local fan2 = F.task(
    H,
    wiki_root,
    "lib.nvim",
    "fan-two",
    F.meta("Fan two", "open", { { "blocked_by", '"[[lib.nvim/mover|M]]"' } })
  )
  assert(index.write_area("lib.nvim", { root = wiki_root }))
  local moved = assert(require("tasks_nvim.moves").move("lib.nvim/mover", "cascade.nvim", {
    root = wiki_root,
    today = F.TODAY,
    checkpoint_dir = H.tmpdir() .. "/checkpoints",
  }))
  eq(moved.new_id, "cascade.nvim/mover")
  has(H.read(fan1), 'blocked_by: "[[mover]]"\n', "the bare link still fits and is kept")
  has(H.read(fan2), "blocked_by: cascade.nvim/mover\n", "the old id is rewritten (plain mode)")
  for _, id in ipairs({ "lib.nvim/fan-one", "lib.nvim/fan-two" }) do
    eq(
      assert(scan.find(id, { root = wiki_root })).blocked_by,
      { "cascade.nvim/mover" },
      id .. " waits on the moved task"
    )
  end

  -- ── the dashboard's assign (P) and done --unblock ─────────────────────────
  local core = require("tasks_nvim.ui.dash_core")
  config.merge({ links = "wikilink" })
  local applied = core.apply_set(
    core.assign_steps({ { id = "lib.nvim/dep-a" } }, "lib.nvim/big", nil),
    { root = wiki_root, today = F.TODAY }
  )
  config.merge({ links = "plain" })
  eq(#applied.failed, 0, vim.inspect(applied.failed))
  has(
    H.read(wiki_root .. "/lib.nvim/ROADMAP/tasks/dep-a.md"),
    'plan: "[[big]]"\n',
    "assign writes the plan as a wikilink"
  )
  local waiter = F.task(
    H,
    wiki_root,
    "lib.nvim",
    "waiter",
    F.meta("Waiter", "blocked", { { "blocked_by", '"[[dep-b]]"' } })
  )
  assert(index.write_area("lib.nvim", { root = wiki_root }))
  local done = run(wiki_root, { "done", "cascade.nvim/dep-b", "--unblock" })
  eq(done.code, 0, done.err)
  has(done.out, "unblocked\tlib.nvim/waiter", "the waiter is freed through its wikilink")
  text = H.read(waiter)
  has(text, "status: open\n", "and set to open")
  has(text, 'blocked_by: "[[dep-b]]"\n', "its wikilink is not rewritten")
  lacks(text, "cascade.nvim/dep-b", "no id was written")
end
