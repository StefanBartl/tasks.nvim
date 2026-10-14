-- TESTS/tasks_open_match_spec.lua -- `:Tasks open <part of a name>`: the matching of tasks_nvim.match (engine) and the
-- handler cmd.task_open (one hit opens, several are offered, none is told), plus the completion of slugs.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has

  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local mutate = require("tasks_nvim.mutate")
  local match = require("tasks_nvim.match")
  local cmd = require("tasks_nvim.ui.cmd")

  local root = F.vault(H)
  vault.set_root(root)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  ---@param area string
  ---@param title string
  ---@param slug? string
  local function task(area, title, slug)
    return assert(mutate.new(area, vim.tbl_extend("force", o, { title = title, slug = slug })))
  end
  task("lib.nvim", "Alpha Widget")
  task("cascade.nvim", "Alpha Widget")
  task("lib.nvim", "Alpha Gadget")
  task("lib.nvim", "Gamma")
  task("lib.nvim", "Gamma Ray")
  task("lib.nvim", "Über uns", "ueber-uns")
  task("lib.nvim", "Quokka migration", "q1")
  local fin = task("lib.nvim", "Beta thing")
  assert(mutate.done(fin.id, o))

  ---@param matches Tasks.Match[]
  ---@return string[]
  local function ids(matches)
    local out = {}
    for _, m in ipairs(matches) do
      out[#out + 1] = m.id
    end
    return out
  end

  -- ── the engine ──────────────────────────────────────────────────────────────
  local both = match.match("alpha-widget")
  eq(
    ids(both),
    { "cascade.nvim/alpha-widget", "lib.nvim/alpha-widget" },
    "the same slug in two areas is two hits"
  )
  eq(match.unique(both), nil, "and none of them is the one")
  eq(
    ids(match.match("lib.nvim/alpha-w")),
    { "lib.nvim/alpha-widget" },
    "an area narrows the search"
  )
  eq(
    match.match("LIB.NVIM/ALPHA-W")[1].id,
    "lib.nvim/alpha-widget",
    "case does not matter, for the area either"
  )
  eq(match.match("alpha-g")[1].rank, 2, "the start of a slug is rank 2")
  eq(match.match("adget")[1].id, "lib.nvim/alpha-gadget", "a part inside a slug is found")
  eq(match.match("adget")[1].rank, 3)
  local title_hit = match.match("quokka")
  eq(ids(title_hit), { "lib.nvim/q1" }, "the title of an open task is searched after the slug")
  eq(title_hit[1].rank, 4)
  local finished = match.match("thing")
  eq(ids(finished), { "lib.nvim/beta-thing" }, "a finished task is found by its slug")
  eq(finished[1].done, true)
  local gamma = match.match("gamma")
  eq(#gamma, 2)
  eq(
    match.unique(gamma).id,
    "lib.nvim/gamma",
    "the slug that is exactly the text wins over longer ones"
  )
  local none, near = match.match("alphx")
  eq(none, {})
  eq(
    near,
    { "cascade.nvim/alpha-widget", "lib.nvim/alpha-gadget", "lib.nvim/alpha-widget" },
    "the closest slugs are named"
  )
  eq(#match.match("lib.nvim/"), 7, "an area and nothing else is all its tasks (open and finished)")
  eq(match.match(""), {})
  -- the case of a title that is not ASCII: vim's tolower folds "Ü", string.lower does not
  eq(
    ids(match.match("über")),
    { "lib.nvim/ueber-uns" },
    "an umlaut in lower case finds a title that starts with it in capitals"
  )
  eq(ids(match.match("ÜBER")), { "lib.nvim/ueber-uns" }, "and the other way round")

  -- ── the handler ─────────────────────────────────────────────────────────────
  local orig_notify = vim.notify
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local offered
  local pick
  cmd.select_task = function(items, opts, cb)
    offered = { items = items, prompt = opts.prompt, shown = opts.format_item(items[1]) }
    cb(items[pick])
  end
  ---@param query string
  local function open(query)
    notes, offered = {}, nil
    cmd.task_open({ args = { id = query }, flags = {}, kv = {}, rest = {} })
  end
  ---@return string
  local function current()
    return vim.fs.basename(vim.api.nvim_buf_get_name(0))
  end

  open("lib.nvim/alpha-gadget")
  eq(current(), "alpha-gadget.md", "a full id opens as before")
  open("gadget")
  eq(current(), "alpha-gadget.md", "one hit opens without a question")
  eq(offered, nil)
  open("thing")
  ok(current():find("beta%-thing"), "a finished task opens from the Backlog")
  open("gamma")
  eq(current(), "gamma.md", "the exact slug opens although a longer one matches too")

  pick = 2
  open("alpha-widget")
  ok(offered ~= nil, "several hits are offered")
  eq(#offered.items, 2)
  has(offered.shown, "cascade.nvim/alpha-widget", "with their ids")
  has(offered.prompt, "2 tasks match", "and the count")
  eq(
    vim.api.nvim_buf_get_name(0):gsub("\\", "/"):match("([^/]+/ROADMAP)"),
    "lib.nvim/ROADMAP",
    "the chosen one is opened"
  )

  pick = nil
  local before = vim.api.nvim_buf_get_name(0)
  open("alpha-widget")
  eq(vim.api.nvim_buf_get_name(0), before, "a cancelled choice opens nothing")

  open("alphx")
  eq(offered, nil)
  has(notes[1].msg, "no task matches 'alphx'", "no hit is told")
  has(notes[1].msg, "did you mean", "with the closest slugs")
  eq(notes[1].level, vim.log.levels.ERROR)

  -- a missing vault is what is told, not "no task matches"
  vault.set_root(H.tmpdir() .. "/no-such-vault")
  open("zebra")
  ok(
    not notes[1].msg:find("no task matches", 1, true),
    "a missing vault is no missing task: " .. notes[1].msg
  )
  has(notes[1].msg, "vault", "the vault is named")
  vault.set_root(root)

  -- ── completion ──────────────────────────────────────────────────────────────
  vim.notify = orig_notify
  cmd.select_task = nil
  ok(require("tasks_nvim.bindings.usrcmds").register(), ":Tasks is registered")
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end
  eq(
    complete("Tasks open gam"),
    { "gamma", "gamma-ray" },
    "a slug is completed without its area where it is unique"
  )
  eq(complete("Tasks open alpha-w"), {}, "but not where two areas have it")
  has(
    table.concat(complete("Tasks open lib.nvim/gam"), " "),
    "lib.nvim/gamma",
    "the full ids still complete"
  )
end
