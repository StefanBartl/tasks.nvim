-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "tasks_nvim",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "h",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  -- "file": the specs register user commands, highlight groups and snacks globals and leave buffers behind;
  -- one editor per file keeps that from piling up (and keeps the state guard quiet) at the same total run time.
  isolated = "file",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  -- SNACKS_DIR: the dashboard specs find snacks.nvim there (the runner isolates stdpath('data')).
  env_allow = { "REPOS_DIR", "SNACKS_DIR", "TASKS_REQUIRE_SNACKS" },
  -- The guards (docs/GUARDS.md of testing.nvim). The suite is clean on all of them, so they all fail the run.
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "error",
  },
  -- What the specs start on purpose; everything else is blocked.
  guard_allow = {
    spawn = {
      -- the CLI specs run scripts/tasks.lua and scripts/tasks-ci.lua in a child Neovim, like a user does
      "nvim",
      -- the staleness spec builds throwaway git repos in a temp folder and reads their history
      "git",
    },
  },
}
