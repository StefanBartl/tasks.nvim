-- TESTS/tasks/tasks_mutate_safety_spec.lua -- hardening of the write paths: a failure in the middle of
-- `attach` / `done` leaves no half state (and says so when it cannot undo it), names that Windows treats
-- as devices are never created, and long whitespace runs do not make the input trimming quadratic.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local TODAY = F.TODAY
  local cpdir = H.tmpdir() .. "/checkpoints"

  local function setup()
    local root = F.vault(H)
    return root, { root = root, today = TODAY, checkpoint_dir = cpdir }
  end

  ---A small file to attach.
  ---@param name string
  ---@param content? string
  ---@return string path
  local function asset_file(name, content)
    local path = H.tmpdir() .. "/src/" .. name
    H.write(path, content or "x")
    return path
  end

  ---Run `body` with `tbl[key]` replaced; the original comes back even when `body` raises, so a
  ---failing assertion cannot leak a stub into the specs that follow.
  ---@param tbl table
  ---@param key string
  ---@param stub function
  ---@param body fun()
  local function with_stub(tbl, key, stub, body)
    local orig = tbl[key]
    tbl[key] = stub
    local okc, err = pcall(body)
    tbl[key] = orig
    if not okc then
      error(err, 0)
    end
  end

  -- ── names Windows treats as devices ─────────────────────────────────────
  for _, name in ipairs({
    "nul",
    "NUL",
    "con",
    "Aux",
    "prn",
    "com1",
    "COM9",
    "lpt3",
    "nul.txt",
    "con.tar.gz",
  }) do
    ok(vault.is_reserved_name(name), name .. " is a reserved device name")
  end
  for _, name in ipairs({ "nullable", "console.log", "com10", "com0", "lpt", "a-nul", "", "x.nul" }) do
    ok(not vault.is_reserved_name(name), name .. " is an ordinary name")
  end
  ok(not vault.is_reserved_name(nil))

  -- a slug generated from a title never ends up as a device name
  eq(mutate.slugify("Nul"), "nul-task")
  eq(mutate.slugify("COM1"), "com1-task")
  eq(mutate.slugify("nullable"), "nullable")

  local root, o = setup()
  local _, rserr = mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "T", slug = "nul" }))
  has(rserr, "reserved")
  local folder_nul =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Nul", folder = true })))
  eq(folder_nul.slug, "nul-task", "a folder task can be called nul only by another name")
  ok(H.exists(folder_nul.path))

  -- an area name keeps no trailing dot (Windows would resolve `lib.nvim.` to `lib.nvim`)
  ok(not vault.valid_area("lib.nvim."))
  ok(not vault.has_area(root, "lib.nvim."))

  -- ... and is spelled exactly like its folder: `LIB.NVIM` reaches the same folder on Windows, but
  -- would become a second id for the same tasks and make the generated index read as stale
  ok(vault.has_area(root, "lib.nvim"))
  ok(not vault.has_area(root, "LIB.NVIM"), "an area in another case is not an area")
  local _, caerr = mutate.new("LIB.NVIM", vim.tbl_extend("force", o, { title = "Alias" }))
  has(caerr, "unknown area")
  local aliased = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Real" })))
  ok(scan.find(aliased.id, { root = root }), "the real spelling finds the task")
  local alias_id = "LIB.NVIM/" .. aliased.slug
  ok(not scan.find(alias_id, { root = root }), "the alias does not")
  ok(mutate.set(alias_id, { prio = "1" }, o) == nil, "set refuses it")
  ok(mutate.done(alias_id, o) == nil, "done refuses it")
  ok(mutate.attach(alias_id, asset_file("c.png"), o) == nil, "attach refuses it")
  ok(mutate.folderize(alias_id, o) == nil, "folderize refuses it")

  -- ── attach: names ───────────────────────────────────────────────────────
  local holder = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Holder" })))
  local payload = asset_file("payload.txt", "DATA")
  for _, name in ipairs({ "nul", "CON", "com1", "nul.txt", "x." }) do
    local res, err = mutate.attach(holder.id, payload, vim.tbl_extend("force", o, { name = name }))
    ok(res == nil and err, "attach --name=" .. name .. " is refused")
  end
  ok(H.exists(holder.path), "a refused name leaves the plain task alone")
  ok(
    not H.exists(root .. "/lib.nvim/ROADMAP/tasks/holder"),
    "and does not turn it into a folder task"
  )
  local fine =
    assert(mutate.attach(holder.id, payload, vim.tbl_extend("force", o, { name = "console.log" })))
  eq(H.read(fine.asset), "DATA")

  -- ── attach: a failing copy leaves the task as it was ────────────────────
  root, o = setup()
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain one" })))
  local plain_text = H.read(plain.path)
  local index_path = root .. "/lib.nvim/ROADMAP/TASKS.md"
  local index_before = H.read(index_path)
  with_stub(fsio, "copy", function()
    return false, "stubbed copy failure"
  end, function()
    local res, err = mutate.attach(plain.id, asset_file("a.png"), o)
    ok(res == nil and err, "the failing copy fails attach")
    has(err, "stubbed copy failure")
    lacks(err, "turned into a folder task", "the folder conversion was undone, nothing to mention")
  end)
  ok(H.exists(plain.path), "the task is a plain file again")
  eq(H.read(plain.path), plain_text, "byte-exact")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/plain-one"), "no empty folder is left")
  eq(H.read(index_path), index_before, "the index still points at the plain file")
  ok(not scan.find(plain.id, { root = root }).folder)

  -- when the conversion cannot be undone either, say so and keep the index true to the disk
  local plain2 = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain two" })))
  local real_rename = fsio.rename
  local renames = 0
  with_stub(fsio, "copy", function()
    return false, "stubbed copy failure"
  end, function()
    with_stub(fsio, "rename", function(from, to)
      renames = renames + 1
      if renames == 1 then
        return real_rename(from, to) -- the conversion itself
      end
      return false, "stubbed rename failure" -- the undo
    end, function()
      local res, err = mutate.attach(plain2.id, asset_file("b.png"), o)
      ok(res == nil and err)
      has(err, "turned into a folder task")
      has(err, "stubbed rename failure")
    end)
  end)
  ok(scan.find(plain2.id, { root = root }).folder, "the task really is a folder task now")
  has(H.read(index_path), "plain-two/plain-two.md", "the index was regenerated for what is on disk")

  -- ── done (folder task): the rollback reports what it could not undo ─────
  root, o = setup()
  local keep =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Keep me", folder = true })))
  assert(mutate.attach(keep.id, asset_file("k.txt", "keep"), o))
  local before = H.read(keep.path)
  local src_dir = root .. "/lib.nvim/ROADMAP/tasks/keep-me"
  local target_dir = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_keep-me"
  local readme = root .. "/lib.nvim/Backlog/README.md"
  local readme_before = H.read(readme)
  real_rename = fsio.rename
  local real_write = fsio.write_atomic
  with_stub(fsio, "write_atomic", function(path, content)
    if path:match("2026%-10%-03_keep%-me%.md$") then
      return false, "stubbed write failure"
    end
    return real_write(path, content)
  end, function()
    with_stub(fsio, "rename", function(from, to)
      if from == src_dir then
        return real_rename(from, to)
      end
      return false, "stubbed rename-back failure"
    end, function()
      local res, err = mutate.done(keep.id, o)
      ok(res == nil and err, "done fails")
      has(err, "stubbed write failure")
      has(err, "rollback incomplete", "a folder that could not be moved back is reported")
      has(err, target_dir, "and named")
    end)
  end)
  eq(
    H.read(target_dir .. "/keep-me.md"),
    before,
    "the stranded folder holds the original task text"
  )
  ok(H.exists(target_dir .. "/assets/k.txt"), "and its assets")
  eq(H.read(readme), readme_before, "the README row is rolled back regardless")

  -- the original task file is restored BEFORE the finished copy is dropped: when it cannot be
  -- written back, the finished copy is the only holder of the text and must stay
  root, o = setup()
  -- a second open task, so the index is written (not removed) when "Keep me" is done
  assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Stays open" })))
  keep =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Keep me", folder = true })))
  src_dir = root .. "/lib.nvim/ROADMAP/tasks/keep-me"
  target_dir = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_keep-me"
  real_write = fsio.write_atomic
  with_stub(fsio, "write_atomic", function(path, content)
    -- the index fails (a later step of done) and so does writing the old file back
    if path:match("TASKS%.md$") or path:match("/keep%-me%.md$") then
      return false, "stubbed write failure"
    end
    return real_write(path, content)
  end, function()
    local res, err = mutate.done(keep.id, o)
    ok(res == nil and err)
    has(err, "rollback incomplete")
  end)
  ok(H.exists(target_dir .. "/2026-10-03_keep-me.md"), "the finished copy survives")
  has(H.read(target_dir .. "/2026-10-03_keep-me.md"), "Keep me", "with the task text")
  ok(not H.exists(src_dir), "the folder was not moved back without its task file")

  -- the same for a plain task file: when the original cannot be put back, the finished copy stays
  root, o = setup()
  assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Stays open" })))
  local plain_keep =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain keep" })))
  local plain_target = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_plain-keep.md"
  real_write = fsio.write_atomic
  local real_create_p = fsio.create_exclusive
  with_stub(fsio, "write_atomic", function(path, content)
    if path:match("ROADMAP/TASKS%.md$") then
      return false, "stubbed index failure"
    end
    return real_write(path, content)
  end, function()
    with_stub(fsio, "create_exclusive", function(path, content)
      if path == plain_keep.path then
        return false, "stubbed create failure"
      end
      return real_create_p(path, content)
    end, function()
      local res, err = mutate.done(plain_keep.id, o)
      ok(res == nil and err)
      has(err, "stubbed index failure")
      has(err, "rollback incomplete")
      has(err, plain_keep.path, "the original that could not be put back is named")
    end)
  end)
  ok(H.exists(plain_target), "the finished copy is the only holder of the text and stays")
  has(H.read(plain_target), "Plain keep")
  ok(not H.exists(plain_keep.path))

  -- ── done: a task file written while it is being finished is not dropped ─
  root, o = setup()
  readme = root .. "/lib.nvim/Backlog/README.md"
  readme_before = H.read(readme)
  local busy = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Busy" })))
  local busy_target = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_busy.md"
  local edited
  local real_create = fsio.create_exclusive
  with_stub(fsio, "create_exclusive", function(path, content)
    local created, cerr = real_create(path, content)
    -- a concurrent writer (the editor, another run) saves the task right after the copy was made
    edited = H.read(busy.path) .. "\nAdded by someone else.\n"
    H.write(busy.path, edited)
    return created, cerr
  end, function()
    local res, err = mutate.done(busy.id, o)
    ok(res == nil and err, "done refuses to drop a file that changed under it")
    has(err, "changed while it was being finished")
  end)
  eq(H.read(busy.path), edited, "the concurrent edit is still there")
  ok(not H.exists(busy_target), "no finished copy is left behind")
  eq(H.read(readme), readme_before, "the README is untouched")
  assert(mutate.done(busy.id, o))
  has(H.read(busy_target), "Added by someone else", "the next run finishes the edited text")

  local fbusy = assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Folder busy", folder = true }))
  )
  local fbusy_dir = root .. "/lib.nvim/Backlog/TASKS/2026-10-03_folder-busy"
  local real_is_dir = fsio.is_dir
  local fired = false
  with_stub(fsio, "is_dir", function(path)
    if not fired and path == fbusy_dir then
      fired = true
      edited = H.read(fbusy.path) .. "\nLate edit.\n"
      H.write(fbusy.path, edited)
    end
    return real_is_dir(path)
  end, function()
    local res, err = mutate.done(fbusy.id, o)
    ok(res == nil and err)
    has(err, "changed while it was being finished")
  end)
  ok(fired)
  eq(H.read(fbusy.path), edited, "the folder task keeps the late edit")
  ok(not H.exists(fbusy_dir), "nothing was moved")

  -- ── done: a slug that exists as a file and as a folder says so ──────────
  root, o = setup()
  F.task(H, root, "lib.nvim", "twice", F.meta("Twice", "open"))
  F.task(H, root, "lib.nvim", "twice/twice", F.meta("Twice", "open"))
  local dres, derr = mutate.done("lib.nvim/twice", o)
  ok(dres == nil and derr)
  has(derr, "file and as folder", "the conflict is named, not reported as a missing task")
  _, derr = mutate.done("lib.nvim/never-there", o)
  has(derr, "no such open task")

  -- ── long whitespace runs do not make the input parsing quadratic ────────
  _, o = setup()
  local wide = "a" .. string.rep(" ", 64000) .. "b"
  local t_wide = vim.uv.hrtime()
  local form = require("tasks_nvim.form")
  local parsed = form.parse({ "Title: " .. wide, "- [x] " .. wide })
  eq(parsed.title, wide, "the form keeps the inner spaces")
  assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = wide, index = false })))
  local wide_s = (vim.uv.hrtime() - t_wide) / 1e9
  ok(wide_s < 1.5, ("trimming 64 000 inner spaces took %.1f s (quadratic pattern?)"):format(wide_s))

  -- ── failure injection: every fsio call of done / attach / folderize, failed in turn ─────────
  -- The k-th call of each primitive fails. A failed operation must leave the vault byte-exact as it
  -- was, or say "rollback incomplete" and lose no task text.
  ---@param dir string
  ---@return table<string, string|true> files  relative path -> content (`true` for a folder)
  local function snapshot(dir)
    local out = {}
    local function walk(d)
      local handle = vim.uv.fs_scandir(d)
      while handle do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        local p = d .. "/" .. name
        if kind == "directory" then
          out[p:sub(#dir + 2) .. "/"] = true
          walk(p)
        else
          out[p:sub(#dir + 2)] = H.read(p)
        end
      end
    end
    walk(dir)
    return out
  end

  ---A vault with one other open task and the "Subject" task, a plain file or a folder with an asset.
  ---@param folder boolean
  ---@return string root
  ---@return table opts
  ---@return table task
  local function inject_vault(folder)
    local r, opts = setup()
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", opts, { title = "Other open" })))
    local created = assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", opts, { title = "Subject", folder = folder }))
    )
    if folder then
      assert(mutate.attach(created.id, asset_file("seed.bin", "seed"), opts))
    end
    return r, opts, created
  end

  ---@param op string  "done" | "attach" | "folderize"
  local function run_op(op, id, opts, src)
    if op == "done" then
      return mutate.done(id, opts)
    elseif op == "attach" then
      return mutate.attach(id, src, opts)
    end
    return mutate.folderize(id, opts)
  end

  local PRIMS = { "create_exclusive", "remove", "rename", "write_atomic", "mkdirp", "copy" }
  local injected = 0
  for _, op in ipairs({ "done", "attach", "folderize" }) do
    for _, folder in ipairs({ false, true }) do
      -- a dry run counts how often each primitive is called
      local counts, origs = {}, {}
      local _, dry_opts, dry_task = inject_vault(folder)
      for _, prim in ipairs(PRIMS) do
        origs[prim], counts[prim] = fsio[prim], 0
        fsio[prim] = function(...)
          counts[prim] = counts[prim] + 1
          return origs[prim](...)
        end
      end
      local dry_ok, dry_err = pcall(run_op, op, dry_task.id, dry_opts, asset_file("dry.bin", "dry"))
      for _, prim in ipairs(PRIMS) do
        fsio[prim] = origs[prim]
      end
      if not dry_ok then
        error(dry_err, 0)
      end

      for _, prim in ipairs(PRIMS) do
        for k = 1, counts[prim] do
          local r, opts, subject = inject_vault(folder)
          local src = asset_file("late.bin", "late")
          local before_state = snapshot(r)
          local label = ("%s, %s#%d, %s task"):format(op, prim, k, folder and "folder" or "plain")
          local calls, orig, res, err = 0, fsio[prim], nil, nil
          with_stub(fsio, prim, function(...)
            calls = calls + 1
            if calls == k then
              return false, "injected failure"
            end
            return orig(...)
          end, function()
            res, err = run_op(op, subject.id, opts, src)
          end)
          injected = injected + 1
          if res == nil then
            local after_state = snapshot(r)
            if tostring(err):find("rollback incomplete", 1, true) then
              local present = {}
              for _, content in pairs(after_state) do
                present[content] = true
              end
              for path, content in pairs(before_state) do
                local generated = path:match("TASKS%.md$") or path:match("README%.md$")
                if content ~= true and not generated then
                  ok(
                    present[content],
                    label .. ": the content of " .. path .. " is still somewhere"
                  )
                end
              end
            else
              eq(after_state, before_state, label .. ": a failed operation changes nothing")
            end
          end
        end
      end
    end
  end
  ok(injected >= 15, ("the injection loop ran (%d failures injected)"):format(injected))
end
