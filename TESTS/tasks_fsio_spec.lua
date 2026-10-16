-- TESTS/tasks/tasks_fsio_spec.lua -- tasks.fsio: atomic writes.

return function(H)
  local eq, ok = H.eq, H.ok
  local fsio = require("tasks_nvim.fsio")
  local uv = vim.uv or vim.loop

  local dir = H.tmpdir()
  local target = dir .. "/sub/TASKS.md"

  --- Names in `d` that look like a leftover temp file.
  ---@param d string
  ---@return string[]
  local function temps(d)
    local out = {}
    for name in vim.fs.dir(d) do
      if name:find("tasks-tmp", 1, true) then
        out[#out + 1] = name
      end
    end
    return out
  end

  -- Creates the parent, writes the bytes as given, leaves no temp file.
  local wrote, werr = fsio.write_atomic(target, "one\r\ntwo")
  ok(wrote, "write failed: " .. tostring(werr))
  eq(H.read(target), "one\r\ntwo", "bytes written as given")
  eq(temps(dir .. "/sub"), {}, "no temp file left behind")

  -- A stale temp file under the old fixed name neither blocks nor is reused.
  H.write(target .. ".tasks-tmp", "stale")
  local again, aerr = fsio.write_atomic(target, "three")
  ok(again, "write beside a stale temp file failed: " .. tostring(aerr))
  eq(H.read(target), "three", "target replaced")
  eq(H.read(target .. ".tasks-tmp"), "stale", "the legacy fixed temp name is not touched")

  -- Two writes of different content in a row (one process) never mix.
  for i = 1, 20 do
    local body = ("round %d\n"):format(i)
    ok(fsio.write_atomic(target, body), "round " .. i)
    eq(H.read(target), body, "round " .. i .. " content")
  end
  vim.fn.delete(target .. ".tasks-tmp")
  eq(temps(dir .. "/sub"), {}, "still no temp file left behind")

  -- Binary content of some size (NUL, CR LF, high bytes, no final newline) is
  -- written byte for byte, and an empty string writes an empty file.
  local blob = ("a\0b\r\n\255\128"):rep(700000)
  ok(fsio.write_atomic(target, blob), "a 5 MB blob")
  eq(H.read(target), blob, "blob read back byte-exact")
  ok(fsio.write_atomic(target, ""), "empty content")
  eq(H.read(target), "", "an empty file")
  eq(temps(dir .. "/sub"), {}, "no temp file left behind by the big writes either")

  -- A failing rename (the target is a directory) reports the error and leaves no temp file.
  vim.fn.mkdir(dir .. "/sub/is-a-dir", "p")
  local blocked, berr = fsio.write_atomic(dir .. "/sub/is-a-dir", "x")
  eq(blocked, false, "cannot replace a directory")
  ok(berr and berr:find("rename failed", 1, true), "the error names the step: " .. tostring(berr))
  eq(temps(dir .. "/sub"), {}, "the temp file of the failed write is removed")

  -- The mode of the replaced file is kept (POSIX; Windows has no such modes).
  if vim.fn.has("win32") == 0 then
    local private = dir .. "/sub/private.md"
    H.write(private, "old")
    uv.fs_chmod(private, tonumber("600", 8))
    ok(fsio.write_atomic(private, "new"))
    eq(H.read(private), "new")
    eq(uv.fs_stat(private).mode % 4096, tonumber("600", 8), "a 0600 file stays 0600")
  end

  -- A read scope remembers what the disk said, ends with the function (also on an error) and nests.
  local probe = dir .. "/scope/probe.txt"
  eq(fsio.is_file(probe), false, "no scope: the disk answers")
  fsio.read_scope(function()
    eq(fsio.is_file(probe), false, "asked inside the scope")
    H.write(probe, "x")
    eq(fsio.is_file(probe), false, "the scope keeps its first answer")
    fsio.read_scope(function()
      eq(fsio.is_file(probe), false, "a nested scope shares the outer one")
    end)
    local function memo(v)
      return fsio.scope_memo("k", function()
        return v
      end)
    end
    eq(memo(1), 1)
    eq(memo(2), 1, "computed once per scope")
  end)
  eq(fsio.is_file(probe), true, "after the scope the disk answers again")
  vim.fn.delete(probe)

  -- The scope is closed after an error, too: the very same question gets a fresh answer.
  local late = dir .. "/scope/late.txt"
  local raised = pcall(fsio.read_scope, function()
    eq(fsio.is_file(late), false)
    H.write(late, "x")
    error("boom")
  end)
  eq(raised, false, "an error passes through")
  eq(fsio.is_file(late), true, "and the scope is closed after it")
  vim.fn.delete(late)

  -- ... also when the error comes from a nested scope that the outer one catches.
  fsio.read_scope(function()
    eq(fsio.is_file(late), false)
    local inner = pcall(fsio.read_scope, function()
      error("inner")
    end)
    eq(inner, false)
    H.write(late, "x")
    eq(fsio.is_file(late), false, "the outer scope is still open and keeps its answer")
  end)
  eq(fsio.is_file(late), true, "and it closes with its own function")
  vim.fn.delete(late)

  -- Two results pass through, a nil first one with its error as well.
  local r1, r2 = fsio.read_scope(function()
    return nil, "e"
  end)
  eq({ r1, r2 }, { nil, "e" }, "(nil, err) is handed on")

  -- What is not there (and not a link, no real path) is not remembered for a link guard: it must see a late arrival.
  local missing = dir .. "/scope/real-missing"
  fsio.read_scope(function()
    eq(fsio.realpath(missing), nil)
    eq(fsio.lstat(missing), nil)
    vim.fn.mkdir(missing, "p")
    ok(fsio.realpath(missing), "a real path that was missing is asked again")
    ok(fsio.lstat(missing), "so is the lstat")
    ok(fsio.realpath(missing) == fsio.realpath(missing), "an answer is remembered")
  end)
  vim.fn.delete(missing, "d")

  -- A write of the module empties what the scope knows.
  local written = dir .. "/scope/written.txt"
  fsio.read_scope(function()
    eq(fsio.is_file(written), false)
    ok(fsio.write_atomic(written, "x"))
    eq(fsio.is_file(written), true, "the question after a write is answered from the disk")
    eq(
      fsio.scope_memo("w", function()
        return 1
      end),
      1
    )
    ok(fsio.remove(written))
    eq(fsio.is_file(written), false)
    eq(
      fsio.scope_memo("w", function()
        return 2
      end),
      2,
      "the remembered values went with the write"
    )
  end)

  -- Another coroutine never gets the answers of the scope that is open in this one.
  local seen = {}
  fsio.read_scope(function()
    eq(fsio.is_file(late), false)
    H.write(late, "x")
    local co = coroutine.create(function()
      seen.foreign = fsio.is_file(late)
      seen.nested = fsio.read_scope(function()
        return fsio.is_file(late)
      end)
    end)
    ok(coroutine.resume(co))
    eq(fsio.is_file(late), false, "the owner still has its answer")
  end)
  eq(seen, { foreign = true, nested = true }, "a foreign coroutine asked the disk")
  vim.fn.delete(late)

  -- ── copy: the "target exists" answer is copy's own, not the token of lib.nvim's create_exclusive ──
  do
    local src = dir .. "/copy-src.txt"
    local dst = dir .. "/copy-dst.txt"
    H.write(src, "source")
    local first, first_err = fsio.copy(src, dst)
    eq({ first, first_err }, { true, nil }, "a copy to a free target works")
    local second, second_err = fsio.copy(src, dst)
    eq(second, false, "a second copy to the same target fails")
    ok(fsio.is_copy_exists(second_err), "and says the target exists")
    eq(second_err, fsio.COPY_EXISTS)
    eq(H.read(dst), "source", "the target is left as it was")

    -- The token of create_exclusive changes (a lib.nvim of the future): copy must not follow it.
    local module = "lib.nvim.fs.create_exclusive"
    local real_lib, real_fsio = package.loaded[module], package.loaded["tasks_nvim.fsio"]
    package.loaded[module] = setmetatable({
      EXISTS = "lib-token",
      is_exists = function(err)
        return err == "lib-token"
      end,
    }, {
      __call = function(_, ...)
        return real_lib(...)
      end,
    })
    package.loaded["tasks_nvim.fsio"] = nil
    local fresh = require("tasks_nvim.fsio")
    local copied, copy_err = fresh.copy(src, dst)
    package.loaded[module], package.loaded["tasks_nvim.fsio"] = real_lib, real_fsio
    eq(copied, false)
    ok(fresh.is_copy_exists(copy_err), "copy answers its own token")
    ok(not fresh.is_exists(copy_err), "which is not the lib token")
  end
end
