-- TESTS/tasks_init_vault_spec.lua -- `init-vault <dir>`: a new vault with a first area and an example task, a dry run
-- first, nothing overwritten; and `examples/vault`, the small real vault that ships with the plugin, stays valid.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local cli = require("tasks_nvim.cli")

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), { "--today=2026-01-05" }), {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local dir = H.tmpdir() .. "/fresh vault"

  -- ── the dry run writes nothing ─────────────────────────────────────────
  local dry = run({ "init-vault", dir })
  eq(dry.code, 0, dry.err)
  has(dry.out, "would-make\tREADME.md")
  has(dry.out, "would-make\tInbox/ROADMAP/tasks/")
  has(dry.out, "dry-run")
  ok(not vim.uv.fs_stat(dir), "a dry run made the folder")

  -- ── --apply makes the vault, a second run adds nothing ─────────────────
  local made = run({ "init-vault", dir, "--apply" })
  eq(made.code, 0, made.err)
  has(made.out, "made\tREADME.md")
  has(made.out, "created\tInbox/erste-task-anlegen-bearbeiten-erledigen")
  ok(vim.uv.fs_stat(dir .. "/Inbox/ROADMAP/TASKS.md"), "the index is written")
  eq(run({ "check", "--vault=" .. dir }).code, 0, "the new vault passes check")

  has(made.out, "made\tInbox/ROADMAP/tasks/")
  local first = H.read(dir .. "/Inbox/ROADMAP/tasks/erste-task-anlegen-bearbeiten-erledigen.md")
  has(first, "created: 2026-01-05", "--today reaches the example task")

  local again = run({ "init-vault", dir, "--apply" })
  eq(again.code, 0, again.err)
  ok(not again.out:find("made\t", 1, true), "a second run made something: " .. again.out)
  ok(not again.out:find("created\t", 1, true), "a second run added a second example task")

  -- ── options and refusals ───────────────────────────────────────────────
  local en = run({ "init-vault", H.tmpdir() .. "/en", "--area=work", "--lang=en", "--apply" })
  eq(en.code, 0, en.err)
  has(en.out, "created\twork/first-task-create-edit-finish")

  eq(run({ "init-vault" }).code, 2, "the folder is required")
  eq(run({ "init-vault", dir, dir }).code, 2, "one folder only")
  eq(run({ "init-vault", dir, "--lang=fr" }).code, 2)
  eq(run({ "init-vault", dir, "--apply", "--dry-run" }).code, 2)
  eq(
    run({ "init-vault", H.tmpdir() .. "/x", "--area=TOOLS", "--apply" }).code,
    1,
    "a folder that is never an area"
  )
  eq(
    run({ "init-vault", H.tmpdir() .. "/y", "--area=../out", "--apply" }).code,
    1,
    "an area cannot leave the vault"
  )
  local file = H.tmpdir() .. "/a-file"
  H.write(file, "x")
  eq(run({ "init-vault", file, "--apply" }).code, 1, "a file is no vault folder")

  -- ── found in review ────────────────────────────────────────────────────
  local home = H.tmpdir() .. "/home-like"
  H.write(home .. "/notes.txt", "x")
  vim.fn.mkdir(home .. "/Documents", "p")
  local refused = run({ "init-vault", home })
  eq(refused.code, 1, "a folder with foreign files is not made a vault by a typo")
  has(refused.err, "--force")
  ok(not vim.uv.fs_stat(home .. "/README.md"))
  eq(run({ "init-vault", home, "--force", "--apply" }).code, 0, "--force makes it there anyway")

  local folder_vault = H.tmpdir() .. "/folder-task"
  H.write(
    folder_vault .. "/Inbox/ROADMAP/tasks/kept/kept.md",
    "---\ntitle: Kept\nstatus: open\n---\n"
  )
  local folder_run = run({ "init-vault", folder_vault, "--force", "--apply" })
  eq(folder_run.code, 0, folder_run.err)
  ok(
    not folder_run.out:find("created\t", 1, true),
    "a folder task counts as a task: no example task"
  )

  has(run({ "init-vault", H.tmpdir() .. "/z", "--vault=" .. dir }).err, "--vault is ignored")

  -- ── found in the second review ─────────────────────────────────────────
  local bad_date = H.tmpdir() .. "/bad-date"
  local errs = {}
  local code = cli.run({ "init-vault", bad_date, "--apply", "--today=2026-13-45" }, {
    out = function() end,
    err = function(t)
      errs[#errs + 1] = t
    end,
  })
  eq(code, 2, "a bad --today is a usage error")
  has(table.concat(errs, "\n"), "--today must be YYYY-MM-DD")
  ok(not vim.uv.fs_stat(bad_date), "a bad --today left a half-made vault")

  local repo_first = H.tmpdir() .. "/git-first"
  vim.fn.mkdir(repo_first .. "/.git", "p")
  H.write(repo_first .. "/.gitignore", "x\n")
  eq(
    run({ "init-vault", repo_first, "--apply" }).code,
    0,
    "a folder with only hidden entries (git init first) needs no --force"
  )

  -- ── examples/vault: valid and its indexes current ──────────────────────
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local example = vim.fs.normalize(here .. "/../examples/vault")
  local checked = run({ "check", "--vault=" .. example })
  eq(checked.code, 0, checked.out .. checked.err)
  has(checked.out, "0 finding(s)")
  eq(
    run({ "index", "--check", "--vault=" .. example }).code,
    0,
    "examples/vault has a stale TASKS.md"
  )
end
