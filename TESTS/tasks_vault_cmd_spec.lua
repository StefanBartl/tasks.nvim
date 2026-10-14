-- TESTS/tasks_vault_cmd_spec.lua -- `:TasksVault`: the paths and writes of tasks_nvim.vault_ops, the handlers of
-- tasks_nvim.ui.vault_cmd (clipboard, paste, link, open, find, grep, new, create, the one "no vault" notice) and the
-- registration with its completion.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has

  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local ops = require("tasks_nvim.vault_ops")
  local cmd = require("tasks_nvim.ui.vault_cmd")
  local routes = require("tasks_nvim.ui.vault_routes")

  local root = F.vault(H)
  vault.set_root(root)
  local env_was = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = nil

  -- ── paths ───────────────────────────────────────────────────────────────────
  eq(ops.part_dir(root, "lib.nvim"), root .. "/lib.nvim/Backlog", "the default part is the Backlog")
  eq(ops.part_dir(root, "lib.nvim", "features"), root .. "/lib.nvim/Backlog/FEATURES")
  eq(ops.part_dir(root, "lib.nvim", "tasks"), root .. "/lib.nvim/Backlog/TASKS")
  eq(ops.part_dir(root, "lib.nvim", "roadmap"), root .. "/lib.nvim/ROADMAP")
  eq(ops.part_dir(root, "lib.nvim", "all"), root .. "/lib.nvim")
  local dir, err = ops.part_dir(root, "lib.nvim", "nope")
  ok(dir == nil and err:find("unknown part", 1, true), "an unknown part is an error")

  eq(
    ops.part_entry(root, "lib.nvim", "backlog"),
    root .. "/lib.nvim/Backlog/README.md",
    "the index of the Backlog is its README"
  )
  eq(ops.part_entry(root, "lib.nvim", "all"), nil, "a part without an index file has none")
  eq(ops.part_entry(root, "lib.nvim", "roadmap"), nil, "no ROADMAP.md and no TASKS.md: none")
  H.write(root .. "/lib.nvim/ROADMAP/TASKS.md", "# tasks\n")
  eq(ops.part_entry(root, "lib.nvim", "roadmap"), root .. "/lib.nvim/ROADMAP/TASKS.md")
  H.write(root .. "/lib.nvim/ROADMAP/ROADMAP.md", "# roadmap\n")
  eq(
    ops.part_entry(root, "lib.nvim", "roadmap"),
    root .. "/lib.nvim/ROADMAP/ROADMAP.md",
    "ROADMAP.md wins over the generated index"
  )

  -- ── which area ──────────────────────────────────────────────────────────────
  local names = vault.area_names(root)
  eq(ops.match_area(names, "lib.nvim"), "lib.nvim", "exact")
  eq(ops.match_area(names, "lib"), "lib.nvim", "lib for lib.nvim")
  eq(ops.match_area(names, "CASCADE"), "cascade.nvim", "any case")
  eq(ops.match_area(names, "nvim"), "nvim-config", "a unique prefix is enough")
  local none, many = ops.match_area({ "lib.nvim", "libx.nvim" }, "li")
  ok(none == nil and #many == 2, "an ambiguous prefix is reported with its candidates")
  eq(ops.match_area(names, "zzz"), nil)
  eq(
    ops.area_of_path(root, root .. "/lib.nvim/ROADMAP/tasks/x.md"),
    "lib.nvim",
    "a file inside an area of the vault"
  )
  eq(ops.area_of_path(root, root .. "/not-an-area/x.md"), nil)
  eq(ops.area_of_path(root, ""), nil)

  -- ── relative paths and links ────────────────────────────────────────────────
  eq(ops.relative_to(root .. "/a/b/c.md", root .. "/a/x/y.md"), "../x/y.md")
  eq(ops.relative_to(root .. "/a/c.md", root .. "/a/dir"), "dir")
  eq(ops.markdown_link("lib backlog", "../x.md"), "[lib backlog](../x.md)")
  eq(
    ops.markdown_link("t", "my dir/x.md"),
    "[t](<my dir/x.md>)",
    "a target with a space is wrapped"
  )

  -- ── a note ──────────────────────────────────────────────────────────────────
  local note, nerr =
    ops.new_note(root, "lib.nvim", "feature", "Backlog Command", { date = "2026-10-14" })
  ok(note, "note created: " .. tostring(nerr))
  eq(note.file, "2026-10-14_backlog-command.md")
  eq(note.bucket, "FEATURES")
  ok(H.exists(note.path), "the note exists")
  has(H.read(note.path), "# Backlog Command", "with its title")
  local readme = H.read(root .. "/lib.nvim/Backlog/README.md")
  has(readme, "(./FEATURES/2026-10-14_backlog-command.md)", "its row is in the README")
  has(readme, "## FEATURES (1)", "and the count follows")
  local again, aerr =
    ops.new_note(root, "lib.nvim", "feature", "Backlog Command", { date = "2026-10-14" })
  ok(again == nil and aerr:find("exists already", 1, true), "an existing note is never overwritten")
  local bad = ops.new_note(root, "lib.nvim", "idea", "x")
  eq(bad, nil, "an unknown kind is refused")
  local blank = ops.new_note(root, "lib.nvim", "task", "   ")
  eq(blank, nil, "a blank title is refused")
  local t = assert(ops.new_note(root, "cascade.nvim", "task", "Sweep", { date = "2026-10-14" }))
  eq(t.bucket, "TASKS")

  -- ── a vault ─────────────────────────────────────────────────────────────────
  local newdir = H.tmpdir() .. "/fresh/vault"
  local made, merr = ops.create_vault(newdir, { "alpha.nvim", "beta" })
  ok(made, "vault created: " .. tostring(merr))
  eq(made.existed, false)
  ok(H.exists(newdir .. "/alpha.nvim/Backlog/FEATURES"), "areas get their Backlog")
  ok(H.exists(newdir .. "/alpha.nvim/ROADMAP/tasks"), "and their task folder")
  ok(H.exists(newdir .. "/README.md"), "the vault has a README")
  eq(vault.area_names(newdir), { "alpha.nvim", "beta" }, "the areas are the areas of the vault")
  local second = assert(ops.create_vault(newdir, { "alpha.nvim" }))
  eq(second.existed, true)
  eq(second.created, {}, "creating again changes nothing")
  eq((ops.create_vault(newdir, { "../x" })), nil, "an invalid area is refused")
  eq((ops.create_vault(newdir, { "TOOLS" })), nil, "a reserved folder is no area")
  eq((ops.create_vault("", {})), nil)

  -- ── the handlers ────────────────────────────────────────────────────────────
  local orig = { notify = vim.notify, select = vim.ui.select, input = vim.ui.input }
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local copied
  cmd.copy = function(text)
    copied = text
    return true
  end
  ---@param f fun()
  local function quiet(f)
    notes, copied = {}, nil
    f()
  end
  ---@param args? table
  ---@param flags? table
  ---@param rest? string[]
  local function ctx(args, flags, rest)
    return { args = args or {}, flags = flags or {}, kv = {}, rest = rest or {} }
  end

  quiet(function()
    cmd.clipboard(ctx({ target = "lib" }))
  end)
  eq(copied, root .. "/lib.nvim/Backlog", "clipboard: the folder, absolute")

  quiet(function()
    cmd.clipboard(ctx({ target = "lib", part = "all" }, { file = true }))
  end)
  eq(copied, nil, "--file with no index file for a part says so")
  has(notes[1].msg, "no index file", "and does not copy")

  quiet(function()
    cmd.clipboard(ctx({ target = "lib" }, { file = true }))
  end)
  eq(copied, root .. "/lib.nvim/Backlog/README.md", "--file: the index file")

  -- no buffer in an area: the picker is asked, and nothing is copied when it is dismissed
  local dismissed = false
  cmd.select = function(_, _, cb)
    dismissed = true
    cb(nil)
  end
  quiet(function()
    cmd.clipboard(ctx({ target = "features" }))
  end)
  ok(dismissed, "a part word alone needs an area: the buffer has none, so the picker is asked")
  eq(copied, nil, "and nothing is copied when it is dismissed")
  cmd.select = nil

  quiet(function()
    cmd.clipboard(ctx({ target = "zzz" }))
  end)
  has(notes[1].msg, "is not an area of the vault", "an unknown area is reported")
  eq(copied, nil)

  -- the area of the buffer
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/cascade.nvim/Backlog/README.md"))
  quiet(function()
    cmd.clipboard(ctx({ target = "tasks" }))
  end)
  eq(copied, root .. "/cascade.nvim/Backlog/TASKS", "a part word alone: the area of this buffer")
  quiet(function()
    cmd.clipboard(ctx({}))
  end)
  eq(copied, root .. "/cascade.nvim/Backlog", "no words: the Backlog of the area of this buffer")

  quiet(function()
    cmd.clipboard(ctx({ target = "lib" }, { rel = true }))
  end)
  eq(
    copied,
    "../../lib.nvim/Backlog",
    "--rel is relative to the folder of the current file (the Backlog of cascade.nvim)"
  )

  -- paste goes into the buffer at the cursor
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "see: " })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  quiet(function()
    cmd.paste(ctx({ target = "lib" }))
  end)
  eq(
    vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
    "see: " .. root .. "/lib.nvim/Backlog",
    "paste at the cursor"
  )

  vim.cmd("enew")
  vim.bo.modifiable = false
  quiet(function()
    cmd.paste(ctx({ target = "lib" }))
  end)
  eq(copied, root .. "/lib.nvim/Backlog", "a buffer that cannot take text gets the clipboard")
  has(notes[1].msg, "instead")
  vim.bo.modifiable = true

  -- link: relative to the current file
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/cascade.nvim/notes.md"))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  quiet(function()
    cmd.link(ctx({ target = "lib" }))
  end)
  eq(
    vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
    "[lib.nvim backlog](../lib.nvim/Backlog/README.md)",
    "link: Markdown, relative, to the index file"
  )
  vim.cmd("enew!")

  -- stray words are refused, not dropped
  quiet(function()
    cmd.clipboard(ctx({ target = "lib" }, {}, { "oops" }))
  end)
  eq(copied, nil)
  has(notes[1].msg, "unexpected argument")

  -- cdx
  quiet(function()
    cmd.cdx(ctx({ target = "lib", part = "features" }))
  end)
  has(copied, root .. "/lib.nvim/Backlog/FEATURES", "the prompt names the folder")
  has(copied, "lib.nvim")

  -- new
  quiet(function()
    cmd.new(ctx({ kind = "task" }, { area = "lib" }, { "Sweep", "the", "docs" }))
  end)
  ok(H.exists(root .. "/lib.nvim/Backlog/TASKS/" .. os.date("%Y-%m-%d") .. "_sweep-the-docs.md"))
  vim.cmd("enew!")
  quiet(function()
    cmd.new(ctx({ kind = "task" }, { area = "lib" }, {}))
  end)
  has(notes[1].msg, "needs a title")

  -- the area picker, when the buffer has none
  vim.cmd("enew!")
  local asked
  cmd.select = function(items, _, cb)
    asked = items
    cb("lib.nvim")
  end
  quiet(function()
    cmd.clipboard(ctx({}))
  end)
  eq(copied, root .. "/lib.nvim/Backlog", "the picker's answer is used")
  ok(vim.tbl_contains(asked, "cascade.nvim"), "it offers the areas of the vault")
  cmd.select = nil

  -- status
  quiet(function()
    cmd.status(ctx())
  end)
  has(notes[1].msg, root, "status names the vault")

  -- ── no vault: one message, no side effect ───────────────────────────────────
  vault.set_root(nil)
  vault.configure({ vault = "" })
  local verbs = { "open", "clipboard", "paste", "link", "find", "grep", "tree", "cdx", "status" }
  local first
  for _, verb in ipairs(verbs) do
    quiet(function()
      cmd[verb](ctx({ target = "lib" }))
    end)
    eq(#notes, 1, verb .. ": exactly one notice")
    eq(copied, nil, verb .. ": nothing copied")
    first = first or notes[1].msg
    eq(notes[1].msg, first, verb .. ": the same notice every time")
  end
  has(first, ":TasksVault create", "the notice names the way out")
  quiet(function()
    cmd.new(ctx({ kind = "task" }, {}, { "x" }))
  end)
  eq(notes[1].msg, first, "new says it too")

  -- create: from nothing, with a prompt for the folder and a plan that is confirmed first
  local confirm = require("tasks_nvim.ui.confirm")
  local confirm_was = confirm.yesno
  local plan_shown
  local answer = true
  confirm.yesno = function(msg, _, cb)
    plan_shown = msg
    cb(answer)
  end
  local target = H.tmpdir() .. "/via-command"
  vim.ui.input = function(opts, cb)
    ok(opts.prompt:find("Vault folder", 1, true), "asks for the folder")
    cb(target)
  end
  answer = false
  quiet(function()
    cmd.create(ctx({}, {}, { "one.nvim" }))
  end)
  ok(not H.exists(target), "a declined plan makes nothing")
  eq(vault.root(), nil, "and uses nothing")
  has(plan_shown, target, "the plan names the folder")
  has(plan_shown, "one.nvim", "and the areas")
  has(plan_shown, "REQUIRED", "and marks the step that is left to the user")
  has(plan_shown, 'vault = "' .. target .. '"', "with the line to write")
  has(plan_shown, "will NOT find", "and what happens without it")

  answer = true
  quiet(function()
    cmd.create(ctx({}, {}, { "one.nvim" }))
  end)
  ok(H.exists(target .. "/one.nvim/Backlog"), "create made the vault and its area")
  eq(vault.root(), target, "and the vault is in use for the session")
  has(notes[1].msg, "ONE STEP IS LEFT", "the result names the open step again")
  has(notes[1].msg, 'vault = "' .. target .. '"', "with the line to write")
  eq(copied, 'vault = "' .. target .. '",', "the line is in the clipboard")
  eq(notes[1].level, vim.log.levels.WARN, "at the level of a warning, not of information")

  quiet(function()
    cmd.create(ctx({ dir = H.tmpdir() .. "/other" }))
  end)
  has(notes[1].msg, "in use already", "a second create without --force is refused")
  ok(not H.exists(H.tmpdir() .. "/other"))
  plan_shown = nil
  quiet(function()
    cmd.create(ctx({ dir = target .. "-2" }, { force = true, yes = true }))
  end)
  eq(plan_shown, nil, "--yes skips the question")
  eq(vault.root(), target .. "-2", "--force switches the vault")
  confirm.yesno = confirm_was

  -- ── registration and completion ─────────────────────────────────────────────
  vault.configure({ vault = "" })
  vault.set_root(root)
  vim.notify, vim.ui.select, vim.ui.input = orig.notify, orig.select, orig.input
  cmd.copy = nil
  local reg = require("tasks_nvim.bindings.usrcmds.vault")
  ok(reg.register(), ":TasksVault registers")
  ok(reg.register(), "and a second time")
  eq(vim.fn.exists(":TasksVault"), 2, ":TasksVault exists")

  ---@param line string
  ---@return string[]
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end
  local verbs_found = complete("TasksVault ")
  for _, verb in ipairs({
    "open",
    "clipboard",
    "paste",
    "link",
    "find",
    "grep",
    "tree",
    "cdx",
    "new",
    "create",
    "status",
  }) do
    ok(vim.tbl_contains(verbs_found, verb), "the verb " .. verb .. " completes")
  end
  local areas = complete("TasksVault clipboard ")
  ok(vim.tbl_contains(areas, "lib.nvim"), "areas complete")
  ok(vim.tbl_contains(areas, "features"), "and parts")
  eq(complete("TasksVault clipboard lib.nvim fe"), { "features" }, "the part after the area")

  local paths = {}
  for _, r in ipairs(routes.routes()) do
    paths[#paths + 1] = table.concat(r.path, " ")
  end
  table.sort(paths)
  eq(paths, {
    "cdx",
    "clipboard",
    "create",
    "find",
    "grep",
    "link",
    "new",
    "open",
    "paste",
    "status",
    "tree",
  }, "the routes of :TasksVault, no two sharing a path")

  vault.set_root(nil)
  vim.env.TASKS_VAULT = env_was
end
