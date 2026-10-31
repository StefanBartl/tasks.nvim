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
---@field tasks_cli? string            # The engine testing.nvim writes with (default: this plugin's `scripts/tasks.lua`).
---@field timeout_ms? integer          # Default `TIMEOUT_MS`.

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

---This plugin's own `scripts/tasks.lua`: handed on as `--tasks-cli`, so the engine that writes the block is the one
---that asked (not another checkout testing.nvim might find first).
---@return string|nil
function M.own_cli()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(src, ":p"))))
  local cli = vim.fs.normalize(root .. "/scripts/tasks.lua")
  return vim.fn.filereadable(cli) == 1 and cli or nil
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
  local own = opts.tasks_cli or M.own_cli()
  if own then
    vim.list_extend(argv, { "--tasks-cli", own })
  end
  if opts.dry_run then
    argv[#argv + 1] = "--dry-run"
  end
  return argv
end

---How long a run may take before it is stopped: 30 minutes (a sheet bounds each of its waits, many of them add up).
M.TIMEOUT_MS = 30 * 60 * 1000

---@class Tasks.SheetRunResult
---@field code integer                 # The exit code of `testing sheets run` (`EXIT`), 3 when it did not start or was stopped.
---@field lines string[]               # What it printed (stdout, then stderr), one entry per line.
---@field summary string               # One line for a notification: what ran and how it ended, and why.

---The outcomes of a written task that are no failure.
local WRITTEN = { changed = true, unchanged = true, would_change = true }

---Turn the output of a run into its result.
---@param code integer
---@param stdout string
---@param stderr string
---@param signal? integer  # A process stopped by a signal (a timeout, a kill) gives no verdict of its own.
---@return Tasks.SheetRunResult
function M.result(code, stdout, stderr, signal)
  local lines = {}
  for _, text in ipairs({ stdout or "", stderr or "" }) do
    for line in text:gmatch("[^\r\n]+") do
      lines[#lines + 1] = line
    end
  end
  if signal and signal ~= 0 then
    return {
      code = M.EXIT.engine,
      lines = lines,
      summary = ("testing.nvim was stopped (signal %d, after %d min at most)"):format(
        signal,
        M.TIMEOUT_MS / 60000
      ),
    }
  end
  -- why, in this order: a red sheet, a task that was not written, a refusal or usage line, an error of the entry
  local red, task, said, other
  for _, line in ipairs(lines) do
    if not red and (line:match("^sheet .-: fail") or line:match("^sheet .-: does not load")) then
      red = line
    end
    local outcome = line:match("^testing sheets: task %S+ (%S+)")
    if outcome then
      if not task and not WRITTEN[(outcome:gsub(":$", ""))] then
        task = line
      end
    elseif not said and line:match("^testing sheets: ") then
      said = line
    elseif not other and line:match("^testing: ") then
      other = line
    end
  end
  local verdict, why
  if code == 0 then
    verdict = "green"
  elseif code == 1 then
    verdict = red and "red" or "the task was not written"
    why = red or task or said or other
  elseif code == 2 then
    verdict, why = "refused", said or other
  else
    verdict = ("testing.nvim failed (exit %d)"):format(code)
    why = said or other or lines[#lines]
  end
  return { code = code, lines = lines, summary = verdict .. (why and (": " .. why) or "") }
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
  local o = { text = true, cwd = opts.vault, timeout = opts.timeout_ms or M.TIMEOUT_MS }
  local function finish(r)
    return M.result(r.code or M.EXIT.engine, r.stdout or "", r.stderr or "", r.signal)
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
