-- TESTS/tasks_lists_spec.lua -- tasks_nvim.lists (named lists: validation, three sources, saving) and their use
-- in `tasks list @name` / `tasks lists`.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local config = require("tasks_nvim.config")
  local lists = require("tasks_nvim.lists")
  local cli = require("tasks_nvim.cli")
  local core = require("tasks_nvim.ui.dash_core")

  local before = vim.deepcopy(config.get())
  lists.set_path(H.tmpdir() .. "/state/lists.json")

  ---@param name string
  ---@param def any
  ---@return string|nil
  local function problem(name, def)
    local _, e = lists.normalize(name, def)
    return e
  end
  local err

  -- ── a definition is checked like the command line, and the complaint names the list ──
  local clean = lists.normalize(
    "mine",
    { effort = "<=S", value = 4, desc = "small and worth it", sort = "roi" }
  )
  eq(
    clean,
    { effort = "<=S", value = "4", desc = "small and worth it", sort = "roi" },
    "numbers become strings"
  )
  err = problem("mine", { effort = "huge" })
  has(err, "list 'mine'")
  has(err, "effort")
  err = problem("mine", { colour = "red", zzz = 1 })
  has(err, "unknown option(s): colour, zzz")
  err = problem("mine", { blocked = "yes" })
  has(err, "`blocked` must be true or false")
  err = problem("mine", { sort = "random" })
  has(err, "list 'mine'")
  err = problem("mine", { readiness = "soon" })
  has(err, "readiness")
  err = problem("mine", { quick_win = true, value = ">=2" })
  has(err, "do not combine", "the shorthand and an explicit bound exclude each other")
  err = problem("bad name", {})
  has(err, "a list name is letters")
  err = problem("x", { desc = "two\nlines" })
  has(err, "control character", "a description is one line")
  err = problem("x", { tag = "a\tb" })
  has(err, "control character", "a tab would split a TSV row")
  err = problem("x", { tag = "evil\27[2J" })
  has(err, "control character", "an escape byte would reach the terminal")
  err = problem("x", { tag = string.rep("t", 201) })
  has(err, "longer than")
  for _, bad in ipairs({ "../x", "a/b", "..", "@x", "-x", "C:\\x" }) do
    err = problem("x", { area = bad })
    has(err, "`area`", "area " .. bad)
  end
  ok(lists.normalize("x", { area = "docmap-desktop" }), "a real area name passes")
  err = problem("x", "not a table")
  has(err, "table of options")

  -- ── resolve: the filter, the sort and the area ──
  local r = lists.resolve(lists.normalize("r", {
    value = ">=4",
    effort = "<=S",
    readiness = "ready",
    sort = "roi",
    area = "lib.nvim",
  }))
  eq(
    { r.filter.value_min, r.filter.effort_max, r.filter.readiness, r.sort, r.area },
    { 4, "S", "ready", "roi", "lib.nvim" }
  )
  eq(lists.resolve(lists.normalize("d", {})).sort, "default", "no sort: the default order")

  -- ── words and from_filter are inverse enough to round-trip ──
  eq(
    lists.words({
      effort = "<=S",
      value = ">=4",
      sort = "roi",
      readiness = "ready",
      quick_win = true,
    }),
    { "--effort=<=S", "--value=>=4", "--quick-win", "--ready", "--sort=roi" }
  )
  local def = lists.from_filter({
    status = { "open", "doing" },
    prio_max = 2,
    effort_max = "M",
    value_min = 3,
    tag = { "ui" },
  }, "prio-effort", "lib.nvim", "from a filter")
  eq(def, {
    desc = "from a filter",
    area = "lib.nvim",
    status = "open,doing",
    prio = "<=2",
    effort = "<=M",
    value = ">=3",
    tag = "ui",
    sort = "prio-effort",
  })
  ok(lists.normalize("rt", def), "what the dashboard saves is a valid list")
  eq(
    lists.from_filter({ value_min = 4, effort_max = "S" }).quick_win,
    true,
    "the definition is saved as `quick_win`"
  )
  eq(
    lists.from_filter({ value_min = 4, effort_max = "S" }).value,
    nil,
    "... not as two bounds that would not follow the config"
  )
  eq(lists.from_filter({}, "default").sort, nil, "the default sort is not written")

  -- ── three sources ──
  local names = vim.tbl_map(function(e)
    return e.name
  end, (lists.all()))
  eq(names, { "quick-wins", "small-and-important", "unestimated" }, "the built-in lists, sorted")
  eq(lists.get("quick-wins").source, "builtin")
  local _, gerr = lists.get("nope")
  has(gerr, "unknown list 'nope'")
  has(gerr, "quick-wins")

  ok(lists.save("mine", { effort = "<=S", value = ">=3", sort = "roi" }))
  eq(lists.get("mine").source, "saved")
  ok(H.exists(lists.path()), "the state file is written")
  eq(lists.get("mine").def.value, ">=3")
  ok(lists.save("quick-wins", { value = ">=5" }), "a saved list may replace a built-in one")
  eq(lists.get("quick-wins").source, "saved")
  eq(lists.get("quick-wins").def.value, ">=5")

  config.merge({
    lists = {
      mine = { prio = "1" },
      cfg = { kind = "bug", desc = "bugs" },
      broken = { effort = "huge" },
    },
  })
  local entry = lists.get("mine")
  eq(
    { entry.source, entry.def.prio },
    { "config", "1" },
    "the config wins over the saved list of that name"
  )
  local _, notes = lists.all()
  ok(
    vim.iter(notes):any(function(n)
      return n:find("shadows the saved one", 1, true) ~= nil
    end),
    "the shadowing is reported"
  )
  ok(
    vim.iter(notes):any(function(n)
      return n:find("setup({ lists })", 1, true) and n:find("list 'broken'", 1, true)
    end),
    "a broken list of the config is skipped and named"
  )
  ok(not lists.get("broken"), "... and not offered")
  local sok, serr = lists.save("cfg", { kind = "feature" })
  ok(
    not sok and serr:find("defined in setup()", 1, true),
    "a config list cannot be replaced from here"
  )
  local dok, derr = lists.delete("cfg")
  ok(not dok and derr:find("defined in setup()", 1, true), "... nor deleted")
  config.merge({ lists = {} })
  ok(lists.get("cfg") == nil, "a later setup({ lists }) replaces the earlier set")

  ok(lists.rename("quick-wins", "qw"), "a saved list can be renamed")
  ok(not lists.rename("nothing", "x2"))
  ok(not lists.rename("qw", "bad name"))
  ok(lists.delete("qw"))
  eq(
    lists.get("quick-wins").source,
    "builtin",
    "deleting the replacement brings the built-in list back"
  )
  local bok, berr = lists.delete("unestimated")
  ok(not bok and berr:find("built in", 1, true))
  lists.delete("mine")

  -- ── the state file: a bad list never costs the rest, junk is never overwritten ──
  H.write(
    lists.path(),
    vim.json.encode({ version = 1, lists = { good = { prio = "1" }, bad = { effort = "huge" } } })
  )
  local saved, status, snotes = lists.load()
  eq(status, "ok")
  eq(saved, { good = { prio = "1" } }, "only the valid list is used")
  has(snotes[1], "list 'bad'")
  H.write(lists.path(), "this is not json")
  _, status = lists.load()
  eq(status, "corrupt")
  local cok, cerr = lists.save("x", { prio = "1" })
  ok(not cok and cerr:find("cannot be read", 1, true), "a corrupt file is never written over")
  eq(H.read(lists.path()), "this is not json", "... and stays as it is")
  vim.fn.delete(lists.path())
  ok(lists.save("x", { prio = "1" }), "a missing file is simply created")

  -- an empty file (`touch`) is an empty set, not damage
  H.write(lists.path(), "")
  local empty, estatus = lists.load()
  eq({ next(empty), estatus }, { nil, "ok" })
  ok(lists.save("y", { prio = "2" }), "... and can be saved to")

  -- the file is read once per change: a second load answers from memory, a change (ours or somebody's) is seen
  H.write(lists.path(), vim.json.encode({ version = 1, lists = { first = { prio = "1" } } }))
  eq(lists.get("first").def.prio, "1")
  H.write(
    lists.path(),
    vim.json.encode({ version = 1, lists = { second = { prio = "2", desc = "other length" } } })
  )
  ok(lists.get("second") ~= nil and lists.get("first") == nil, "a changed file is read again")
  ok(lists.save("third", { prio = "3" }))
  ok(lists.get("third") ~= nil, "our own save is visible at once")
  local copy = lists.load()
  copy.third.prio = "mutated"
  eq(lists.get("third").def.prio, "3", "what load hands out is a copy of the cache")

  -- ── the dashboard's quick-win chip uses the same rule ──
  ok(core.is_quick_win_filter({ value_min = 4, effort_max = "S" }))

  -- ── tasks list @name, tasks lists, in-process on a throw-away vault ──
  local root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "small-ok",
    F.meta("Small and worth it", "open", { { "prio", "1" }, { "effort", "XS" }, { "value", "5" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "small-low",
    F.meta("Small, little value", "open", { { "prio", "3" }, { "effort", "XS" }, { "value", "1" } })
  )
  F.task(
    H,
    root,
    "cascade.nvim",
    "big",
    F.meta("Big", "open", { { "prio", "1" }, { "effort", "L" }, { "value", "5" } })
  )
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, errs = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, common)
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end

  vim.fn.delete(lists.path())
  local res = run({
    "lists",
    "save",
    "worth",
    "--value=>=4",
    "--effort=<=S",
    "--sort=roi",
    "--desc=small and worth it",
  })
  eq(res.code, 0, res.err)
  has(res.out, "saved\tworth\t")
  res = run({ "lists" })
  has(res.out, "worth\tsaved\tsmall and worth it")
  has(res.out, "quick-wins\tbuiltin\t")
  res = run({ "lists", "show", "worth" })
  has(res.out, "tasks list --effort=<=S --value=>=4 --sort=roi")
  res = run({ "list", "@worth" })
  eq(res.code, 0, res.err)
  has(res.out, "lib.nvim/small-ok")
  lacks(res.out, "small-low")
  lacks(res.out, "cascade.nvim/big")
  res = run({ "list", "@worth", "--prio=3" })
  lacks(res.out, "small-ok", "an option you type wins over the list")
  res = run({ "list", "@quick-wins" })
  has(res.out, "lib.nvim/small-ok", "a built-in list")
  res = run({ "estimate", "@worth" })
  has(res.out, "1 task", "the list scopes estimate too")
  res = run({ "list", "@nope" })
  eq(res.code, 2)
  has(res.err, "unknown list 'nope'")
  -- a word of the list that a command has no use for is an error, not a quietly wider answer
  res = run({ "estimate", "@small-and-important" })
  eq(res.code, 2)
  has(res.err, "--ready, which `estimate` does not take")
  res = run({ "plan", "@unestimated" })
  eq(res.code, 0, "plan takes what unestimated sets: " .. res.err)
  lists.save("waits", { readiness = "waiting" })
  res = run({ "plan", "@waits" })
  eq(res.code, 2)
  has(res.err, "--waiting, which `plan` does not take")
  lists.save("sorted", { value = ">=4", sort = "roi" })
  res = run({ "estimate", "@sorted" })
  eq(res.code, 0, "a sort order is the one thing a command may leave over: " .. res.err)
  lists.save("elsewhere", { area = "no-such-area" })
  res = run({ "list", "@elsewhere" })
  eq(res.code, 1, "an area the vault does not have")
  has(res.err, "unknown area")
  lists.delete("waits")
  lists.delete("sorted")
  lists.delete("elsewhere")
  res = run({ "lists", "save", "bad", "--prio=9" })
  eq(res.code, 1)
  has(res.err, "list 'bad'")
  res = run({ "lists", "save" })
  eq(res.code, 2, "a name is required")
  res = run({ "lists", "rename", "worth", "worthy" })
  has(res.out, "renamed\tworth\tworthy")
  res = run({ "lists", "delete", "worthy" })
  has(res.out, "deleted\tworthy")
  res = run({ "lists", "delete", "worthy" })
  eq(res.code, 1)
  res = run({ "lists", "frobnicate" })
  eq(res.code, 2)

  -- ── the dashboard menu (`gl`): apply, save the current view, delete ──
  local dash = require("tasks_nvim.ui.dash")
  ---@param state table
  ---@param choose fun(items: any[], opts: table): any
  ---@param typed? string
  ---@return boolean closed
  local function menu(state, choose, typed)
    local select_orig, input_orig = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, cb)
      cb(choose(items, opts or {}))
    end
    vim.ui.input = function(_, cb)
      cb(typed)
    end
    local closed = false
    local called, cerr2 = pcall(dash.lists_menu, state, function()
      closed = true
    end)
    vim.ui.select, vim.ui.input = select_orig, input_orig
    ok(called, tostring(cerr2))
    return closed
  end
  ---@param prefix string
  ---@return fun(items: any[], opts: table): any
  local function pick(prefix)
    return function(items, opts)
      for _, item in ipairs(items) do
        local label = type(item) == "string" and item or (item.label or item.name or "")
        if label:find(prefix, 1, true) == 1 then
          return item
        end
      end
      error(("no item starts with %q (prompt %s)"):format(prefix, tostring(opts.prompt)))
    end
  end

  vim.fn.delete(lists.path())
  local state = { root = root, filter = {}, sort = "default", persist = false }
  ok(menu(state, pick("quick-wins")), "the menu hands control back")
  eq(state.sort, "roi", "applying a list sets its sort")
  ok(core.is_quick_win_filter(state.filter), "... and its filter")

  state = {
    root = root,
    filter = { value_min = 3, effort_max = "M" },
    sort = "prio-effort",
    persist = false,
  }
  ok(menu(state, pick("Save the current"), "from-dash"))
  local saved_entry = lists.get("from-dash")
  eq(saved_entry.source, "saved", "the current view was saved")
  eq(
    { saved_entry.def.value, saved_entry.def.effort, saved_entry.def.sort },
    { ">=3", "<=M", "prio-effort" },
    "with its filter and sort"
  )
  ok(menu(state, pick("Save the current"), "   "), "an empty name saves nothing")

  -- rename through the menu
  lists.save("old-name", { prio = "1" })
  local function choose_rename(items, opts)
    if opts.prompt == "Rename which list?" then
      for _, item in ipairs(items) do
        if item.name == "old-name" then
          return item
        end
      end
    end
    return pick("Rename a saved")(items, opts)
  end
  ok(menu(state, choose_rename, "new-name"), "renaming hands control back")
  ok(
    lists.get("new-name") ~= nil and lists.get("old-name") == nil,
    "a saved list is renamed from the menu"
  )
  lists.delete("new-name")

  local function choose_delete(items, opts)
    if opts.prompt == "Delete which list?" then
      return items[1]
    end
    if opts.prompt == "Task lists" then
      return pick("Delete a saved")(items, opts)
    end
    for _, item in ipairs(items) do
      if type(item) == "string" and item:find("Yes", 1, true) == 1 then
        return item
      end
    end
    return items[#items]
  end
  menu(state, choose_delete)
  ok(lists.get("from-dash") == nil, "a saved list is deleted from the menu")

  lists.set_path(nil)
  config.merge(before)
end
