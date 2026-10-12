-- TESTS/tasks_engine_git_spec.lua -- the commit a document names as its engine: what is kept for the life of the
-- process (an answer of git) and what is asked again (no answer in time).

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces vim.system for the lookup on purpose, so no git is started.

return function(H)
  local eq, ok = H.eq, H.ok

  local real_system = vim.system
  local real_loaded = package.loaded["tasks_nvim.contract"]

  ---Run `fn(git)` with a freshly loaded contract module (its cache is file-local) and a scripted `vim.system`.
  ---@param script (table|string)[]  # per call: `{ code, signal, stdout }`, or a string = the start fails with it
  ---@param fn fun(git: fun(): string, calls: integer[])  # `calls` collects the wait of each call
  local function with_script(script, fn)
    local calls = {}
    vim.system = function()
      local step = script[#calls + 1]
      return {
        wait = function(_, ms)
          calls[#calls + 1] = ms
          if type(step) == "string" then
            error(step)
          end
          return { code = step[1], signal = step[2], stdout = step[3] or "" }
        end,
      }
    end
    package.loaded["tasks_nvim.contract"] = nil
    local contract = require("tasks_nvim.contract")
    local run_ok, err = pcall(fn, function()
      return contract.engine_info().git
    end, calls)
    vim.system = real_system
    package.loaded["tasks_nvim.contract"] = real_loaded
    assert(run_ok, err)
  end

  -- a timeout (code 124, the signal of the kill) is not kept: the next call asks again and keeps the answer
  with_script({ { 124, 9 }, { 0, 0, "abc1234\n" } }, function(git, calls)
    eq(git(), "unknown", "no answer in time")
    eq(git(), "abc1234", "the next call asks again; the newline is cut")
    eq(git(), "abc1234", "an answer is kept")
    eq(#calls, 2, "no third look")
  end)

  -- only the first look gets the full wait; a retry is quick
  with_script({ { 124, 9 }, { 124, 9 }, { 124, 9 } }, function(git, calls)
    git()
    git()
    git()
    eq(calls, { 2000, 500, 500 }, "2 s for the first look, 0.5 s for each retry")
  end)

  -- git ran and said there is no commit (code 128: not a repository): that stays
  with_script({ { 128, 0 } }, function(git, calls)
    eq(git(), "unknown")
    eq(git(), "unknown")
    eq(#calls, 1, "an answer of git is not asked again")
  end)

  -- an error of the start is a no-answer, not a kept one
  with_script({ "spawn failed", { 0, 0, "def5678\n" } }, function(git, calls)
    eq(git(), "unknown", "the start failed")
    eq(git(), "def5678", "recovers on a later call")
    eq(#calls, 2)
  end)

  -- three misses in a row: "unknown" is kept and git is left alone
  with_script({ { 124, 9 }, { 124, 9 }, { 124, 9 }, { 0, 0, "aaa1111\n" } }, function(git, calls)
    for _ = 1, 5 do
      eq(git(), "unknown")
    end
    eq(#calls, 3, "the limit of three looks")
  end)

  -- the code of `:wait` alone says "timed out", whatever the platform reports as signal
  with_script({ { 124, 0 }, { 0, 0, "bbb2222\n" } }, function(git, calls)
    eq(git(), "unknown")
    eq(git(), "bbb2222", "code 124 without a signal is not pinned either")
    eq(#calls, 2)
  end)

  -- an answer of git that is not a commit is an answer: "unknown", kept
  with_script({ { 0, 0, "fatal: not a hash\n" }, { 0, 0, "ccc3333\n" } }, function(git, calls)
    eq(git(), "unknown")
    eq(git(), "unknown")
    eq(#calls, 1)
  end)

  ok(package.loaded["tasks_nvim.contract"] == real_loaded, "the module of the other specs is back")
end
