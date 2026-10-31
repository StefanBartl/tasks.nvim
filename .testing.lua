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
  -- SNACKS_DIR: the dashboard specs find snacks.nvim there (the runner isolates stdpath('data'), so scripts/test.sh
  -- looks snacks.nvim up and sets it).
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
      -- the test-script spec runs scripts/test.sh in a throwaway project with a stand-in nvim
      "bash",
    },
  },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K6",
        level = "warn",
        text = "vault not found",
        reason = "the plugin needs a task vault (setup vault, $TASKS_VAULT or --vault); the minimal conformance editor has none, and the health message is correct",
        expires = "2027-04-14",
      },
    },
  },
  -- The pipeline `scripts/ci.sh` (a shim for `testing ci`) and the workflow run; `--fast` is the pre-push profile.
  -- The schema contract check needs Node and runs in the CI job `contract` only.
  ci = {
    default = "full",
    profiles = {
      fast = { "stylua", "luacheck" },
      full = { "fast", "suite", "conformance", "contract" },
    },
    steps = {
      luacheck = { preset = "luacheck", args = { "lua", "TESTS", "scripts" } },
      -- tasks-export/1 from outside (schema, golden files, refused documents, TypeScript types); installs the dev
      -- dependencies of contract/ on first use.
      contract = { run = { "scripts/contract.sh" }, needs = { "node", "npm" } },
    },
  },
}
