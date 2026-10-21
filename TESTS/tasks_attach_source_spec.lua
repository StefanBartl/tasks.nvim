-- TESTS/tasks_attach_source_spec.lua -- attach from the clipboard image or the newest screenshot.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local source = require("tasks_nvim.attach_source")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/checkpoints" }
  local NOW = os.time({ year = 2026, month = 10, day = 19, hour = 14, min = 32, sec = 10 })
  local PNG = "\137PNG\r\n\26\n" .. "image-bytes"

  local function new_task(title)
    return assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title })))
  end

  ---A clipboard that holds `stdout` (linux/wl-paste) or nothing.
  ---@param stdout string
  ---@return Lib.ClipboardImage.Opts
  local function clipboard(stdout)
    return {
      platform = "linux",
      has = function(exe)
        return exe == "wl-paste"
      end,
      system = function()
        return { code = stdout ~= "" and 0 or 1, stdout = stdout }
      end,
    }
  end

  local function attach(id, mode, extra)
    return source.attach(
      id,
      mode,
      vim.tbl_extend("force", { root = root, today = F.TODAY, now = NOW }, extra or {})
    )
  end

  -- ---- default name -----------------------------------------------------------
  eq(
    source.default_name("lib.nvim/my-task", "png", NOW),
    "my-task-2026-10-19-1432.png",
    "<slug>-<date>-<HHMM>.<ext>"
  )

  -- ---- clipboard ---------------------------------------------------------------
  local task = new_task("Clip shot")
  local res, err = attach(task.id, "clipboard", { clipboard = clipboard(PNG) })
  ok(res, "the clipboard image is attached: " .. tostring(err))
  eq(res.rel, "assets/clip-shot-2026-10-19-1432.png", "named from slug and time")
  eq(
    res.link,
    "![clip-shot-2026-10-19-1432.png](assets/clip-shot-2026-10-19-1432.png)",
    "an image link"
  )
  ok(res.folderized, "a plain task became a folder task")
  eq(H.read(res.asset), PNG, "the bytes are stored as they were")
  eq(res.source, "clipboard", "the source is named")

  local again = attach(task.id, "clipboard", { clipboard = clipboard(PNG) })
  eq(
    again.rel,
    "assets/clip-shot-2026-10-19-1432-2.png",
    "the same minute again: a counter, nothing replaced"
  )
  local third = attach(task.id, "clipboard", { clipboard = clipboard(PNG) })
  eq(third.rel, "assets/clip-shot-2026-10-19-1432-3.png", "and again")

  local named = attach(task.id, "clipboard", { clipboard = clipboard(PNG), name = "mine.png" })
  eq(named.rel, "assets/mine.png", "a given name is used as it is")
  local dup, dup_err =
    attach(task.id, "clipboard", { clipboard = clipboard(PNG), name = "mine.png" })
  ok(
    dup == nil and dup_err:find("asset exists", 1, true),
    "a given name that is taken is an error, not a counter"
  )

  -- nothing on the clipboard: a clear message, and the task stays as it was
  local plain = new_task("Plain stays")
  local none, none_err = attach(plain.id, "clipboard", { clipboard = clipboard("") })
  ok(
    none == nil and none_err:find("no image in the clipboard", 1, true),
    "no image: " .. tostring(none_err)
  )
  ok(
    not scan.find(plain.id, { root = root }).folder,
    "and the task was not turned into a folder task"
  )

  -- ---- latest --------------------------------------------------------------------
  local shots = H.tmpdir() .. "/screenshots"
  local function shot(name, age)
    local p = shots .. "/" .. name
    H.write(p, PNG)
    vim.uv.fs_utime(p, NOW - age, NOW - age)
    return p
  end
  shot("old.png", 5000)
  shot("Fresh.JPG", 20)
  local lt = new_task("Latest shot")
  local lres, lerr = attach(lt.id, "latest", { dir = shots, max_age_s = 300 })
  ok(lres, "the newest recent screenshot is attached: " .. tostring(lerr))
  eq(lres.rel, "assets/latest-shot-2026-10-19-1432.jpg", "the extension of the source, lower case")
  has(lres.source, "Fresh.JPG")

  local stale_dir = H.tmpdir() .. "/stale-shots"
  H.write(stale_dir .. "/x.png", PNG)
  vim.uv.fs_utime(stale_dir .. "/x.png", NOW - 4000, NOW - 4000)
  local st = new_task("Stale shot")
  local sres, serr, too_old = attach(st.id, "latest", { dir = stale_dir, max_age_s = 300 })
  ok(
    sres == nil and serr:find("old", 1, true),
    "a file older than the limit is not guessed: " .. tostring(serr)
  )
  ok(too_old and too_old.path:find("x.png", 1, true), "it is handed back so the caller can ask")
  ok(not scan.find(st.id, { root = root }).folder, "and the task stays a plain task")

  local missing, merr = attach(st.id, "latest", { dir = H.tmpdir() .. "/no-such-folder" })
  ok(
    missing == nil and merr:find("no matching file", 1, true),
    "an empty folder: " .. tostring(merr)
  )
  local bad, bad_err = attach(st.id, "nonsense")
  ok(bad == nil and bad_err:find("clipboard' or 'latest", 1, true), "an unknown source is refused")

  -- ---- folders ---------------------------------------------------------------------
  eq(source.screenshot_dirs({ dir = "/a" }), { "/a" }, "dir wins")
  eq(source.screenshot_dirs({ dirs = { "/b", "/c" } }), { "/b", "/c" }, "then dirs")
  eq(
    source.suggested_dirs("windows", "C:/Users/x")[1],
    "C:/Users/x/Pictures/Screenshots",
    "windows suggestion"
  )
  eq(source.suggested_dirs("macos", "/Users/x")[1], "/Users/x/Desktop", "macOS suggestion")
  eq(
    source.suggested_dirs("linux", "/home/x")[1],
    "/home/x/Pictures/Screenshots",
    "linux suggestion"
  )

  -- ---- check: an attached image nobody links -----------------------------------------
  assert(index.write_area("lib.nvim", { root = root }))
  local checked = assert(check.run({ root = root }))
  local unused = {}
  for _, f in ipairs(checked.findings) do
    if f.code == "asset-unused" then
      unused[#unused + 1] = f.message
    end
  end
  ok(#unused >= 1, "attached but unlinked images are reported")
  ok(checked.ok, "only warnings")

  -- ---- CLI -----------------------------------------------------------------------------
  local function run(argv)
    local out, errs = {}, {}
    local code = cli.run(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        errs[#errs + 1] = s
      end,
    })
    return code, table.concat(out), table.concat(errs)
  end
  local ct = new_task("Cli shot")
  local base = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function with(...)
    local argv = { ... }
    vim.list_extend(argv, base)
    return argv
  end

  local code, _, e1 = run(with("attach", ct.id, "--clipboard", "--latest"))
  eq(code, 2, "--clipboard and --latest exclude each other")
  has(e1, "exclude each other")
  code = run(with("attach", ct.id))
  eq(code, 2, "a file or a source is needed")
  code = run(with("attach", ct.id, "some.png", "--clipboard"))
  eq(code, 2, "a file and a source exclude each other")

  local fresh_dir = H.tmpdir() .. "/cli-shots"
  H.write(fresh_dir .. "/now.png", PNG)
  local c2, out2 = run(with("attach", ct.id, "--latest=" .. fresh_dir))
  eq(c2, 0, "--latest=<folder> attaches the newest recent image")
  has(out2, "attached\t" .. ct.id .. "\tassets/cli-shot-")

  local old_dir = H.tmpdir() .. "/cli-old"
  H.write(old_dir .. "/o.png", PNG)
  local month_ago = os.time() - 40 * 86400
  vim.uv.fs_utime(old_dir .. "/o.png", month_ago, month_ago)
  local c3, _, e3 = run(with("attach", ct.id, "--latest=" .. old_dir))
  eq(c3, 1, "an old screenshot is refused")
  has(e3, "attach.max_age_s")
end
