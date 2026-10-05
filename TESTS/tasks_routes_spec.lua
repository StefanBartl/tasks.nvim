-- TESTS/tasks_routes_spec.lua -- the :MyPlugins tasks/task/open layer: composer parsing, dispatch,
-- delivery targets, completion, prompts. Engine rules are covered by the other specs; this one drives the
-- real composer command (registered here as :TaskT with the very routes `:MyPlugins` gets) against a
-- fixture vault.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local composer = require("lib.nvim.bindings.usercmd.composer")
  local routes = require("tasks_nvim.ui.routes")
  local cmd = require("tasks_nvim.ui.cmd")
  local view = require("tasks_nvim.ui.view")
  local confirm = require("tasks_nvim.ui.confirm")
  local vault = require("tasks_nvim.vault")

  -- ── harness: one pinned fixture vault, captured notifications ─────────────
  local root = F.vault(H)
  vault.set_root(root)
  routes.register_types()
  composer.verb("TaskT", { routes = routes.routes() })

  local today = os.date("%Y-%m-%d") --[[@as string]]
  local old = "2020-01-01"

  local orig_notify = vim.notify
  local orig_input = vim.ui.input
  local orig_yesno = confirm.yesno
  local orig_loaded = {}
  local STUBBED = {
    "pickers.command",
    "pickers.engines",
    "lib.nvim.ui.kit",
    "cascade",
    "lib.nvim.cross.copy_to_clipboard",
  }
  for _, name in ipairs(STUBBED) do
    orig_loaded[name] = package.loaded[name]
  end

  ---@type { msg: string, level: integer }[]
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end

  local function restore()
    vim.notify = orig_notify
    vim.ui.input = orig_input
    confirm.yesno = orig_yesno
    cmd.dashboard = nil
    cmd.form_open = nil
    cmd.explorer_open = nil
    local pv = package.loaded["tasks_nvim.ui.preview"]
    if pv then
      pv.probe, pv.opener, pv.temp_root = nil, nil, nil
      pv.cleanup_all()
    end
    vault.set_root(nil)
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = orig_loaded[name]
    end
    pcall(vim.cmd, "cclose")
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  local function flush()
    vim.wait(30, function()
      return false
    end)
  end

  ---Run `:TaskT <line>` and let scheduled notifications arrive.
  ---@param line string
  local function run(line)
    notes = {}
    vim.cmd("TaskT " .. line)
    flush()
  end

  ---All notification texts joined, for `has`.
  ---@return string
  local function said()
    local out = {}
    for _, n in ipairs(notes) do
      out[#out + 1] = n.msg
    end
    return table.concat(out, "\n")
  end

  ---@param level integer
  ---@return boolean
  local function said_level(level)
    for _, n in ipairs(notes) do
      if n.level == level then
        return true
      end
    end
    return false
  end

  local ERROR, WARN = vim.log.levels.ERROR, vim.log.levels.WARN

  local function task_path(area, slug)
    return root .. "/" .. area .. "/ROADMAP/tasks/" .. slug .. ".md"
  end

  ---@param s string
  ---@return string[]
  local function lines_of(s)
    return vim.split((s:gsub("\n$", "")), "\n", { plain = true })
  end

  local function position(text, needle)
    return (text:find(needle, 1, true)) or math.huge
  end

  local function body()
    local ok_run, err = pcall(function()
      -- The default hook opens the interactive dashboard (tasks_dash_spec covers it);
      -- `false` keeps these specs on the scratch buffer.
      cmd.dashboard = false

      -- ── fixture ─────────────────────────────────────────────────────────
      F.task(
        H,
        root,
        "lib.nvim",
        "alpha",
        F.meta("Alpha feature", "doing", {
          { "kind", "feature" },
          { "prio", "1" },
          { "effort", "M" },
          { "tags", "[ui, release]" },
          { "created", today },
          { "updated", today },
        }),
        "\nAlpha summary.\n"
      )
      F.task(
        H,
        root,
        "lib.nvim",
        "beta-bug",
        F.meta("Beta bug", "open", {
          { "kind", "bug" },
          { "prio", "2" },
          { "effort", "S" },
          { "created", old },
          { "updated", old },
        }),
        "\nBeta summary.\n"
      )
      F.task(
        H,
        root,
        "lib.nvim",
        "gamma-decision",
        F.meta("Gamma", "decision", { { "prio", "2" }, { "created", today }, { "updated", today } }),
        "\nWaiting for a decision.\n"
      )
      F.task(
        H,
        root,
        "lib.nvim",
        "delta-blocked",
        F.meta("Delta", "blocked", {
          { "prio", "3" },
          { "blocked_by", "cascade.nvim/epsilon" },
          { "created", today },
          { "updated", today },
        }),
        "\nDelta summary.\n"
      )
      F.task(
        H,
        root,
        "cascade.nvim",
        "epsilon",
        F.meta("Epsilon", "open", { { "prio", "3" }, { "created", today }, { "updated", today } }),
        "\nEpsilon summary.\n"
      )
      local out_dir = H.tmpdir()

      -- ── view: targets, formats, exact text ──────────────────────────────
      eq(view.parse_target(nil), nil, "no --to means no target")
      eq(view.parse_target("buffer"), { kind = "buffer" })
      eq(view.parse_target("qf"), { kind = "qf" })
      eq(view.parse_target("file:C:/x/y.md"), { kind = "file", path = "C:/x/y.md" })
      local t_nil, t_err = view.parse_target("file:")
      eq(t_nil, nil)
      has(t_err, "needs a path")
      t_nil, t_err = view.parse_target("printer")
      eq(t_nil, nil)
      has(t_err, "unknown --to target 'printer'")
      eq(view.resolve_format(nil, nil), "md")
      eq(
        view.resolve_format({ kind = "file", path = "a/B.CSV" }, nil),
        "csv",
        "extension implies csv"
      )
      eq(view.resolve_format({ kind = "file", path = "a/b.csv" }, "md"), "md", "--format wins")
      eq(view.resolve_format({ kind = "buffer" }, "csv"), "csv")

      -- ── parse_assignments: values with spaces, removal, errors ──────────
      local known = { "title", "status", "kind", "prio" }
      eq(
        cmd.parse_assignments({ "title=Fix", "the", "thing", "status=doing" }, known),
        { title = "Fix the thing", status = "doing" },
        "a value continues until the next known key"
      )
      eq(
        cmd.parse_assignments({ "title=Fix", "a=b", "thing" }, known).title,
        "Fix a=b thing",
        "an unknown key=word inside a value is part of it"
      )
      eq(
        cmd.parse_assignments({ 'title="Quoted', 'title"' }, known).title,
        "Quoted title",
        "surrounding quotes are dropped"
      )
      eq(
        cmd.parse_assignments({ "kind=" }, known).kind,
        require("tasks_nvim.mutate").REMOVE,
        "an empty value removes the key"
      )
      ---@param tokens string[]
      ---@param needle string
      local function refused(tokens, needle)
        local patch, perr = cmd.parse_assignments(tokens, known)
        eq(patch, nil, "refused: " .. needle)
        has(perr, needle)
      end
      refused({ "bogus=1" }, "unknown field 'bogus'")
      refused({ "loose" }, "expected key=value")
      refused({}, "nothing to set")
      refused({ "prio=1", "prio=2" }, "'prio' given twice")

      -- ── :tasks -> file / csv ────────────────────────────────────────────
      local all_md = out_dir .. "/all.md"
      run("tasks --to=file:" .. all_md)
      local text = assert(H.read(all_md))
      has(text, "# Offene Tasks — alle Bereiche (5)")
      has(text, "| Task ")
      lacks(text, "Summary", "the Markdown table leaves the wide columns out")
      lacks(text, "Path")
      ok(
        position(text, "lib.nvim/alpha") < position(text, "lib.nvim/gamma-decision")
          and position(text, "lib.nvim/gamma-decision") < position(text, "lib.nvim/delta-blocked")
          and position(text, "lib.nvim/delta-blocked") < position(text, "lib.nvim/beta-bug")
          and position(text, "lib.nvim/beta-bug") < position(text, "cascade.nvim/epsilon"),
        "doing, decision, blocked, then open by prio"
      )
      has(said(), "5 open task(s) -> file:" .. all_md)

      local csv_path = out_dir .. "/lib.csv"
      run("tasks lib.nvim --status=doing,decision --to=file:" .. csv_path)
      local csv = lines_of(assert(H.read(csv_path)))
      eq(
        csv[1],
        "Task,Status,Prio,Effort,Kind,Updated,Title,Tags,Blocked by,Summary,Path,Severity",
        "the CSV gets Severity as its last column"
      )
      eq(#csv, 3, "header and two rows")
      has(
        csv[2],
        "lib.nvim/alpha,doing,1,M,feature," .. today .. ",Alpha feature,ui;release,,Alpha summary.,"
      )
      has(csv[3], "lib.nvim/gamma-decision,decision,2,,,", "empty cells stay empty in csv")

      local forced = out_dir .. "/forced.txt"
      run("tasks lib.nvim --format=csv --to=file:" .. forced)
      has(assert(H.read(forced)), "Task,Status,Prio", "--format=csv on a .txt target")
      local forced_md = out_dir .. "/forced.csv"
      run("tasks lib.nvim --format=md --to=file:" .. forced_md)
      has(assert(H.read(forced_md)), "| Task ", "--format=md beats the .csv extension")

      -- a title is whatever a file says: a CSV cell that reads as a formula is neutralised
      local function fake_task(title)
        return {
          id = "x/y",
          status = "open",
          title = title,
          tags = {},
          blocked_by = {},
          path = "/p/y.md",
        }
      end
      local csv_out = view.render({
        fake_task('=HYPERLINK("http://evil","x")'),
        fake_task("+1+1"),
        fake_task("-2+3"),
        fake_task("@SUM(1)"),
        fake_task("\tTabbed"),
        fake_task("Plain title"),
        fake_task("a=b"),
        fake_task("Fix -x flag"),
      }, { format = "csv" })
      has(csv_out, ',"\'=HYPERLINK(""http://evil"",""x"")",', "= is defused (and quoted as before)")
      has(csv_out, ",'+1+1,", "+ is defused")
      has(csv_out, ",'-2+3,", "- is defused")
      has(csv_out, ",'@SUM(1),", "@ is defused")
      has(csv_out, ",'\tTabbed,", "a leading tab is defused")
      has(csv_out, ",Plain title,", "an ordinary title is left alone")
      has(csv_out, ",a=b,", "an = inside a title is left alone")
      has(csv_out, ",Fix -x flag,", "so is a - inside it")
      lacks(csv_out, ",+1+1,")
      lacks(csv_out, ',"=HYPERLINK')
      has(
        view.render({ fake_task("=1+1") }, { format = "md" }),
        "| =1+1 ",
        "the Markdown table is not CSV: untouched"
      )

      -- ── filters ─────────────────────────────────────────────────────────
      ---@param flags string
      ---@return string[] ids in output order
      local function ids_for(flags)
        local path = out_dir .. "/f.csv"
        vim.fn.delete(path)
        run("tasks " .. flags .. " --to=file:" .. path)
        local content = H.read(path)
        local ids = {}
        for _, l in ipairs(content and lines_of(content) or {}) do
          local id = l:match("^([%w%.]+/[%w-]+),")
          if id then
            ids[#ids + 1] = id
          end
        end
        return ids
      end
      eq(ids_for("--prio=1"), { "lib.nvim/alpha" })
      eq(
        ids_for("--prio=<=2"),
        { "lib.nvim/alpha", "lib.nvim/gamma-decision", "lib.nvim/beta-bug" }
      )
      eq(ids_for("--prio=3"), { "lib.nvim/delta-blocked", "cascade.nvim/epsilon" })
      eq(ids_for("--kind=bug"), { "lib.nvim/beta-bug" })
      eq(ids_for("--tag=ui"), { "lib.nvim/alpha" })
      eq(ids_for("--status=blocked"), { "lib.nvim/delta-blocked" })
      eq(ids_for("--blocked"), { "lib.nvim/delta-blocked" })
      eq(ids_for("--stale=30"), { "lib.nvim/beta-bug" }, "only the task untouched since 2020")
      eq(ids_for("--stale=refs"), {}, "no fixture task carries refs: nothing is stale by refs")
      has(said(), "--stale=refs: 0 file(s)", "the lookup reports what it checked")
      eq(ids_for("--stale=30 --stale=refs"), {}, "the last --stale wins, and refs is accepted")
      eq(ids_for("cascade.nvim"), { "cascade.nvim/epsilon" })
      eq(ids_for("all --status=open --prio=2,3"), { "lib.nvim/beta-bug", "cascade.nvim/epsilon" })
      eq(
        ids_for("lib.nvim --status=open --prio=1"),
        {},
        "a filter that matches nothing writes no file"
      )
      has(said(), "no open task matches")

      -- the uppercase area ALL is an area; the lowercase word is "every area"
      vim.fn.delete(out_dir .. "/f.csv")
      run("tasks ALL --to=file:" .. out_dir .. "/f.csv")
      ok(not H.exists(out_dir .. "/f.csv"), "ALL has no task: nothing written")
      has(said(), "no open task matches")

      -- ── errors are reported, nothing is delivered ───────────────────────
      run("tasks --to=printer")
      has(said(), "unknown --to target 'printer'")
      ok(said_level(ERROR))
      run("tasks --status=nope")
      has(said(), "unknown status in --status: nope")
      run("tasks --stale=abc")
      has(said(), "stale")
      run("tasks nowhere")
      has(said(), "'nowhere' is not an area of the vault")
      run("tasks --format=xml")
      has(said(), "expected one of md|csv")
      run("tasks --to=file:")
      has(said(), "needs a path")

      -- ── words a command has no use for are refused, not ignored ─────────
      -- The command line splits at spaces: `--to=file:<dir with space>/x.md` is the path up to the
      -- space plus a stray word, and the template used to be written to a file named after the
      -- first half.
      local spaced = out_dir .. "/with space"
      run("task template --to=file:" .. spaced .. "/tpl.md")
      has(said(), "unexpected argument: space/tpl.md")
      has(said(), "backslash before each space")
      ok(said_level(ERROR))
      ok(
        not H.exists(out_dir .. "/with") and not H.exists(spaced),
        "nothing was written to the half path"
      )
      run("task template --to=file:" .. out_dir .. "/with\\ space/tpl.md")
      ok(H.exists(spaced .. "/tpl.md"), "a backslash before the space keeps the path whole")
      run("tasks lib.nvim stray")
      has(said(), "unexpected argument: stray")
      run("tasks index lib.nvim junk")
      has(said(), "unexpected argument: junk")
      lacks(said(), "tasks index:", "and no index run")
      local open_before = vim.api.nvim_get_current_buf()
      run("task open lib.nvim/alpha extra")
      has(said(), "unexpected argument: extra")
      eq(vim.api.nvim_get_current_buf(), open_before, "nothing was opened")

      -- ── :tasks -> quickfix ──────────────────────────────────────────────
      run("tasks lib.nvim --to=qf")
      local qf = vim.fn.getqflist({ title = 1, items = 1 })
      eq(#qf.items, 4)
      has(qf.title, "tasks://tasks/lib.nvim")
      has(qf.items[1].text, "doing")
      has(qf.items[1].text, "lib.nvim/alpha")
      eq(
        vim.fs.normalize(vim.api.nvim_buf_get_name(qf.items[1].bufnr)),
        task_path("lib.nvim", "alpha"),
        "an entry jumps into the task file"
      )
      vim.cmd("cclose")

      -- ── :tasks -> scratch buffer (the default) and the dashboard hook ───
      run("tasks lib.nvim --status=doing")
      eq(vim.bo.buftype, "nofile")
      eq(vim.bo.filetype, "markdown")
      local shown = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      has(shown, "# Offene Tasks — lib.nvim (1)")
      has(shown, "Filter: status=doing")
      has(shown, "lib.nvim/alpha")
      vim.cmd("bwipeout!")

      local hook_calls = {}
      cmd.dashboard = function(v)
        hook_calls[#hook_calls + 1] = v
      end
      run("tasks lib.nvim --prio=<=2")
      eq(#hook_calls, 1, "without --to/--format the dashboard hook gets the list")
      eq(hook_calls[1].area, "lib.nvim")
      eq(#hook_calls[1].tasks, 3)
      eq(hook_calls[1].filter.prio_max, 2)
      eq(hook_calls[1].root, root)
      eq(hook_calls[1].tasks[1].id, "lib.nvim/alpha", "the hook receives the sorted list")
      run("tasks all")
      eq(hook_calls[2].area, nil, "'all' is no area")
      run("tasks lib.nvim --to=buffer")
      eq(#hook_calls, 2, "an explicit --to bypasses the hook")
      vim.cmd("bwipeout!")
      run("tasks lib.nvim --format=csv --to=file:" .. out_dir .. "/h.csv")
      eq(#hook_calls, 2, "an explicit --format bypasses the hook")
      cmd.dashboard = false

      -- ── tasks index ─────────────────────────────────────────────────────
      local lib_index = root .. "/lib.nvim/ROADMAP/TASKS.md"
      run("tasks index lib.nvim --check")
      ok(said_level(ERROR), "a missing index is an error in --check")
      has(said(), "index-stale")
      ok(not H.exists(lib_index), "--check writes nothing")
      run("tasks index lib.nvim")
      has(said(), "1 written")
      ok(H.exists(lib_index))
      ok(not H.exists(root .. "/cascade.nvim/ROADMAP/TASKS.md"), "only the named area")
      run("tasks index lib.nvim --check")
      ok(not said_level(ERROR) and not said_level(WARN))
      has(said(), "0 finding(s)")
      run("tasks index --check")
      ok(said_level(ERROR), "cascade.nvim is still stale")
      has(said(), "cascade.nvim/ROADMAP/TASKS.md")
      run("tasks index --all")
      has(said(), "tasks index: ")
      ok(H.exists(root .. "/cascade.nvim/ROADMAP/TASKS.md"))
      run("tasks index --all --check")
      has(said(), "0 finding(s)")
      run("tasks index nowhere")
      has(said(), "not an area")
      run("tasks index all")
      has(
        said(),
        "'all' is not an area of the vault",
        "'all' is a keyword of tasks only, even where ALL exists"
      )
      run("task set ALL/nothing status=doing")
      has(said(), "no such open task")
      run("task set all/nothing status=doing")
      has(said(), "'all' is not an area of the vault")

      -- ── task new ────────────────────────────────────────────────────────
      run("task new lib.nvim Zeta feature work kind=feature prio=1 effort=S tags=a,b")
      local zeta = task_path("lib.nvim", "zeta-feature-work")
      ok(H.exists(zeta), "slug comes from the title words")
      local zeta_text = assert(H.read(zeta))
      has(zeta_text, "title: Zeta feature work")
      has(zeta_text, "kind: feature")
      has(zeta_text, "prio: 1")
      has(zeta_text, "effort: S")
      has(zeta_text, "tags: [a, b]")
      has(zeta_text, "status: open")
      eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), zeta, "the new file is opened")
      has(assert(H.read(lib_index)), "Zeta feature work", "the index is regenerated")
      has(said(), "created lib.nvim/zeta-feature-work")

      run('task new cascade.nvim "Quoted title" status=doing')
      local quoted = assert(H.read(task_path("cascade.nvim", "quoted-title")))
      has(quoted, "title: Quoted title")
      has(quoted, "status: doing")
      run("task new lib.nvim Zeta feature work")
      ok(H.exists(task_path("lib.nvim", "zeta-feature-work-2")), "a taken slug gets -2")

      local before = #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks")
      run("task new lib.nvim Broken kind=wrong")
      has(said(), "unknown kind 'wrong'")
      eq(
        #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks"),
        before,
        "a rejected task creates nothing"
      )
      run("task new nowhere Whatever")
      has(said(), "not an area")

      -- a missing title is asked for (no ui.nvim in this run: vim.ui.input chain)
      local prompts, answers = {}, {}
      vim.ui.input = function(opts, cb)
        prompts[#prompts + 1] = opts.prompt
        local a = table.remove(answers, 1)
        cb(a)
      end
      answers = { "Asked title", "idea", "", "L" }
      run("task new lib.nvim")
      eq(#prompts, 4, "title, kind, prio, effort")
      has(prompts[1], "Title")
      has(prompts[2], "Kind")
      has(prompts[3], "Prio")
      has(prompts[4], "Effort")
      local asked = assert(H.read(task_path("lib.nvim", "asked-title")))
      has(asked, "kind: idea")
      has(asked, "effort: L")
      lacks(asked, "prio:", "an empty answer leaves the field out")

      prompts, answers = {}, { "Only title", "S" }
      run("task new lib.nvim kind=bug prio=2")
      eq(#prompts, 2, "fields given as key=value are not asked again: title and effort")
      has(prompts[2], "Effort")
      local only = assert(H.read(task_path("lib.nvim", "only-title")))
      has(only, "kind: bug")
      has(only, "prio: 2")
      has(only, "effort: S")

      prompts, answers = {}, { "Bad effort", "7" }
      run("task new lib.nvim kind=bug prio=2")
      has(said(), "effort '7'", "a bad answer is reported by the engine")
      ok(not H.exists(task_path("lib.nvim", "bad-effort")), "and creates nothing")

      prompts, answers = {}, { nil }
      before = #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks")
      run("task new lib.nvim")
      eq(#prompts, 1, "escape on the required title stops the chain")
      has(said(), "cancelled")
      eq(#vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks"), before)

      prompts, answers = {}, { "  ", "", "", "" }
      run("task new lib.nvim")
      has(said(), "no title given")
      eq(
        #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks"),
        before,
        "a blank title creates nothing"
      )

      -- ── categories, folder tasks, attach ────────────────────────────────
      run("task new lib.nvim Sec folder kind=task category=security --folder")
      local folder_file = root .. "/lib.nvim/ROADMAP/tasks/sec-folder/sec-folder.md"
      ok(H.exists(folder_file), "task new --folder makes a folder task")
      has(assert(H.read(folder_file)), "category: [security]")
      run("task new lib.nvim Bad category category=nope")
      has(said(), "unknown category")
      ok(said_level(ERROR))
      run("task set lib.nvim/sec-folder category=docs,performance")
      has(assert(H.read(folder_file)), "category: [docs, performance]")

      local shot = H.tmpdir() .. "/shot.png"
      H.write(shot, "png")
      run("task attach lib.nvim/sec-folder " .. shot)
      ok(
        H.exists(root .. "/lib.nvim/ROADMAP/tasks/sec-folder/assets/shot.png"),
        "attach copies the file"
      )
      has(said(), "attached lib.nvim/sec-folder -> assets/shot.png")
      run("task attach lib.nvim/sec-folder " .. shot)
      has(said(), "asset exists")
      run("task attach lib.nvim/sec-folder " .. shot .. " name=shot-2.png")
      ok(
        H.exists(root .. "/lib.nvim/ROADMAP/tasks/sec-folder/assets/shot-2.png"),
        "name= renames the copy"
      )
      -- the composer has expanded the FILE argument: a second expansion read `[1]` as a wildcard
      local wild_dir = H.tmpdir()
      H.write(wild_dir .. "/shot1.png", "WRONG")
      H.write(wild_dir .. "/shot[1].png", "RIGHT")
      run("task attach lib.nvim/sec-folder " .. wild_dir .. "/shot[1].png name=wild.png")
      eq(
        H.read(root .. "/lib.nvim/ROADMAP/tasks/sec-folder/assets/wild.png"),
        "RIGHT",
        "the file that was named is the file that is attached"
      )

      run("task folderize lib.nvim/beta-bug")
      ok(
        H.exists(root .. "/lib.nvim/ROADMAP/tasks/beta-bug/beta-bug.md"),
        "folderize moves the file"
      )
      ok(not H.exists(task_path("lib.nvim", "beta-bug")), "the old file is gone")
      run("task folderize lib.nvim/beta-bug")
      has(said(), "already a folder task")
      -- put it back as a plain file for the rest of this spec
      vim.fn.rename(
        root .. "/lib.nvim/ROADMAP/tasks/beta-bug/beta-bug.md",
        task_path("lib.nvim", "beta-bug")
      )
      vim.fn.delete(root .. "/lib.nvim/ROADMAP/tasks/beta-bug", "d")
      run("tasks lib.nvim --category=security --to=buffer")
      has(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), " "), "Sec folder")
      run("tasks lib.nvim --category=nope --to=buffer")
      has(said(), "unknown category")

      -- ── task set ────────────────────────────────────────────────────────
      local beta = task_path("lib.nvim", "beta-bug")
      run("task set lib.nvim/beta-bug title=Beta bug, renamed status=doing prio=1 tags=x,y")
      local beta_text = assert(H.read(beta))
      has(beta_text, "title: Beta bug, renamed")
      has(beta_text, "status: doing")
      has(beta_text, "prio: 1")
      has(beta_text, "tags: [x, y]")
      has(beta_text, "updated: " .. today, "updated is bumped")
      lacks(beta_text, "updated: " .. old)
      has(said(), "set lib.nvim/beta-bug: changed")
      has(assert(H.read(lib_index)), "Beta bug, renamed", "the index follows")

      local frozen = assert(H.read(beta))
      run("task set lib.nvim/beta-bug status=doing")
      has(said(), "unchanged")
      eq(H.read(beta), frozen, "an identical value rewrites nothing")

      run("task set lib.nvim/beta-bug title=Fix a=b thing")
      has(assert(H.read(beta)), "title: Fix a=b thing")
      run("task set lib.nvim/beta-bug kind=")
      lacks(assert(H.read(beta)), "kind:", "an empty value removes the key")

      -- an open buffer of the file follows the change
      vim.cmd("edit " .. vim.fn.fnameescape(beta))
      run("task set lib.nvim/beta-bug status=parked")
      has(
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
        "status: parked",
        "an unmodified buffer is reloaded"
      )
      run("task set lib.nvim/beta-bug status=doing")

      run("task set lib.nvim/beta-bug status=done")
      has(said(), "tasks done")
      run("task set lib.nvim/beta-bug bogus=1")
      has(said(), "unknown field 'bogus'")
      run("task set lib.nvim/beta-bug")
      has(said(), "nothing to set")
      run("task set lib.nvim/beta-bug prio=1 prio=2")
      has(said(), "given twice")
      run("task set lib.nvim/beta-bug effort=huge")
      has(said(), "effort 'huge'")
      eq(H.read(beta), assert(H.read(beta)), "still readable")
      run("task set lib.nvim/no-such-task status=doing")
      has(said(), "no such open task")
      run("task set nowhere/x status=doing")
      has(said(), "'nowhere' is not an area of the vault")
      run("task set not-an-id status=doing")
      has(said(), "expected <area>/<slug>")

      -- ── task done ───────────────────────────────────────────────────────
      local msgs = {}
      confirm.yesno = function(msg, label, cb)
        msgs[#msgs + 1] = { msg = msg, label = label }
        cb(false)
      end
      local gamma = task_path("lib.nvim", "gamma-decision")
      run("task done lib.nvim/gamma-decision")
      eq(#msgs, 1, "finishing asks first")
      has(msgs[1].msg, "lib.nvim/gamma-decision")
      has(msgs[1].msg, "Gamma")
      has(msgs[1].msg, "Backlog/TASKS/" .. today .. "_gamma-decision.md")
      eq(msgs[1].label, "finish")
      ok(H.exists(gamma), "declined: the task stays")
      has(said(), "cancelled")

      confirm.yesno = function(_, _, cb)
        cb(true)
      end
      vim.cmd("edit " .. vim.fn.fnameescape(gamma))
      local old_buf = vim.api.nvim_get_current_buf()
      run("task done lib.nvim/gamma-decision date=2026-10-01 done_in=lib.nvim@abc1234")
      local gamma_done = root .. "/lib.nvim/Backlog/TASKS/2026-10-01_gamma-decision.md"
      ok(H.exists(gamma_done), "accepted: moved to Backlog/TASKS with the date prefix")
      ok(not H.exists(gamma), "the open file is gone")
      has(assert(H.read(gamma_done)), "status: done")
      has(assert(H.read(gamma_done)), "done_in: lib.nvim@abc1234")
      has(assert(H.read(root .. "/lib.nvim/Backlog/README.md")), "2026-10-01_gamma-decision.md")
      lacks(assert(H.read(lib_index)), "Gamma", "the index lost the finished task")
      eq(
        vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
        gamma_done,
        "the window followed the file to Backlog/"
      )
      ok(not vim.api.nvim_buf_is_loaded(old_buf), "the buffer of the dead path is gone")
      has(
        said(),
        "done lib.nvim/gamma-decision -> lib.nvim/Backlog/TASKS/2026-10-01_gamma-decision.md"
      )

      confirm.yesno = function()
        error("must not ask for a task that is already finished")
      end
      run("task done lib.nvim/gamma-decision")
      has(said(), "already finished")
      ok(not said_level(ERROR))

      confirm.yesno = function()
        error("--yes must not ask")
      end
      run("task done cascade.nvim/epsilon --yes")
      ok(
        H.exists(root .. "/cascade.nvim/Backlog/TASKS/" .. today .. "_epsilon.md"),
        "--yes skips the question"
      )
      run("task done lib.nvim/does-not-exist")
      has(said(), "no such open task")
      run("task done lib.nvim/alpha stray words --yes")
      has(said(), "unexpected argument")
      ok(H.exists(task_path("lib.nvim", "alpha")), "a malformed call finishes nothing")
      -- a kind-less/unknown-kind task is refused by the engine, the file stays
      F.task(H, root, "lib.nvim", "odd-kind", F.meta("Odd", "open", { { "kind", "epic" } }))
      run("task done lib.nvim/odd-kind --yes")
      has(said(), "unknown kind")
      ok(H.exists(task_path("lib.nvim", "odd-kind")))
      confirm.yesno = orig_yesno

      -- ── task template ───────────────────────────────────────────────────
      local clip
      package.loaded["lib.nvim.cross.copy_to_clipboard"] = function(t)
        clip = t
        return true
      end
      run("task template")
      ok(clip and clip:sub(1, 3) == "---", "the template went to the clipboard")
      has(clip, "title: Titel")
      has(clip, "## Akzeptanz")
      has(said(), "+ register")

      package.loaded["lib.nvim.cross.copy_to_clipboard"] = function()
        return false
      end
      run("task template")
      eq(vim.bo.filetype, "markdown", "no clipboard: the template opens in a buffer")
      has(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "title: Titel")
      ok(said_level(WARN))
      vim.cmd("bwipeout!")
      package.loaded["lib.nvim.cross.copy_to_clipboard"] =
        orig_loaded["lib.nvim.cross.copy_to_clipboard"]

      run("task template --to=file:" .. out_dir .. "/tpl.md")
      has(assert(H.read(out_dir .. "/tpl.md")), "title: Titel")
      run("task template --to=qf")
      has(said(), "qf")
      ok(said_level(ERROR))

      -- ── task open ───────────────────────────────────────────────────────
      run("task open lib.nvim/alpha")
      eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), task_path("lib.nvim", "alpha"))
      run("task open lib.nvim/gamma-decision")
      eq(
        vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
        gamma_done,
        "a finished task opens its Backlog copy"
      )
      run("task open lib.nvim/nothing-here")
      has(said(), "no such open task")

      -- ── mdview preview: `task preview`, `--to=mdview`, temp-file clean-up ─
      -- The seams stand in for mdview.nvim; the opener really `:edit`s the file, so the
      -- buffer-deleted clean-up runs for real.
      local preview = require("tasks_nvim.ui.preview")
      local preview_dir = H.tmpdir()
      ---@type { path: string, text: string }[]
      local shown_in_mdview = {}
      preview.temp_root = function()
        return preview_dir
      end
      preview.probe = function()
        return true
      end
      preview.opener = function(path)
        shown_in_mdview[#shown_in_mdview + 1] = { path = path, text = H.read(path) or "" }
        vim.cmd("silent edit " .. vim.fn.fnameescape(path))
        return true
      end
      local function temp_files_in_dir()
        return vim.fn.glob(preview_dir .. "/*", false, true)
      end

      -- a task file is opened as it is, nothing is copied or written
      run("task preview lib.nvim/alpha")
      eq(#shown_in_mdview, 1)
      eq(shown_in_mdview[1].path, task_path("lib.nvim", "alpha"))
      has(said(), "previewing lib.nvim/alpha")
      eq(temp_files_in_dir(), {}, "a task preview makes no temp file")
      run("task preview lib.nvim/gamma-decision")
      eq(shown_in_mdview[2].path, gamma_done, "a finished task previews its Backlog copy")
      run("task preview lib.nvim/nothing-here")
      has(said(), "no such open task")
      eq(#shown_in_mdview, 2)
      run("task preview lib.nvim/alpha extra")
      has(said(), "unexpected argument: extra")
      eq(#shown_in_mdview, 2, "a stray word previews nothing")
      vim.cmd("silent! %bwipeout!")

      -- the list export: a temp Markdown file, named after the scope
      run("tasks lib.nvim --to=mdview")
      eq(#shown_in_mdview, 3)
      local exp1 = shown_in_mdview[3]
      eq(exp1.path, vim.fs.normalize(preview_dir) .. "/tasks-lib.nvim.md")
      has(exp1.text, "# Offene Tasks")
      has(exp1.text, "lib.nvim/alpha")
      has(exp1.text, "| Task ", "the Markdown table, not CSV")
      has(said(), "-> mdview")
      eq(preview.pending(), { exp1.path })
      ok(H.exists(exp1.path), "the temp file exists while its buffer is open")
      ok(not vim.bo.buflisted, "the preview buffer stays out of the buffer list")
      -- a second export of the same scope gets its own file, the first stays untouched
      run("tasks lib.nvim --to=mdview --status=open")
      eq(#shown_in_mdview, 4)
      eq(shown_in_mdview[4].path, vim.fs.normalize(preview_dir) .. "/tasks-lib.nvim-2.md")
      ok(H.exists(exp1.path) and H.exists(shown_in_mdview[4].path))
      -- deleting the buffers deletes the files
      vim.cmd("silent! %bwipeout!")
      ok(
        vim.wait(1000, function()
          return #temp_files_in_dir() == 0
        end),
        "the temp files go with their buffers"
      )
      eq(preview.pending(), {})
      -- the vault was never written
      ok(not H.exists(root .. "/lib.nvim/tasks-lib.nvim.md"))

      -- CSV makes no sense in a browser: refused before anything is written
      run("tasks lib.nvim --to=mdview --format=csv")
      has(said(), "drop --format=csv")
      eq(#shown_in_mdview, 4)
      eq(temp_files_in_dir(), {})

      -- the dashboard's export choice delivers through the same sink
      local dash_core = require("tasks_nvim.ui.dash_core")
      local tsk = require("tasks_nvim.scan").all({ root = root })
      local dash_target = assert(dash_core.export_target(dash_core.EXPORT_CHOICES[7]))
      local delivered, derr = view.deliver(tsk, dash_target, {
        format = "md",
        heading = "Open tasks -- all areas",
        title = "tasks://tasks/all",
      })
      ok(delivered, derr)
      eq(shown_in_mdview[5].path, vim.fs.normalize(preview_dir) .. "/tasks-all.md")
      vim.cmd("silent! %bwipeout!")
      ok(vim.wait(1000, function()
        return #temp_files_in_dir() == 0
      end))

      -- mdview missing: one clear message, no temp file, nothing opened
      preview.probe = function()
        return false, nil
      end
      run("tasks lib.nvim --to=mdview")
      has(said(), "mdview.nvim is not available")
      has(said(), "cannot deliver the task list")
      run("task preview lib.nvim/alpha")
      has(said(), "cannot preview lib.nvim/alpha")
      has(said(), "mdview.nvim is not available")
      eq(#shown_in_mdview, 5, "nothing was opened")
      eq(temp_files_in_dir(), {}, "and nothing was written")
      -- the real probe, when this Neovim has no mdview at all
      preview.probe = nil
      if vim.fn.exists(":MDView") ~= 2 and not pcall(require, "mdview") then
        run("tasks lib.nvim --to=mdview")
        has(said(), "mdview.nvim is not available")
      end
      preview.probe = function()
        return true
      end

      -- the opener failing removes the temp file again
      local good_opener = preview.opener
      preview.opener = function()
        return false, "relay refused"
      end
      local failed_ok, failed_err = preview.open_text("# x\n", "fails")
      eq(failed_ok, false)
      has(failed_err, "relay refused")
      eq(temp_files_in_dir(), {})
      eq(preview.pending(), {})
      preview.opener = function()
        error("opener exploded")
      end
      failed_ok, failed_err = preview.open_text("# x\n", "explodes")
      eq(failed_ok, false)
      has(failed_err, "opener exploded")
      eq(temp_files_in_dir(), {})
      preview.opener = good_opener

      -- the vault is refused as a temp location
      preview.temp_root = function()
        return root .. "/lib.nvim"
      end
      local in_vault, vault_err = preview.open_text("# x\n", "vault")
      eq(in_vault, false)
      has(vault_err, "inside the vault")
      ok(not H.exists(root .. "/lib.nvim/tasks-vault.md"))
      preview.temp_root = function()
        return preview_dir
      end

      -- leaving Neovim: one sweep deletes whatever is left
      local left = assert(preview.write_temp("# left\n", "leftover"))
      ok(H.exists(left))
      preview.cleanup_all()
      ok(not H.exists(left), "cleanup_all removes tracked temp files")
      eq(preview.pending(), {})

      -- file-name-safe labels (Windows reserved characters, dots at the ends, empty)
      eq(preview.slug("lib.nvim"), "lib.nvim")
      eq(preview.slug("a b/c:d*e?"), "a-b-c-d-e")
      eq(preview.slug("../x"), "x")
      eq(preview.slug(""), "export")
      eq(preview.slug(nil), "export")
      eq(#preview.slug(("x"):rep(100)), 40)

      -- `:bdelete` drops the temp file too (BufDelete never fires for an unlisted buffer) ...
      run("tasks lib.nvim --to=mdview")
      local gone_path = shown_in_mdview[#shown_in_mdview].path
      ok(H.exists(gone_path))
      ok(not vim.bo.buflisted, "the preview buffer is unlisted")
      vim.cmd("silent bdelete")
      ok(
        vim.wait(1000, function()
          return not H.exists(gone_path)
        end),
        ":bdelete removes the temp file"
      )
      eq(preview.pending(), {})
      -- ... while merely reloading the buffer (`:edit!` fires BufUnload as well) does not
      run("tasks lib.nvim --to=mdview")
      local kept_path = shown_in_mdview[#shown_in_mdview].path
      vim.cmd("silent edit!")
      flush()
      ok(H.exists(kept_path), "reloading the buffer keeps the file")
      vim.cmd("silent bwipeout!")
      ok(
        vim.wait(1000, function()
          return not H.exists(kept_path)
        end),
        "and wiping it removes it"
      )
      eq(preview.pending(), {})

      -- the vault is refused as a temp location whatever the case of the spelling (Windows)
      if vim.fn.has("win32") == 1 then
        preview.temp_root = function()
          return (root .. "/lib.nvim"):upper()
        end
        local upper_ok, upper_err = preview.open_text("# x\n", "vault")
        eq(upper_ok, false)
        has(upper_err, "inside the vault")
        ok(not H.exists(root .. "/lib.nvim/tasks-vault.md"), "nothing was written into the vault")
        preview.temp_root = function()
          return preview_dir
        end
      end

      -- the default opener hands `:MDView start` the path as ONE argument: a `#`, `%` or `'` in it
      -- (or a space) must arrive as written, not with the backslash `fnameescape` adds
      if vim.fn.exists(":MDView") == 0 then
        local mdview_args
        vim.api.nvim_create_user_command("MDView", function(o)
          mdview_args = o.fargs
        end, { nargs = "*" })
        local odd = H.tmpdir() .. "/O'Neil #1 100% (x)/task one.md"
        H.write(odd, "# t\n")
        preview.opener = nil
        local odd_ok, odd_err = preview.open_file(odd)
        pcall(vim.api.nvim_del_user_command, "MDView")
        ok(odd_ok, odd_err)
        eq(mdview_args, { "start", odd }, "the path reaches :MDView intact")
        vim.cmd("silent! %bwipeout!")
      end
      preview.probe, preview.opener, preview.temp_root = nil, nil, nil

      eq(view.parse_target("mdview"), { kind = "mdview" })
      eq(view.resolve_format({ kind = "mdview" }, nil), "md")

      -- ── open <area> <folder> ────────────────────────────────────────────
      local dispatched = {}
      package.loaded["pickers.command"] = {
        dispatch = function(action, source, engine)
          dispatched[#dispatched + 1] = { action = action, source = source, engine = engine }
        end,
      }
      package.loaded["pickers.engines"] = {
        load = function()
          return { name = "stub" }
        end,
      }
      run("open lib.nvim tasks")
      eq(#dispatched, 1)
      eq(dispatched[1].action, "files")
      eq(dispatched[1].source.roots, { root .. "/lib.nvim/ROADMAP/tasks" })
      eq(dispatched[1].source.prompt, "lib.nvim/tasks> ")
      eq(dispatched[1].engine.name, "stub")
      run("open lib.nvim tasks stray")
      has(said(), "unexpected argument: stray")
      eq(#dispatched, 1, "a stray word opens no picker")
      run("open lib.nvim")
      eq(dispatched[2].source.roots, { root .. "/lib.nvim" }, "no folder means the whole area")
      run("open lib.nvim backlog --action=grep")
      eq(dispatched[3].action, "grep")
      eq(dispatched[3].source.roots, { root .. "/lib.nvim/Backlog" })
      run("open lib.nvim roadmap --action=smart")
      eq(dispatched[4].source.roots, { root .. "/lib.nvim/ROADMAP" })
      H.write(root .. "/cascade.nvim/handovers/h.md", "x\n")
      H.write(root .. "/cascade.nvim/NOTES/n.md", "x\n")
      run("open cascade.nvim handover")
      eq(dispatched[5].source.roots, { root .. "/cascade.nvim/handovers" })
      run("open cascade.nvim notes")
      eq(dispatched[6].source.roots, { root .. "/cascade.nvim/NOTES" })
      run("open migrate.nvim notes")
      eq(#dispatched, 6, "a missing folder opens no picker")
      has(said(), "has no notes folder")
      run("open lib.nvim bogus")
      has(said(), "expected one of tasks|roadmap|backlog|handover|notes|all")
      run("open nowhere tasks")
      has(said(), "not an area")
      run("open lib.nvim tasks --action=burn")
      has(said(), "expected one of files|grep|smart")
      eq(#dispatched, 6)

      run("open lib.nvim tasks --list --to=file:" .. out_dir .. "/files.txt")
      local listed = lines_of(assert(H.read(out_dir .. "/files.txt")))
      eq(listed[1], "alpha.md", "--list gives paths relative to the folder")
      ok(vim.tbl_contains(listed, "zeta-feature-work.md"))
      eq(#dispatched, 6, "--list opens no picker")
      run("open lib.nvim backlog --list")
      has(
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
        "TASKS/2026-10-01_gamma-decision.md"
      )
      vim.cmd("bwipeout!")

      -- without pickers.nvim: a select over the folder's Markdown files
      package.loaded["pickers.command"] = nil
      package.loaded["pickers.engines"] = nil
      local select_opts
      package.loaded["lib.nvim.ui.kit"] = {
        select = function(o)
          select_opts = o
          o.on_select(o.items[1], 1)
        end,
      }
      run("open lib.nvim tasks")
      ok(select_opts ~= nil, "the fallback asks through a select")
      eq(select_opts.items[1], "alpha.md")
      eq(
        vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
        task_path("lib.nvim", "alpha"),
        "choosing a file opens it"
      )
      run("open lib.nvim tasks --action=grep")
      has(said(), "pickers.nvim is not available")

      -- ── completion: one route tree, tab candidates ──────────────────────
      ---@param line string
      ---@return string[]
      local function complete(line)
        return vim.fn.getcompletion(line, "cmdline")
      end
      local top = complete("TaskT ")
      for _, w in ipairs({ "tasks", "task", "open" }) do
        ok(vim.tbl_contains(top, w), "verb completes " .. w)
      end
      local after_tasks = complete("TaskT tasks ")
      for _, w in ipairs({ "index", "all", "lib.nvim", "cascade.nvim", "ALL", "nvim-config" }) do
        ok(vim.tbl_contains(after_tasks, w), "tasks completes " .. w)
      end
      ok(not vim.tbl_contains(after_tasks, "TEMPLATES"), "TEMPLATES is no area")
      ok(not vim.tbl_contains(after_tasks, "_Telemetry"), "_Telemetry is no area")
      ok(not vim.tbl_contains(after_tasks, "filetreepicker.nvim"), "an empty folder is no area")
      eq(complete("TaskT tasks li"), { "lib.nvim" })
      local after_index = complete("TaskT tasks index ")
      ok(vim.tbl_contains(after_index, "lib.nvim"))
      ok(not vim.tbl_contains(after_index, "all"), "'all' is only for tasks, not index")
      ok(vim.tbl_contains(complete("TaskT task new "), "migrate.nvim"), "extra areas complete")
      ok(not vim.tbl_contains(complete("TaskT task new "), "all"))
      eq(complete("TaskT tasks --status="), {
        "--status=doing",
        "--status=decision",
        "--status=blocked",
        "--status=open",
        "--status=parked",
      })
      ok(vim.tbl_contains(complete("TaskT tasks --"), "--blocked"))
      ok(vim.tbl_contains(complete("TaskT tasks --to="), "--to=qf"))
      eq(
        complete("TaskT open lib.nvim "),
        { "tasks", "roadmap", "backlog", "handover", "notes", "all" }
      )
      eq(complete("TaskT open lib.nvim b"), { "backlog" })

      F.task(H, root, "lib.nvim", "weird-status", F.meta("Weird", "weird"))
      -- ids of OPEN tasks only (cache may be a few seconds old: wait it out)
      vim.wait(3100, function()
        return false
      end)
      local ids = complete("TaskT task set lib.nvim/")
      ok(vim.tbl_contains(ids, "lib.nvim/alpha"), "open task ids complete")
      ok(not vim.tbl_contains(ids, "lib.nvim/gamma-decision"), "finished tasks do not")
      ok(
        not vim.tbl_contains(ids, "lib.nvim/weird-status"),
        "a file with an unknown status is no open task"
      )
      ok(
        not vim.tbl_contains(ids, "cascade.nvim/quoted-title"),
        "other areas are filtered by the prefix"
      )
      eq(complete("TaskT task set cascade.nvim/q"), { "cascade.nvim/quoted-title" })
      local keys = complete("TaskT task set lib.nvim/alpha ")
      for _, k in ipairs({ "title=", "status=", "prio=", "blocked_by=", "done_in=" }) do
        ok(vim.tbl_contains(keys, k), "task set completes " .. k)
      end
      ok(not vim.tbl_contains(keys, "updated="), "updated is not settable")
      eq(complete("TaskT task set lib.nvim/alpha status=d"), { "status=doing", "status=decision" })
      eq(complete("TaskT task new lib.nvim Title kind=b"), { "kind=bug" })
      ok(vim.tbl_contains(complete("TaskT task done lib.nvim/al"), "lib.nvim/alpha"))
      ok(vim.tbl_contains(complete("TaskT task done lib.nvim/alpha "), "done_in="))
      ok(vim.tbl_contains(complete("TaskT task done lib.nvim/alpha --"), "--yes"))

      -- ── effort filter, severity, --sort (concept section 12.5) ───────────
      run("task new lib.nvim Sev crash kind=bug prio=1 effort=L severity=critical")
      run("task new lib.nvim Sev hang kind=bug prio=1 effort=XS severity=high")
      run("task new lib.nvim Sev leak category=security prio=2 severity=high")
      run("task new lib.nvim Sev none kind=bug prio=1 effort=S")
      has(
        assert(H.read(task_path("lib.nvim", "sev-crash"))),
        "severity: critical",
        "task new takes severity="
      )
      run("task new lib.nvim Sev bad kind=bug severity=urgent")
      has(said(), "unknown severity")
      ok(not H.exists(task_path("lib.nvim", "sev-bad")), "nothing created for a bad severity")

      eq(
        ids_for("--severity=high,critical --sort=severity"),
        { "lib.nvim/sev-crash", "lib.nvim/sev-hang", "lib.nvim/sev-leak" },
        "critical first, then prio"
      )
      eq(
        ids_for("--severity=high,critical --sort=prio-effort"),
        { "lib.nvim/sev-hang", "lib.nvim/sev-crash", "lib.nvim/sev-leak" },
        "prio first, then small before large"
      )
      eq(ids_for("--severity=critical"), { "lib.nvim/sev-crash" })
      eq(ids_for("--effort=XS"), { "lib.nvim/sev-hang" })
      local small = vim.tbl_filter(function(id)
        return id:find("lib.nvim/sev-", 1, true) == 1
      end, ids_for("--effort=<=S --category=bug,security --sort=prio-effort"))
      eq(
        small,
        { "lib.nvim/sev-hang", "lib.nvim/sev-none" },
        "<=S keeps the small ones; sev-leak has no effort, sev-crash is L"
      )
      eq(ids_for("lib.nvim --effort=xs --severity=high"), { "lib.nvim/sev-hang" }, "xs equals XS")
      run("tasks --effort=huge --to=buffer")
      has(said(), "unknown effort in --effort: huge")
      ok(said_level(ERROR))
      run("tasks --severity=urgent --to=buffer")
      has(said(), "unknown severity in --severity: urgent")
      run("tasks --sort=best --to=buffer")
      ok(said_level(ERROR), "an unknown --sort is refused")
      run("tasks lib.nvim --severity=critical --to=buffer")
      has(
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), " "),
        "severity=critical",
        "the table heading names the filter"
      )
      vim.cmd("bwipeout!")

      run("task set lib.nvim/sev-none severity=medium")
      has(assert(H.read(task_path("lib.nvim", "sev-none"))), "severity: medium")
      run("task set lib.nvim/sev-none severity=urgent")
      has(said(), "unknown severity")
      run("task set lib.nvim/sev-none severity=")
      lacks(assert(H.read(task_path("lib.nvim", "sev-none"))), "severity")

      -- the dashboard hook gets the sort order and the new filter fields
      local seen
      cmd.dashboard = function(v)
        seen = v
      end
      run("tasks lib.nvim --sort=prio-effort --effort=<=M --severity=high")
      eq(seen.sort, "prio-effort")
      eq(seen.filter.effort_max, "M")
      eq(seen.filter.severity, { "high" })
      run("tasks lib.nvim")
      eq(seen.sort, nil, "no --sort: left open, the dashboard may use the remembered order")
      run("tasks lib.nvim --sort=default")
      eq(seen.sort, "default", "an explicit --sort=default is the user's choice and is passed on")
      cmd.dashboard = false

      -- ── task new without arguments: the form ────────────────────────────
      -- Driven through the real buffer and its keymaps (feedkeys); the question
      -- "attach assets?" and the explorer are injected.
      local function fkeys(k)
        vim.api.nvim_feedkeys(vim.keycode(k), "mx", false)
      end
      local function buf_text()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      end
      ---@param want string  whole line
      ---@return integer|nil
      local function line_of(want)
        for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
          if l == want then
            return i
          end
        end
      end
      ---Put the cursor on the line `text` and press `key`.
      local function press_on(want, key)
        local n = assert(line_of(want), "no line " .. want)
        vim.api.nvim_win_set_cursor(0, { n, 0 })
        fkeys(key)
      end
      local function set_line(prefix, value)
        local n
        for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
          if vim.startswith(l, prefix) then
            n = i
            break
          end
        end
        assert(n, "no line '" .. prefix .. "' in: " .. buf_text())
        vim.api.nvim_buf_set_lines(0, n - 1, n, false, { prefix .. value })
      end
      local function tasks_dir_count(area)
        return #vim.fn.readdir(root .. "/" .. area .. "/ROADMAP/tasks")
      end

      local form_asked, answer = {}, false
      local explored
      confirm.yesno = function(msg, _, cb)
        form_asked[#form_asked + 1] = msg
        cb(answer)
      end
      cmd.explorer_open = function(dir)
        explored = dir
      end

      -- the form opens, the value sets are in it, the areas are listed
      local before_buf = vim.api.nvim_get_current_buf()
      run("task new")
      local form_buf = vim.api.nvim_get_current_buf()
      ok(form_buf ~= before_buf, "a form buffer opened")
      eq(vim.bo[form_buf].filetype, "markdown")
      has(buf_text(), "## category (several)")
      has(buf_text(), "- [x] task")
      has(buf_text(), "- [ ] critical")
      has(buf_text(), "areas: ")
      has(buf_text(), "lib.nvim")

      -- <Space> ticks one-choice lists exclusively, category takes several
      press_on("- [ ] bug", "<Space>")
      ok(line_of("- [x] bug") and line_of("- [ ] task"), "kind moved from task to bug")
      press_on("- [ ] S", "<CR>")
      press_on("- [ ] docs", "<Space>")
      press_on("- [ ] security", "<Space>")
      press_on("- [ ] high", "<Space>")
      press_on("- [ ] low", "<Space>")
      ok(line_of("- [x] low") and line_of("- [ ] high"), "severity keeps one tick")
      eq(
        select(2, buf_text():gsub("%- %[x%] ", "")),
        6,
        "kind, effort, 2 categories, severity, status"
      )

      -- submit with the required fields empty: errors in the buffer, nothing lost, nothing created
      local before_n = tasks_dir_count("lib.nvim")
      fkeys("<C-s>")
      has(buf_text(), "! - Area is required")
      has(buf_text(), "! - Title is required")
      has(buf_text(), "- [x] bug", "ticks survive a failed submit")
      eq(vim.api.nvim_get_current_buf(), form_buf, "the form stays open")
      eq(tasks_dir_count("lib.nvim"), before_n)
      eq(#form_asked, 0, "no question before the form is valid")

      -- an unknown area is reported too; fixing it clears the old report
      set_line("Area: ", "nowhere")
      set_line("Title: ", "Form made task")
      fkeys("<C-s>")
      has(buf_text(), "'nowhere' is not an area")
      lacks(buf_text(), "Title is required")

      -- valid, answer "no assets": a plain file task through mutate.new
      set_line("Area: ", "lib.nvim")
      set_line("Tags: ", "ui, form")
      answer, explored = false, nil
      fkeys("<C-s>")
      flush()
      eq(#form_asked, 1)
      has(form_asked[1], "Attach assets")
      local made = task_path("lib.nvim", "form-made-task")
      ok(H.exists(made), "the task file exists")
      local made_text = assert(H.read(made))
      has(made_text, "title: Form made task")
      has(made_text, "kind: bug")
      has(made_text, "effort: S")
      has(made_text, "category: [security, docs]")
      has(made_text, "severity: low")
      has(made_text, "tags: [ui, form]")
      has(made_text, "status: open")
      lacks(made_text, "prio:", "an unticked field is left out")
      eq(explored, nil, "no explorer without assets")
      eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), made, "the new file is opened")
      ok(not vim.api.nvim_buf_is_valid(form_buf), "the form is closed")
      has(said(), "created lib.nvim/form-made-task")
      has(assert(H.read(lib_index)), "Form made task", "the index is regenerated")

      -- answer "yes": a folder task, assets/ exists, the explorer is pointed at it
      run("task new")
      set_line("Area: ", "lib.nvim")
      set_line("Title: ", "Form with assets")
      answer = true
      fkeys("<C-s>")
      flush()
      local folder_md = root .. "/lib.nvim/ROADMAP/tasks/form-with-assets/form-with-assets.md"
      ok(H.exists(folder_md), "a folder task")
      eq(explored, root .. "/lib.nvim/ROADMAP/tasks/form-with-assets/assets")
      eq(vim.fn.isdirectory(explored), 1, "assets/ was created")
      has(
        assert(H.read(folder_md)),
        "kind: task",
        "an untouched default tick is the engine default"
      )

      -- cancel: nothing is created
      before_n = tasks_dir_count("lib.nvim")
      run("task new")
      form_buf = vim.api.nvim_get_current_buf()
      set_line("Area: ", "lib.nvim")
      set_line("Title: ", "Never made")
      fkeys("q")
      has(said(), "cancelled")
      ok(not vim.api.nvim_buf_is_valid(form_buf), "cancel closes the form")
      eq(tasks_dir_count("lib.nvim"), before_n)
      ok(not H.exists(task_path("lib.nvim", "never-made")))

      -- an engine error (a tag with a forbidden character) shows in the form, which stays
      run("task new")
      form_buf = vim.api.nvim_get_current_buf()
      set_line("Area: ", "lib.nvim")
      set_line("Title: ", "Engine refuses")
      set_line("Tags: ", "a#b")
      answer = false
      fkeys("<C-s>")
      flush()
      eq(vim.api.nvim_get_current_buf(), form_buf, "the form survives an engine error")
      has(buf_text(), "! - ")
      has(buf_text(), "tags item 'a#b'", "the engine's message is shown")
      has(buf_text(), "Title: Engine refuses", "the typed text survives")
      ok(not H.exists(task_path("lib.nvim", "engine-refuses")), "nothing was created")
      fkeys("q")

      -- an error that arrives while focus is elsewhere (after the "attach assets?" question) moves
      -- the cursor of the form's window, not the one of whatever window has focus
      run("task new")
      form_buf = vim.api.nvim_get_current_buf()
      local form_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(form_win, { 6, 0 })
      vim.cmd("new")
      local elsewhere = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
      vim.api.nvim_win_set_cursor(elsewhere, { 3, 0 })
      require("tasks_nvim.ui.form").show_errors(form_buf, { "late failure" })
      eq(vim.api.nvim_win_get_cursor(elsewhere), { 3, 0 }, "the focused window keeps its cursor")
      eq(vim.api.nvim_win_get_cursor(form_win)[1], 1, "the form shows its report from the top")
      has(
        table.concat(vim.api.nvim_buf_get_lines(form_buf, 0, 3, false), "\n"),
        "late failure",
        "and the report is there"
      )
      vim.cmd("silent! bwipeout!")
      vim.api.nvim_set_current_win(form_win)
      fkeys("q")

      -- help
      run("task new")
      fkeys("g?")
      flush()
      has(said(), "Task form")
      has(said(), "<C-s>")
      fkeys("q")

      -- kv given on the command line are pre-ticked, areas stay free
      run("task new kind=idea category=docs,ruleset tags=a,b")
      ok(line_of("- [x] idea") and line_of("- [ ] task"), "kind=idea pre-ticked")
      ok(line_of("- [x] docs") and line_of("- [x] ruleset"), "category pre-ticked")
      ok(line_of("Tags: a,b"))
      fkeys("q")

      -- with an area the old behaviour stays: no form, the prompt chain
      local bufs_before = #vim.api.nvim_list_bufs()
      prompts, answers = {}, { "Still prompted", "", "", "" }
      run("task new lib.nvim")
      eq(#prompts, 4, "area given: the prompt chain, not the form")
      ok(H.exists(task_path("lib.nvim", "still-prompted")))
      ok(#vim.api.nvim_list_bufs() <= bufs_before + 1, "no form buffer")

      -- cascade.nvim installed: its checkbox toggle flips, the form still keeps its rules
      local cascade_calls = 0
      package.loaded["cascade"] = {
        toggle_checkbox = function()
          cascade_calls = cascade_calls + 1
          local n = vim.api.nvim_win_get_cursor(0)[1]
          local l = vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
          -- a three-state cycle: empty -> "-" (not a tick the form knows)
          vim.api.nvim_buf_set_lines(0, n - 1, n, false, { (l:gsub("%[.%]", "[-]", 1)) })
        end,
      }
      run("task new")
      press_on("- [ ] idea", "<Space>")
      eq(cascade_calls, 1, "the cascade toggle did the flip")
      ok(
        line_of("- [x] idea") and line_of("- [ ] task"),
        "result normalised to a tick, siblings cleared"
      )
      press_on("- [x] idea", "<Space>")
      ok(line_of("- [ ] idea"), "unticking works with cascade installed")
      -- a cascade that does nothing: the fallback takes over
      package.loaded["cascade"] = { toggle_checkbox = function() end }
      press_on("- [ ] idea", "<Space>")
      ok(line_of("- [x] idea"), "a no-op cascade falls back to the own toggle")
      -- a cascade that throws
      package.loaded["cascade"] = {
        toggle_checkbox = function()
          error("boom")
        end,
      }
      press_on("- [ ] feature", "<Space>")
      ok(line_of("- [x] feature") and line_of("- [ ] idea"), "a broken cascade falls back too")
      fkeys("q")
      package.loaded["cascade"] = orig_loaded["cascade"]
      cmd.explorer_open = nil

      -- completion
      eq(complete("TaskT tasks --sort="), {
        "--sort=default",
        "--sort=prio-effort",
        "--sort=severity",
        "--sort=frecency",
      })
      ok(vim.tbl_contains(complete("TaskT tasks --to="), "--to=mdview"))
      ok(vim.tbl_contains(complete("TaskT task preview lib.nvim/al"), "lib.nvim/alpha"))
      ok(vim.tbl_contains(complete("TaskT tasks --severity="), "--severity=critical"))
      ok(vim.tbl_contains(complete("TaskT tasks --effort="), "--effort=<=M"))
      eq(complete("TaskT task new lib.nvim Title severity=c"), { "severity=critical" })
      ok(vim.tbl_contains(complete("TaskT task set lib.nvim/alpha severity="), "severity=high"))
      ok(vim.tbl_contains(complete("TaskT task set lib.nvim/alpha "), "severity="))
    end)

    restore()
    if not ok_run then
      error(err, 0)
    end
  end

  body()
end
