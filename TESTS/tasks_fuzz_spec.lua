-- TESTS/tasks_fuzz_spec.lua -- property checks with a fixed seed: whatever bytes a vault or a command line holds,
-- the readers answer (data or an error) and never raise, and the generators keep their promises.

return function(H)
  local eq, ok = H.eq, H.ok
  local fsio = require("tasks_nvim.fsio")
  local model = require("tasks_nvim.model")
  local vault = require("tasks_nvim.vault")
  local mutate = require("tasks_nvim.mutate")
  local staleness = require("tasks_nvim.staleness")
  local filter_opts = require("tasks_nvim.filter_opts")

  -- A tiny deterministic generator (an LCG): the same run every time, no dependence on math.random's seed.
  local state = 20261005
  ---@param n integer
  ---@return integer
  local function rnd(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end

  -- Pieces that matter to the parsers: frontmatter fences, YAML punctuation, table and escape characters,
  -- control bytes, a non-UTF-8 byte, long runs, CR/LF.
  local PIECES = {
    "---",
    "\n",
    "\r\n",
    ":",
    ": ",
    "title",
    "status",
    "open",
    "doing",
    "refs",
    "[",
    "]",
    ",",
    "|",
    "\\",
    '"',
    "'",
    "#",
    "!",
    "- ",
    "  ",
    "\t",
    "\27",
    "\0",
    "\255",
    "\194\155",
    "ä",
    "ß",
    string.rep(" ", 40),
    string.rep("\\", 40),
    "2026-10-05",
    "..",
    "../",
    "C:/x",
    "lib.nvim@803de65",
    "a.lua:12",
    "x#y",
  }

  ---@param max integer  pieces at most
  ---@return string
  local function noise(max)
    local out = {}
    for _ = 1, rnd(max) do
      out[#out + 1] = PIECES[rnd(#PIECES)]
    end
    return table.concat(out)
  end

  local ROUNDS = 300

  -- ── model.parse_text: a task comes back for every text, never a raise ──
  for i = 1, ROUNDS do
    local text = (i % 3 == 0 and "---\n" or "")
      .. noise(40)
      .. (i % 2 == 0 and "\n---\n" or "")
      .. noise(10)
    local called, task =
      pcall(model.parse_text, text, { area = "lib.nvim", slug = "fuzz", path = "x.md" })
    ok(called, "parse_text raised on " .. vim.inspect(text) .. ": " .. tostring(task))
    ok(
      type(task) == "table" and type(task.errors) == "table",
      "a broken file is still a task with errors"
    )
    ok(task.valid == (#task.errors == 0), "`valid` agrees with `errors`")
  end

  -- ── filter_opts.parse: a filter or an error string, for any value of any option ──
  local OPTION_KEYS =
    { "status", "prio", "effort", "kind", "tag", "category", "severity", "stale", "today" }
  for _ = 1, ROUNDS do
    local opt = {}
    for _ = 1, rnd(3) do
      local value = noise(6)
      if rnd(5) == 1 then
        value = rnd(12) - 3
      end
      opt[OPTION_KEYS[rnd(#OPTION_KEYS)]] = value
    end
    local called, filter, err = pcall(filter_opts.parse, opt)
    ok(called, "filter_opts.parse raised on " .. vim.inspect(opt) .. ": " .. tostring(filter))
    ok((filter ~= nil) ~= (err ~= nil), "exactly one of filter / error comes back")
  end

  -- ── mutate.slugify: always a valid slug, and slugifying a slug changes nothing ──
  for _ = 1, ROUNDS do
    local title = noise(12)
    local slug = mutate.slugify(title)
    ok(
      vault.valid_slug(slug),
      ("slugify gave an invalid slug %q for %s"):format(slug, vim.inspect(title))
    )
    eq(mutate.slugify(slug), slug, "slugify is idempotent on its own output")
  end

  -- ── fsio.md_cell / clean / double_runs ──
  for _ = 1, ROUNDS do
    local text = noise(30)
    local cell = fsio.md_cell(text)
    ok(not cell:find("[\r\n]"), "a cell holds no line break")
    ok(not cell:find("[%z\1-\8\11\12\14-\31\127]"), "a cell holds no control byte")
    -- every `|` that is left is preceded by an odd number of backslashes: it cannot end the cell
    local pos = 1
    while true do
      local at = cell:find("|", pos, true)
      if not at then
        break
      end
      local run = cell:sub(1, at - 1):match("\\*$")
      ok(#run % 2 == 1, "an unescaped | in a cell: " .. vim.inspect(cell))
      pos = at + 1
    end
    eq(fsio.clean(fsio.clean(text)), fsio.clean(text), "clean is idempotent")
  end

  -- ── staleness.classify: a verdict for every ref ──
  for _ = 1, ROUNDS do
    local ref = noise(6)
    local called, kind, rel = pcall(staleness.classify, ref)
    ok(called, "classify raised on " .. vim.inspect(ref))
    ok(kind == "path" or kind == "skip", "classify answers path or skip")
    ok(kind == "skip" or (type(rel) == "string" and rel ~= ""), "a path verdict carries a path")
  end
  for _, odd in ipairs({ 1, true, {}, vim.NIL }) do
    eq((staleness.classify(odd)), "skip", "a non-string ref is skipped, not a raise")
  end

  -- ── model.is_date / days_between never raise and agree with each other ──
  for _ = 1, ROUNDS do
    local a, b = noise(3), noise(3)
    local called, d = pcall(model.days_between, a, b)
    ok(called, "days_between raised")
    ok(d == nil or model.is_date(a) and model.is_date(b), "a day count needs two dates")
  end
end
