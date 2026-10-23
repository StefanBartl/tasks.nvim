-- TESTS/tasks_attach_op_spec.lua -- `attach` of the write door: the clipboard image or the newest screenshot becomes an asset
-- of a task, the answer carries the asset and its link, a dry run writes nothing, and what is wrong is refused.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local ops = require("tasks_nvim.ops")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local PNG = "\137PNG\r\n\26\n" .. "image-bytes"

  ---@param stdout string
  ---@return table
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

  ---@param list table[]
  ---@param extra? table   # request fields (`dry_run`)
  ---@param attach? table  # the seams of `attach_source` (a fake clipboard, the folders)
  ---@return table entry
  local function one(list, extra, attach)
    -- `tasks_nvim.ops.run`, not `api.call`: the seams are options of the engine, a request can never carry them
    local doc, err = ops.run(
      vim.tbl_extend("force", { ops = list }, extra or {}),
      { root = root, today = F.TODAY, attach = attach }
    )
    eq(doc and doc.kind, "tasks.result", vim.inspect(err))
    return doc.results[1]
  end

  local function new_task(title)
    return assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title })))
  end

  -- ── the clipboard image becomes an asset ───────────────────────────────────
  local a = new_task("Attach by clipboard")
  local e = one({ { op = "attach", id = a.id, from = "clipboard", name = "shot.png" } }, nil, {
    clipboard = clipboard(PNG),
  })
  eq(e.ok, true, vim.inspect(e))
  eq(e.outcome, "changed")
  eq(e.id, a.id)
  eq(e.asset, "assets/shot.png", "the asset is named relative to the task folder")
  eq(e.link, "![shot.png](assets/shot.png)", "the answer carries the link")
  eq(e.changed_ids[1], a.id)
  ok(e.etag_after, "the version after is told")
  local task = assert(scan.find(a.id, { root = root }))
  eq(task.folder, true, "a plain task became a folder task")
  eq(fsio.is_file(fsio.dirname(task.path) .. "/assets/shot.png"), true, "the image is in assets/")
  eq(
    e.file,
    "lib.nvim/ROADMAP/tasks/" .. a.id:match("([^/]+)$") .. "/" .. a.id:match("([^/]+)$") .. ".md"
  )

  -- without a name the asset is called <slug>-<date>-<HHMM>.png and never replaces another
  local e2 = one({ { op = "attach", id = a.id, from = "clipboard" } }, nil, {
    clipboard = clipboard(PNG),
  })
  eq(e2.ok, true, vim.inspect(e2))
  local slug = a.id:match("([^/]+)$")
  ok(
    e2.asset:match(
      "^assets/" .. slug:gsub("%p", "%%%0") .. "%-%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%.png$"
    ),
    "the default name is <slug>-<date>-<HHMM>.png: " .. e2.asset
  )

  -- ── no image on the clipboard: a clear failure, nothing created ───────────
  local b = new_task("Attach nothing")
  local none = one({ { op = "attach", id = b.id, from = "clipboard" } }, nil, {
    clipboard = clipboard(""),
  })
  eq(none.ok, false)
  eq(none.outcome, "failed")
  eq(none.error.code, "invalid_argument")
  eq(assert(scan.find(b.id, { root = root })).folder, false, "the task stays a plain file")

  -- ── the newest screenshot of a folder ─────────────────────────────────────
  local shots = H.tmpdir() .. "/shots"
  vim.fn.mkdir(shots, "p")
  vim.fn.writefile({ PNG }, shots .. "/new.png", "b")
  local c = new_task("Attach latest")
  local latest = one({ { op = "attach", id = c.id, from = "latest", name = "latest.png" } }, nil, {
    dirs = { shots },
  })
  eq(latest.ok, true, vim.inspect(latest))
  eq(latest.asset, "assets/latest.png")

  -- too old: told, not guessed
  local d = new_task("Attach too old")
  local old = one({ { op = "attach", id = d.id, from = "latest" } }, nil, {
    dirs = { shots },
    now = os.time() + 24 * 3600,
  })
  eq(old.ok, false, "a screenshot older than the limit is not taken")
  eq(assert(scan.find(d.id, { root = root })).folder, false)

  -- ── a dry run writes nothing ──────────────────────────────────────────────
  local f = new_task("Attach dry")
  local dry = one(
    { { op = "attach", id = f.id, from = "clipboard", name = "dry.png" } },
    { dry_run = true },
    { clipboard = clipboard(PNG) }
  )
  eq(dry.ok, true, vim.inspect(dry))
  eq(dry.outcome, "would_change")
  eq(#dry.changed_ids, 0)
  eq(
    assert(scan.find(f.id, { root = root })).folder,
    false,
    "a dry run leaves the task a plain file"
  )

  -- ── what is wrong is refused ──────────────────────────────────────────────
  ---@param op table
  ---@param code string
  ---@param what string
  local function refused(op, code, what)
    -- through the front door (`api.call`), which has no seam to a clipboard: a request that got further would fail
    -- on the machine's own one
    local text =
      api.call("ops", vim.json.encode({ ops = { op } }), { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    -- a request that is wrong in shape is a `tasks.error` (`code` on top); an operation that fails has it in its entry
    local err = doc.kind == "tasks.error" and doc or (doc.results[1] and doc.results[1].error)
    ok(err, what .. ": " .. text)
    eq(err.code, code, what .. ": " .. text)
  end
  refused({ op = "attach", from = "clipboard" }, "invalid_argument", "needs an id")
  refused({ op = "attach", id = a.id }, "invalid_argument", "needs a source")
  refused({ op = "attach", id = a.id, from = "file" }, "invalid_argument", "unknown source")
  refused(
    { op = "attach", id = a.id, from = "latest", dir = "/etc" },
    "invalid_argument",
    "no folder from outside"
  )
  refused(
    { op = "attach", id = "lib.nvim/never-was", from = "clipboard" },
    "not_found",
    "unknown task"
  )

  -- ── the folders a caller names (`attach_dirs`, the hub from its settings) ─
  ---@param request table
  ---@return table doc
  local function front(request)
    local text = api.call("ops", vim.json.encode(request), { root = root, today = F.TODAY })
    return vim.json.decode(text)
  end
  vim.fn.writefile({ PNG }, shots .. "/named.png", "b")
  local g = new_task("Attach from a named folder")
  local named = front({
    attach_dirs = { shots },
    ops = { { op = "attach", id = g.id, from = "latest", name = "named.png" } },
  })
  eq(named.results and named.results[1].ok, true, vim.inspect(named))
  eq(named.results[1].asset, "assets/named.png", "the newest image of the folder that was named")

  -- named, and none: only the clipboard, never the folders of the system
  local h = new_task("Attach with no folder")
  local nofolder =
    front({ attach_dirs = {}, ops = { { op = "attach", id = h.id, from = "latest" } } })
  local nerr = nofolder.results and nofolder.results[1].error
  eq(nerr and nerr.code, "invalid_argument", vim.inspect(nofolder))
  ok(nerr.message:find("no screenshot folders", 1, true), nerr.message)
  eq(assert(scan.find(h.id, { root = root })).folder, false, "nothing was attached")

  -- a folder that is not absolute, too many folders, not a list of words: the request is refused as a whole
  for _, bad in ipairs({ { "shots" }, vim.fn["repeat"]({ shots }, 9), { 5 } }) do
    local doc =
      front({ attach_dirs = bad, ops = { { op = "attach", id = h.id, from = "latest" } } })
    eq(doc.kind, "tasks.error", vim.inspect(doc))
    eq(doc.code, "invalid_argument", vim.inspect(doc))
  end
end
