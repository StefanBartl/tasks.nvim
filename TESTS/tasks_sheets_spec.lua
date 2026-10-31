-- TESTS/tasks_sheets_spec.lua -- the test-sheet block testing.nvim writes into a task: how its states line is read
-- (the worst sheet, the counts, markers in a fence, a block without its end or without a states line), and what the
-- model, the contract (`sheets`), `show`, `list --sheet=` and the dashboard line make of it. A task without the
-- block reads as before.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local sheets = require("tasks_nvim.sheets")

  local function block(states)
    return table.concat({
      sheets.BEGIN,
      "## Test sheets",
      "",
      "- **One** (`one`): automated part green, waiting for your judgement",
      states and (sheets.STATES_PREFIX .. " " .. states .. " -->") or "- (no states line)",
      sheets.END,
    }, "\n")
  end
  local BODY = "\nSummary.\n\n## Kontext\n\nWhy.\n\n"
    .. block("one=inbox two=green three=never")
    .. "\n\n## Notizen\n"

  -- ── reading ────────────────────────────────────────────────────────────────
  local s = sheets.parse(BODY)
  ok(s ~= nil, "the block is read")
  eq(s.state, "never", "the worst sheet: never ran is worse than waiting for a judgement")
  eq(s.total, 3)
  eq(
    s.counts,
    { red = 0, stale = 0, never = 1, inbox = 1, manual = 0, green = 1 },
    "the counts of every state"
  )
  eq(s.sheets[1], { id = "one", state = "inbox" }, "the sheets in the order of the line")
  eq(sheets.describe(s), "never (3 sheets: 1 never, 1 inbox, 1 green)")
  eq(sheets.parse(block("a=red b=stale")).state, "red", "red is the worst")
  eq(sheets.parse(block("a=green")).state, "green")
  eq(sheets.parse(block("a=manual b=green")).state, "manual")
  eq(sheets.parse(block("a=stale b=never")).state, "stale", "stale is worse than never")
  local odd = sheets.parse(block("a=purple b=green junk"))
  eq({ odd.state, odd.total }, { "green", 1 }, "a word that is no state is left out")
  local old = sheets.parse(block(nil))
  eq(
    { old.state, old.total },
    { "unknown", 0 },
    "a block without a states line (an older testing.nvim)"
  )
  has(sheets.describe(old), "no states line")
  eq(sheets.parse(block("")).state, "unknown", "an empty states line")
  eq(sheets.parse(block("a=inbox"):gsub("\n", "\r\n")).state, "inbox", "CRLF")

  -- review of ca44e86: the same rules as testing.nvim, and a states line that cannot stall a load
  local function reason(body)
    local r = sheets.parse(body)
    return r and { r.state, r.reason } or nil
  end
  eq(
    reason(block("a=red") .. "\n" .. block("b=green")),
    { "unknown", "broken-markers" },
    "two blocks"
  )
  eq(
    reason(sheets.END .. "\n" .. block("a=red")),
    { "unknown", "broken-markers" },
    "an end in front of the begin"
  )
  eq(
    reason(sheets.BEGIN .. "\n" .. sheets.STATES_PREFIX .. " a=red -->\n"),
    { "unknown", "broken-markers" },
    "a begin without its end"
  )
  has(sheets.describe(sheets.parse(block("a=red") .. "\n" .. block("b=red"))), "markers are broken")
  eq(
    sheets.parse(
      "  " .. sheets.BEGIN .. "  \n" .. sheets.STATES_PREFIX .. " a=red -->  \n " .. sheets.END
    ).state,
    "red",
    "markers and the states line are trimmed, as testing.nvim reads them"
  )
  for _, pre in ipairs({
    "```text\n~~~~~~~~\n```\n",
    "```\ncode\n```lua\n```\n",
    "```code``` sample\n",
  }) do
    eq(sheets.parse(pre .. block("a=red")).state, "red", "the block after " .. vim.inspect(pre))
  end
  local unk = sheets.parse(block("a=skipped"))
  eq(
    { unk.state, unk.reason },
    { "unknown", "no-known-state" },
    "a state word of a newer testing.nvim"
  )
  has(sheets.describe(unk), "no state this tasks.nvim knows")
  eq(old.reason, "no-states-line")
  local started = os.clock()
  sheets.parse(block(("a"):rep(40000)))
  sheets.parse(block("a=red" .. ("-"):rep(40000)))
  ok(os.clock() - started < 0.5, "a states line of 40000 characters without '=' stays linear")

  ok(sheets.parse("\nNo block here.\n") == nil, "a body without the block: nil")
  ok(
    sheets.parse("```\n" .. block("a=red") .. "\n```\n") == nil,
    "a block quoted in a fenced code block is text"
  )
  ok(
    sheets.parse("Text " .. sheets.BEGIN .. " and " .. sheets.END .. " in prose") == nil,
    "a marker inside a line is text"
  )
  eq(
    sheets.parse("```\n" .. block("a=red") .. "\n```\n\n" .. block("b=green")).state,
    "green",
    "the block after a quoted one"
  )
  eq(
    sheets.parse("````\n```\n````\n" .. block("a=manual")).state,
    "manual",
    "a shorter fence inside a longer one does not close it"
  )

  -- ── model, filter, contract, show ──────────────────────────────────────────
  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "checked", F.meta("Checked", "open", {}), BODY)
  F.task(
    H,
    root,
    "lib.nvim",
    "green",
    F.meta("Green", "open", {}),
    "\nAll fine.\n\n" .. block("x=green")
  )
  F.task(H, root, "lib.nvim", "plain", F.meta("Plain", "open", {}), "\nNo sheets.\n")
  local all = assert(require("tasks_nvim.scan").all({ root = root }))
  local by = {}
  for _, t in ipairs(all) do
    by[t.id] = t
  end
  eq(by["lib.nvim/checked"].sheets.state, "never", "the model carries the block")
  ok(by["lib.nvim/plain"].sheets == nil, "a task without the block: no field")

  local model = require("tasks_nvim.model")
  local function ids(f)
    local out = {}
    for _, t in ipairs(model.filter(all, f)) do
      out[#out + 1] = t.id
    end
    table.sort(out)
    return out
  end
  eq(ids({ sheet = { "never" } }), { "lib.nvim/checked" }, "filter by the state")
  eq(
    ids({ sheet = { "never", "green" } }),
    { "lib.nvim/checked", "lib.nvim/green" },
    "a list of states"
  )
  eq(
    ids({ sheet = { "any" } }),
    { "lib.nvim/checked", "lib.nvim/green" },
    "any: a task with the block"
  )
  eq(ids({ sheet = { "red" } }), {}, "nobody is red")

  local fo = require("tasks_nvim.filter_opts")
  eq(fo.parse({ sheet = "inbox,red" }).sheet, { "inbox", "red" })
  local _, ferr = fo.parse({ sheet = "purple" })
  has(ferr, "unknown state in --sheet: purple")
  local _, eerr = fo.parse({ sheet = "" })
  has(eerr, "--sheet needs a value")

  local contract = require("tasks_nvim.contract")
  local doc = assert(contract.task("lib.nvim/checked", { root = root }))
  eq(doc.task.sheets.state, "never", "the contract carries the state")
  eq(doc.task.sheets.total, 3)
  eq(doc.task.sheets.counts.inbox, 1)
  local plain_doc = assert(contract.task("lib.nvim/plain", { root = root }))
  ok(plain_doc.task.sheets == nil, "and nothing for a task without the block")
  ok(doc.task.sheets.reason == nil, "no reason when the state is known")
  F.task(
    H,
    root,
    "lib.nvim",
    "twice",
    F.meta("Twice", "open", {}),
    "\n" .. block("a=red") .. "\n\n" .. block("b=green")
  )
  local twice = assert(contract.task("lib.nvim/twice", { root = root }))
  eq(
    { twice.task.sheets.state, twice.task.sheets.reason },
    { "unknown", "broken-markers" },
    "the contract says why the state is unknown"
  )

  local cli = require("tasks_nvim.cli")
  local function run(argv)
    local out, err = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. F.TODAY }), {
        out = function(x)
          out[#out + 1] = x
        end,
        err = function(x)
          err[#err + 1] = x
        end,
      })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  has(
    run({ "show", "lib.nvim/checked" }).out,
    "sheets: never (3 sheets: 1 never, 1 inbox, 1 green)"
  )
  lacks(run({ "show", "lib.nvim/plain" }).out, "sheets:", "show without the block: as before")
  local listed = run({ "list", "lib.nvim", "--sheet=never", "--format=ids" })
  eq(listed.code, 0, listed.err)
  eq(vim.trim(listed.out), "lib.nvim/checked", "list --sheet=never")
  local any = run({ "list", "lib.nvim", "--sheet=any", "--format=ids" })
  eq(
    vim.split(vim.trim(any.out), "\n"),
    { "lib.nvim/checked", "lib.nvim/green", "lib.nvim/twice" },
    "list --sheet=any (a block with broken markers too)"
  )
  eq(run({ "list", "--sheet=purple" }).code, 2, "an unknown state is bad usage")

  -- ── the dashboard line ─────────────────────────────────────────────────────
  local core = require("tasks_nvim.ui.dash_core")
  local w = core.widths(all)
  has(core.line(by["lib.nvim/checked"], w), "[sheet: never]", "the dashboard line shows the state")
  lacks(core.line(by["lib.nvim/plain"], w), "[sheet:", "and nothing without the block")
  local hl
  for _, p in ipairs(core.parts(by["lib.nvim/green"], w)) do
    if p[1]:find("[sheet:", 1, true) then
      hl = p[2]
    end
  end
  eq(hl, "DiagnosticOk", "green is drawn green")
  has(core.search_text(by["lib.nvim/checked"]), "sheet:never", "and the picker finds it")
end
