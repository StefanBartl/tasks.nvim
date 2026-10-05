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
end
