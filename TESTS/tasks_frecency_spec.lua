-- TESTS/tasks/tasks_frecency_spec.lua -- the frecency score behind `--sort=frecency` (lua/tasks/frecency.lua):
-- the arithmetic with an injected clock, pruning and the entry cap, the file format, persistence (including a
-- corrupt and an unreadable file) and how `model.sort` uses the scores. Every file lives in a temp directory.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has

  local fr = require("tasks_nvim.frecency")
  local model = require("tasks_nvim.model")

  local DAY = 86400
  local T0 = 1800000000 -- an arbitrary "now"

  ---@param actual number
  ---@param expected number
  ---@param msg string
  local function near(actual, expected, msg)
    ok(
      math.abs(actual - expected) < 1e-6,
      ("%s: expected ~%s, got %s"):format(msg, expected, actual)
    )
  end

  -- ── decay: the half-life ────────────────────────────────────────────────
  eq(fr.HALF_LIFE_DAYS, 14)
  near(fr.decayed({ score = 1, last = T0 }, T0), 1, "no time passed")
  near(fr.decayed({ score = 1, last = T0 }, T0 + 14 * DAY), 0.5, "one half-life")
  near(fr.decayed({ score = 1, last = T0 }, T0 + 28 * DAY), 0.25, "two half-lives")
  near(fr.decayed({ score = 4, last = T0 }, T0 + 14 * DAY), 2, "the score scales")
  near(
    fr.decayed({ score = 1, last = T0 }, T0 - 5 * DAY),
    1,
    "a clock that went backwards counts as now"
  )
  near(
    fr.decayed({ score = 1, last = T0 }, T0 + 7 * DAY, { half_life_days = 7 }),
    0.5,
    "the half-life is an option"
  )
  eq(fr.decayed(nil, T0), 0, "no entry, no score")
  eq(fr.decayed({ last = T0 }, T0), 0, "a malformed entry scores nothing")

  -- ── bump: a visit adds 1 to the decayed score ───────────────────────────
  local e = {}
  local first = fr.bump(e, "lib.nvim/alpha", T0)
  near(first.score, 1, "the first visit")
  eq(first.last, T0)
  fr.bump(e, "lib.nvim/alpha", T0 + 14 * DAY)
  near(e["lib.nvim/alpha"].score, 1.5, "0.5 left of the first visit + 1")
  eq(e["lib.nvim/alpha"].last, T0 + 14 * DAY, "the stamp moves to the latest visit")
  eq(fr.bump(e, "", T0), nil, "an empty id is not a visit")
  eq(fr.bump(e, 42, T0), nil, "a non-string id is not a visit")
  eq(vim.tbl_count(e), 1, "nothing else was added")
  fr.bump(e, "lib.nvim/alpha", T0 + 14 * DAY, nil, 2)
  near(e["lib.nvim/alpha"].score, 3.5, "a weight is added instead of 1")

  -- frequency AND recency decide, not either alone
  local rank = {}
  for _ = 1, 3 do
    fr.bump(rank, "fresh", T0)
  end
  for _ = 1, 5 do
    fr.bump(rank, "old", T0 - 30 * DAY)
  end
  local s = fr.scores(rank, T0)
  ok(s.fresh > s.old, "three visits today beat five visits a month ago")
  fr.bump(rank, "old", T0)
  fr.bump(rank, "old", T0)
  fr.bump(rank, "old", T0)
  ok(fr.scores(rank, T0).old > s.old, "a task opened again climbs back")

  -- ── scores / prune ──────────────────────────────────────────────────────
  local fade = {}
  fr.bump(fade, "gone", T0)
  fr.bump(fade, "kept", T0 + 70 * DAY)
  local now = T0 + 70 * DAY
  ok(fr.decayed(fade.gone, now) < fr.MIN_SCORE, "70 days of silence fades a single visit")
  eq(vim.tbl_keys(fr.scores(fade, now)), { "kept" }, "scores omits what faded")
  eq(fr.prune(fade, now), 1, "prune reports what it dropped")
  eq(vim.tbl_keys(fade), { "kept" })

  -- the cap keeps the highest scores; ties break by recency, then id
  local many = {}
  for i = 1, 520 do
    many[("a/t%03d"):format(i)] = { score = i, last = T0 }
  end
  eq(fr.MAX_ENTRIES, 500)
  eq(fr.prune(many, T0), 20)
  eq(vim.tbl_count(many), 500)
  ok(many["a/t520"] and many["a/t021"], "the top 500 stay")
  ok(many["a/t020"] == nil and many["a/t001"] == nil, "the lowest 20 go")
  local ties = {
    ["c/same"] = { score = 1, last = T0 },
    ["b/same"] = { score = 1, last = T0 },
    ["a/same"] = { score = 1, last = T0 },
  }
  fr.prune(ties, T0, { max_entries = 2 })
  local kept = vim.tbl_keys(ties)
  table.sort(kept)
  eq(kept, { "a/same", "b/same" }, "equal scores at the cap: the lower id stays, deterministically")

  -- ── the file format ─────────────────────────────────────────────────────
  local text = fr.encode({ ["lib.nvim/alpha"] = { score = 1.23456789, last = T0 } })
  local back = assert(fr.decode(text))
  near(back["lib.nvim/alpha"].score, 1.2346, "scores are rounded to four places")
  eq(back["lib.nvim/alpha"].last, T0)
  eq(assert(fr.decode(fr.encode({}))), {}, "an empty table round-trips as an empty object")
  has(fr.encode({}), '"entries":{}')

  local good_and_bad = vim.json.encode({
    version = 1,
    entries = {
      ["a/ok"] = { score = 2, last = T0 },
      ["a/negative"] = { score = -1, last = T0 },
      ["a/zero"] = { score = 0, last = T0 },
      ["a/string"] = { score = "2", last = T0 },
      ["a/nolast"] = { score = 2 },
      ["a/notable"] = 5,
      [string.rep("x", 300)] = { score = 1, last = T0 },
    },
  })
  local decoded = assert(fr.decode(good_and_bad))
  eq(vim.tbl_keys(decoded), { "a/ok" }, "rows that do not validate are skipped, the rest is kept")

  for _, junk in ipairs({ "", "   \n", "not json {", "[1,2]", '"text"', '{"version":1}', "null" }) do
    local d, err = fr.decode(junk)
    eq(d, nil, "no entries from " .. vim.inspect(junk))
    ok(type(err) == "string", "a reason for " .. vim.inspect(junk))
  end
  eq(fr.decode(nil), nil)

  -- ── persistence ─────────────────────────────────────────────────────────
  local dir = H.tmpdir()
  local file = dir .. "/state/tasks/frecency.json"
  local clock = T0
  local function opts()
    return {
      path = file,
      now = function()
        return clock
      end,
    }
  end

  local entries, status = fr.load(opts())
  eq(entries, {}, "no file: empty")
  eq(status, "missing")
  eq(fr.load_scores(opts()), {}, "no file: no scores")

  eq({ fr.record("lib.nvim/alpha", opts()) }, { true })
  ok(H.exists(file), "record creates the file and its folders")
  entries, status = fr.load(opts())
  eq(status, "ok")
  near(entries["lib.nvim/alpha"].score, 1, "one visit")

  clock = T0 + 14 * DAY
  fr.record({ "lib.nvim/alpha", "cascade.nvim/gamma", "cascade.nvim/gamma" }, opts())
  entries = fr.load(opts())
  near(entries["lib.nvim/alpha"].score, 1.5, "decayed to now, plus the visit")
  near(entries["cascade.nvim/gamma"].score, 1, "an id given twice in one call is one visit")
  eq(fr.record({}, opts()), true, "nothing to record is fine")
  eq(fr.record("", opts()), true, "an empty id is skipped")
  near(
    fr.load_scores(opts())["lib.nvim/alpha"],
    1.5,
    "load_scores reads the file at the injected time"
  )
  clock = T0 + 28 * DAY
  near(fr.load_scores(opts())["lib.nvim/alpha"], 0.75, "and decays it")

  -- the cap is applied on write
  local capped = { path = H.tmpdir() .. "/c.json", now = opts().now, max_entries = 2 }
  fr.record("a/one", capped)
  clock = clock + 1
  fr.record("a/two", capped)
  clock = clock + 1
  fr.record("a/three", capped)
  eq(vim.tbl_count((fr.load(capped))), 2, "only max_entries stay in the file")

  -- a corrupt file: start empty, keep the old bytes aside, overwrite
  local bad = H.tmpdir() .. "/bad.json"
  H.write(bad, "{ this is not json")
  entries, status = fr.load({ path = bad })
  eq(entries, {})
  eq(status, "corrupt", "garbage is reported as corrupt, not raised")
  eq(fr.load_scores({ path = bad }), {}, "and scores nothing")
  eq({ fr.record("a/new", { path = bad, now = opts().now }) }, { true })
  entries, status = fr.load({ path = bad })
  eq(status, "ok", "the next record replaced the corrupt file")
  ok(entries["a/new"] ~= nil)
  eq(H.read(bad .. ".bad"), "{ this is not json", "the corrupt bytes were kept")
  -- a file full of valid JSON of the wrong shape is corrupt too
  H.write(bad, "[1,2,3]")
  eq(select(2, fr.load({ path = bad })), "corrupt")

  -- a runaway file is not read at all: corrupt, the bytes kept aside on the next record
  local huge = H.tmpdir() .. "/huge.json"
  local row = ('"a/x%d":{"score":1,"last":1700000000},'):format(1)
  H.write(huge, '{"version":1,"entries":{' .. row:rep(fr.MAX_FILE_BYTES / #row + 10) .. '"z":{}}}')
  ok(vim.uv.fs_stat(huge).size > fr.MAX_FILE_BYTES, "the fixture is over the limit")
  local huge_entries, huge_status, huge_err = fr.load({ path = huge })
  eq(huge_entries, {})
  eq(huge_status, "corrupt", "over the size limit is corrupt")
  has(huge_err, "more than")
  eq(fr.load_scores({ path = huge }), {}, "and scores nothing")
  eq({ fr.record("a/new", { path = huge, now = opts().now }) }, { true })
  eq(select(2, fr.load({ path = huge })), "ok", "the next record starts a fresh file")
  ok(vim.uv.fs_stat(huge .. ".bad").size > fr.MAX_FILE_BYTES, "the old bytes were kept aside")

  -- an unreadable path (a folder where the file should be) is never overwritten
  local blocked = H.tmpdir() .. "/blocked.json"
  vim.fn.mkdir(blocked, "p")
  entries, status = fr.load({ path = blocked })
  eq(entries, {})
  eq(status, "unreadable", "a folder in the way is unreadable")
  local rok, rerr = fr.record("a/x", { path = blocked, now = opts().now })
  eq(rok, false, "record refuses to write over what it could not read")
  has(rerr, "not readable")
  eq(vim.fn.isdirectory(blocked), 1, "the folder is still there")

  -- the path: set_path wins, then $TASKS_FRECENCY_FILE (run.lua sets it), then stdpath("state")
  local before = fr.path()
  fr.set_path(dir .. "/pinned.json")
  eq(fr.path(), dir .. "/pinned.json")
  fr.set_path(nil)
  eq(fr.path(), before)
  ok(
    vim.env.TASKS_FRECENCY_FILE == nil or fr.path() == vim.fs.normalize(vim.env.TASKS_FRECENCY_FILE)
  )
  local env_was = vim.env.TASKS_FRECENCY_FILE
  vim.env.TASKS_FRECENCY_FILE = nil
  has(fr.path(), "/tasks/frecency.json")
  vim.env.TASKS_FRECENCY_FILE = env_was

  -- ── model.sort(..., "frecency") ─────────────────────────────────────────
  ---@param area string
  ---@param slug string
  ---@param prio integer|nil
  ---@param st string
  local function task(area, slug, prio, st)
    return {
      id = area .. "/" .. slug,
      area = area,
      slug = slug,
      path = ("/v/%s/ROADMAP/tasks/%s.md"):format(area, slug),
      prio = prio,
      status = st or "open",
    }
  end
  local function ids(list)
    return vim.tbl_map(function(t)
      return t.id
    end, list)
  end
  local function fixture()
    return {
      task("a", "alpha", 1, "doing"),
      task("a", "beta", 2),
      task("b", "gamma", nil, "decision"),
      task("b", "delta", 3),
    }
  end

  eq(model.parse_sort("frecency"), "frecency", "frecency is a valid --sort word")
  eq(
    ids(model.sort(fixture(), "frecency", { scores = {} })),
    ids(model.sort(fixture())),
    "no scores: the default order"
  )
  eq(
    ids(model.sort(fixture(), "frecency", { scores = { ["b/delta"] = 3, ["a/beta"] = 1 } })),
    { "b/delta", "a/beta", "a/alpha", "b/gamma" },
    "scored tasks first (highest first), the rest in the default order -- statuses and prios mix on purpose"
  )
  eq(
    ids(model.sort(fixture(), "frecency", { scores = { ["a/beta"] = 2, ["b/delta"] = 2 } })),
    { "a/beta", "b/delta", "a/alpha", "b/gamma" },
    "equal scores fall back to the default order"
  )
  eq(
    ids(model.sort(fixture(), "default", { scores = { ["b/delta"] = 3 } })),
    ids(model.sort(fixture())),
    "other orders ignore scores"
  )

  -- without a table the scores come from the frecency file
  fr.set_path(H.tmpdir() .. "/sort.json")
  local sort_clock = os.time()
  fr.record({ "b/gamma", "b/gamma", "a/beta" }, { now = sort_clock })
  eq(
    ids(model.sort(fixture(), "frecency")),
    { "b/gamma", "a/beta", "a/alpha", "b/delta" },
    "list --sort=frecency reads the file"
  )
  H.write(fr.path(), "garbage")
  eq(
    ids(model.sort(fixture(), "frecency")),
    ids(model.sort(fixture())),
    "a corrupt file: the default order, no error"
  )
  fr.set_path(nil)
end
