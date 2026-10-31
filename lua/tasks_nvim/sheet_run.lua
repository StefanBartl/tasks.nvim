---@module 'tasks_nvim.sheet_run'
---@brief Run the test sheets of a task now: `testing sheets run --task <id> --tasks <vault>` (testing.nvim) as a process.
---@description
--- A live-check task names its test sheets in the block testing.nvim writes (`tasks_nvim.sheets`). This module starts
--- testing.nvim's command for one task: it finds the task's sheets, runs them headless and writes their state into the
--- block through this engine's `call ops`. The two plugins meet only on that command line and the block; neither
--- loads the other's Lua.
---
--- testing.nvim is found like a dependency: `opts.cli` (`--testing-cli`, `sheet_run.testing_cli` of `setup()`), then
--- `$TESTING_NVIM_DIR`, `$REPOS_DIR/testing.nvim`, `<vault>/../testing.nvim`, `stdpath('data')/lazy/testing.nvim`; each
--- must hold `scripts/testing.lua`. Whether a sheet may run (trust, the workstation) is testing.nvim's decision; its
--- refusal comes back as the exit code and the message.
---
--- Not its job: running a sheet, the trust gate, writing the block (testing.nvim); reading the block (`sheets`).

local M = {}

---Exit codes of `testing sheets run` (testing.nvim docs/SHEETS.md).
M.EXIT = { green = 0, red = 1, refused = 2, engine = 3 }

---@class Tasks.SheetRunOpts
---@field vault string                 # The vault root (passed on as `--tasks`).
---@field cli? string                  # Path of testing.nvim's `scripts/testing.lua`.
---@field dry_run? boolean
---@field getenv? fun(name: string): string|nil
---@field data_dir? string             # `stdpath('data')` (specs).

---Where testing.nvim's command line is: the path of `scripts/testing.lua`, or nil and the places looked at.
---@param opts Tasks.SheetRunOpts
---@return string|nil cli, string|nil err
function M.locate(opts)
  if opts.cli then
    if vim.fn.filereadable(opts.cli) == 1 then
      return vim.fs.normalize(opts.cli)
    end
    return nil, "testing.nvim: " .. opts.cli .. " is not readable"
  end
  local getenv = opts.getenv or vim.uv.os_getenv
  local tried, dirs = {}, {}
  local function add(dir)
    if dir and dir ~= "" then
      dirs[#dirs + 1] = dir
    end
  end
  add(getenv("TESTING_NVIM_DIR"))
  local repos = getenv("REPOS_DIR")
  add(repos and repos ~= "" and (repos .. "/testing.nvim") or nil)
  add(vim.fs.dirname(opts.vault) .. "/testing.nvim")
  add((opts.data_dir or vim.fn.stdpath("data")) .. "/lazy/testing.nvim")
  for _, dir in ipairs(dirs) do
    local cli = vim.fs.normalize(dir .. "/scripts/testing.lua")
    tried[#tried + 1] = cli
    if vim.fn.filereadable(cli) == 1 then
      return cli
    end
  end
  return nil,
    "testing.nvim not found (looked at "
      .. table.concat(tried, ", ")
      .. "); set TESTING_NVIM_DIR or sheet_run.testing_cli"
end

---The command that runs the sheets of `id`.
---@param id string
---@param cli string
---@param opts Tasks.SheetRunOpts
---@return string[]
function M.argv(id, cli, opts)
  local argv = {
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-l",
    cli,
    "sheets",
    "run",
    "--task",
    id,
    "--tasks",
    opts.vault,
  }
  if opts.dry_run then
    argv[#argv + 1] = "--dry-run"
  end
  return argv
end

---@class Tasks.SheetRunResult
---@field code integer                 # The exit code of `testing sheets run` (`EXIT`), or 3 when it did not start.
---@field lines string[]               # What it printed (stdout, then stderr), one entry per line.
---@field summary string               # One line for a notification: what ran and how it ended.

---Turn the output of a run into its result.
---@param code integer
---@param stdout string
---@param stderr string
---@return Tasks.SheetRunResult
function M.result(code, stdout, stderr)
  local lines = {}
  for _, text in ipairs({ stdout or "", stderr or "" }) do
    for line in text:gmatch("[^\r\n]+") do
      lines[#lines + 1] = line
    end
  end
  local verdict = ({
    [0] = "green",
    [1] = "red (or the task was not written)",
    [2] = "refused",
    [3] = "testing.nvim could not reach the engine",
  })[code] or ("ended with exit " .. tostring(code))
  -- the first line that says why: a red sheet, a refusal
  local why
  for _, line in ipairs(lines) do
    if
      line:match(": fail")
      or line:match("does not load")
      or (line:match("^testing sheets: ") and not line:match("^testing sheets: task "))
    then
      why = line
      break
    end
  end
  return {
    code = code,
    lines = lines,
    summary = verdict .. (code ~= 0 and why and (": " .. why) or ""),
  }
end

---Run the sheets of a task. With `on_done` the run is asynchronous (the editor); without, it waits (the CLI).
---@param id string
---@param opts Tasks.SheetRunOpts
---@param on_done? fun(res: Tasks.SheetRunResult)
---@param system? fun(argv: string[], o: table, cb?: fun(r: table)): table A stand-in for `vim.system` (specs).
---@return Tasks.SheetRunResult|nil result  # nil when `on_done` is given.
function M.run(id, opts, on_done, system)
  local cli, err = M.locate(opts)
  if not cli then
    local res = M.result(M.EXIT.engine, "", tostring(err))
    res.summary = tostring(err)
    if on_done then
      on_done(res)
      return nil
    end
    return res
  end
  system = system or vim.system
  local argv = M.argv(id, cli, opts)
  local o = { text = true, cwd = opts.vault }
  local function finish(r)
    return M.result(r.code or M.EXIT.engine, r.stdout or "", r.stderr or "")
  end
  local ok, handle = pcall(system, argv, o, on_done and function(r)
    vim.schedule(function()
      on_done(finish(r))
    end)
  end or nil)
  if not ok then
    local res = M.result(M.EXIT.engine, "", tostring(handle))
    res.summary = "testing.nvim did not start: " .. tostring(handle)
    if on_done then
      on_done(res)
      return nil
    end
    return res
  end
  if on_done then
    return nil
  end
  return finish(handle:wait())
end

return M
