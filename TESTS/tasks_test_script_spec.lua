-- TESTS/tasks_test_script_spec.lua -- scripts/test.sh, the runner of this suite: the optional snacks.nvim is looked up
-- like the other dependencies and handed to the specs as $SNACKS_DIR. The runner gives every child editor a sandbox
-- stdpath('data'), so the dashboard specs cannot find a plugin-manager install by themselves: without this the
-- picker part of tasks_dash_picker_spec / tasks_dash_refresh_spec silently stopped running on a local machine.
-- The real script runs in throw-away projects with a stand-in `nvim` that prints what it was given. A run of the
-- script starts a handful of processes (slow under Git Bash), so all runs are started first and waited for after.
-- Skipped (reported, not failed) when no POSIX bash is usable (on Windows `bash` can be WSL's bash.exe).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks

  local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
  local is_win = vim.fn.has("win32") == 1

  --- A POSIX bash this spec can drive: on Windows Git Bash (it has cygpath), not WSL's bash.exe.
  ---@return boolean
  local function bash_usable()
    if vim.fn.executable("bash") ~= 1 then
      return false
    end
    local probe = is_win and "command -v cygpath" or "true"
    local r = vim.system({ "bash", "-c", probe }, { text = true }):wait(30000)
    return r.code == 0
  end

  -- This sits before the first assertion on purpose: testing.nvim turns a printed `skip` line into a SKIP only for a
  -- spec that has asserted nothing (a spec that asserted first keeps its verdict, a green PASS).
  if not bash_usable() then
    io.stdout:write("skip  tasks_test_script_spec.lua: no POSIX bash on PATH\n")
    return
  end

  local script_text = H.read(repo .. "/scripts/test.sh")
  ok(script_text, "scripts/test.sh is readable")

  --- The spelling of an environment variable name that the process environment already uses (Windows: `Path`).
  ---@param name string
  ---@return string
  local function env_key(name)
    for key in pairs(vim.fn.environ()) do
      if key:lower() == name:lower() then
        return key
      end
    end
    return name
  end

  ---@class TasksTestScript.Project
  ---@field top string   everything lives below it
  ---@field proj string  the project; its parent is `top`, so the script's `../snacks.nvim` is `top/snacks.nvim`

  --- A throw-away project: the real script, fake dependencies, a stand-in `nvim` that reports $SNACKS_DIR.
  ---@return TasksTestScript.Project
  local function project()
    local top = H.tmpdir()
    H.write(top .. "/proj/scripts/test.sh", script_text)
    H.write(top .. "/fake/testing.nvim/scripts/testing.lua", "")
    vim.fn.mkdir(top .. "/fake/testing.nvim/lua/testing", "p")
    vim.fn.mkdir(top .. "/fake/lib.nvim/lua/lib/nvim", "p")
    local stub = top .. "/bin/nvim"
    H.write(stub, '#!/bin/sh\necho "stub-nvim SNACKS_DIR=[${SNACKS_DIR:-}]"\n')
    vim.uv.fs_chmod(stub, tonumber("755", 8))
    return { top = top, proj = top .. "/proj" }
  end

  --- A valid snacks.nvim checkout (what the script and the specs look for) at `dir`.
  ---@param dir string
  local function snacks_at(dir)
    vim.fn.mkdir(dir .. "/lua/snacks/picker", "p")
  end

  --- Start the script. `$SNACKS_DIR` starts empty and the data folder is inside `top`, whatever the machine has.
  ---@param p TasksTestScript.Project
  ---@param env? table<string, string>
  ---@return vim.SystemObj
  local function start(p, env)
    local full = {
      TESTING_NVIM_DIR = p.top .. "/fake/testing.nvim",
      LIB_NVIM_DIR = p.top .. "/fake/lib.nvim",
      SNACKS_DIR = "",
      NVIM_APPNAME = "nvim",
      [env_key("LOCALAPPDATA")] = p.top .. "/localapp",
      [env_key("PATH")] = p.top .. "/bin" .. (is_win and ";" or ":") .. (vim.env.PATH or ""),
    }
    for key, value in pairs(env or {}) do
      full[key] = value
    end
    return vim.system({ "bash", p.proj .. "/scripts/test.sh" }, { text = true, env = full })
  end

  ---@param handle vim.SystemObj
  ---@return integer code
  ---@return string stdout
  ---@return string stderr
  local function finish(handle)
    local r = handle:wait(120000)
    return r.code, r.stdout or "", r.stderr or ""
  end

  --- What the stand-in `nvim` saw in $SNACKS_DIR (nil when it did not run).
  ---@param out string
  ---@return string|nil
  local function seen_snacks(out)
    return out:match("stub%-nvim SNACKS_DIR=%[(.-)%]")
  end

  ---@param value string|nil
  ---@param suffix string
  ---@param msg string
  local function ends_with(value, suffix, msg)
    ok(
      value and vim.endswith(value, suffix),
      ("%s: expected ...%s, got %s"):format(msg, suffix, vim.inspect(value))
    )
  end

  -- 1. .deps/snacks.nvim is found and handed down; it wins over the data folder
  local p_deps = project()
  snacks_at(p_deps.proj .. "/.deps/snacks.nvim")
  snacks_at(p_deps.top .. "/localapp/nvim-data/lazy/snacks.nvim")
  local run_deps = start(p_deps)

  -- 2. the plugin manager's data folder (the case that stopped working); a directory that is no snacks.nvim
  --    checkout (.deps/snacks.nvim here) is not taken
  local p_lazy = project()
  vim.fn.mkdir(p_lazy.proj .. "/.deps/snacks.nvim", "p")
  snacks_at(p_lazy.top .. "/localapp/nvim-data/lazy/snacks.nvim")
  local run_lazy = start(p_lazy)

  -- 3. $SNACKS_DIR decides alone, and an invalid one fails the run instead of being skipped
  local p_env = project()
  snacks_at(p_env.proj .. "/.deps/snacks.nvim")
  snacks_at(p_env.top .. "/override/snacks.nvim")
  local run_override = start(p_env, { SNACKS_DIR = p_env.top .. "/override/snacks.nvim" })
  local run_invalid = start(p_env, { SNACKS_DIR = p_env.top .. "/no-such-dir" })

  -- 4. the dependencies of the runner stay mandatory
  local run_lib = start(p_env, { LIB_NVIM_DIR = p_env.top .. "/no-such-dir" })

  -- 5. not found anywhere: the run goes on and says so
  local run_none = start(project())

  local code, out, err = finish(run_deps)
  eq(code, 0, err)
  ends_with(seen_snacks(out), "/proj/.deps/snacks.nvim", ".deps comes first")
  lacks(err, "optional dependency", "a found dependency adds no note")

  code, out, err = finish(run_lazy)
  eq(code, 0, err)
  ends_with(seen_snacks(out), "/localapp/nvim-data/lazy/snacks.nvim", "lazy.nvim's data folder")

  code, out, err = finish(run_override)
  eq(code, 0, err)
  ends_with(seen_snacks(out), "/override/snacks.nvim", "$SNACKS_DIR wins over .deps")

  code, out, err = finish(run_invalid)
  eq(code, 1, "an override that is set but not valid fails the run")
  has(err, "dependency 'snacks.nvim' not found")
  has(err, "$SNACKS_DIR")
  eq(seen_snacks(out), nil, "the runner was not started")

  code, out, err = finish(run_lib)
  eq(code, 1)
  has(err, "dependency 'lib.nvim' not found")
  eq(seen_snacks(out), nil, "the runner was not started")

  code, out, err = finish(run_none)
  eq(code, 0, "snacks.nvim is optional: " .. err)
  eq(seen_snacks(out), "", "nothing is handed down")
  has(err, "optional dependency snacks.nvim not found")
  has(err, "$SNACKS_DIR")
  has(err, ".deps/snacks.nvim")
end
