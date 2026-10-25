-- TESTS/tasks_questions_spec.lua -- the optional `## Offene Fragen` section: how it is read (keys, options, the
-- recommendation, what counts as answered, what is wrong with it), how `answer` writes (through the front door: the
-- compare-and-set, the dry run, the inverse, the key of a question that had none, the refusals), and what the model,
-- `check` and the contract carry of it.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local questions = require("tasks_nvim.questions")
  local model = require("tasks_nvim.model")

  local BODY = table.concat({
    "",
    "A summary line.",
    "",
    "## Offene Fragen",
    "",
    "### Which format? [q1]",
    "Some words of explanation.",
    "- [ ] Section in the body (empfohlen)",
    "- [ ] List in the frontmatter",
    "",
    "### Settled already [q2]",
    "- [ ] Yes",
    "- [x] No",
    "",
    "### Written without a key",
    "- [ ] One",
    "- [ ] Two (recommended)",
    "",
    "```",
    "### Not a question, it is inside a fence",
    "- [ ] nor an option",
    "```",
    "",
    "## Notizen",
    "",
    "### Not a question: another section",
    "- [ ] nor an option",
    "",
  }, "\n")

  -- ── reading ────────────────────────────────────────────────────────────────
  local s = questions.parse(BODY)
  ok(s ~= nil, "the section is read")
  eq(s.total, 3)
  eq(s.open, 2, "q2 is answered, q1 and the third are open")
  eq(#s.problems, 0, vim.inspect(s.problems))
  local q1, q2, q3 = s.items[1], s.items[2], s.items[3]
  eq(q1.key, "q1")
  eq(q1.title, "Which format?")
  eq(q1.text, "Some words of explanation.")
  eq(#q1.options, 2)
  eq(
    q1.options[1].text,
    "Section in the body",
    "the marker of the recommendation is not part of the text"
  )
  eq(q1.options[1].recommended, true)
  eq(q1.options[2].recommended, false)
  eq(q1.answered, false)
  eq(q2.answered, true)
  eq(q2.options[2].chosen, true)
  eq(q3.key, nil, "a question may be written without a key")
  eq(q3.options[2].recommended, true, "the English marker counts too")
  eq(q3.n, 3)

  ok(questions.parse("\nNo questions here.\n") == nil, "no section, no questions")
  ok(
    questions.parse("\n## Offene Fragen\n\nOnly prose.\n") == nil,
    "a section without a question is none"
  )
  local en = questions.parse("\n## Open questions\n\n### Which? [q1]\n- [ ] A\n- [x] B\n")
  ok(en ~= nil and en.total == 1 and en.open == 0, "the English heading is read")

  -- what is wrong with a section: said once each
  local bad = questions.parse(table.concat({
    "## Offene Fragen",
    "### Twice [q1]",
    "- [x] A",
    "- [x] B (empfohlen)",
    "- [ ] C (empfohlen)",
    "### Same key [q1]",
    "- [ ] A",
    "### Empty [q3]",
  }, "\n"))
  local joined = table.concat(bad.problems, "\n")
  has(joined, "[q1] is used twice")
  has(joined, "2 ticked options")
  has(joined, "recommends 2 options")
  has(joined, "has no options")
  eq(bad.items[1].answered, false, "two ticked options are no answer")

  -- ── answering (pure) ───────────────────────────────────────────────────────
  local text2, info = questions.answer(BODY, "q1", 2)
  ok(text2 ~= nil, "answer q1 with the second option")
  eq(info.was, 0)
  eq(info.key, "q1")
  local after = questions.parse(text2)
  eq(after.items[1].options[2].chosen, true)
  eq(after.items[1].options[1].chosen, false)
  eq(after.open, 1)
  has(text2, "- [x] List in the frontmatter")
  has(text2, "- [ ] Section in the body (empfohlen)", "the marker stays in the file")
  -- everything else is as it was
  eq(text2:gsub("%[x%] List", "[ ] List", 1), BODY)

  -- another option replaces the answer, option 0 takes it back
  local text3, info3 = questions.answer(text2, "q1", 1)
  eq(info3.was, 2)
  local back = questions.parse(text3)
  eq(back.items[1].options[1].chosen, true)
  eq(back.items[1].options[2].chosen, false)
  local text4 = questions.answer(text3, "q1", 0)
  eq(questions.parse(text4).items[1].answered, false)
  -- the same state again is no change
  eq((questions.answer(text3, "q1", 1)), text3)
  eq((questions.answer(text4, "q1", 0)), text4)

  -- a question without a key gets the next free one, when it is answered
  local keyed, kinfo = questions.answer(BODY, 3, 1)
  eq(kinfo.key, "q3", "the next number after the highest key")
  has(keyed, "### Written without a key [q3]")
  eq(questions.parse(keyed).items[3].key, "q3")
  local by_hash = questions.answer(BODY, "#3", 2)
  has(by_hash, "### Written without a key [q3]")

  -- refusals
  local function refuses(...)
    local t, _, err = questions.answer(...)
    ok(t == nil and err ~= nil, "refused")
    return err
  end
  has(refuses(BODY, "q9", 1), "there is no question q9")
  has(refuses(BODY, "q1", 3), "there is no option 3")
  has(refuses(BODY, "q1", -1), "there is no option -1")
  has(refuses(BODY, "q1", 1.5), "there is no option")
  has(refuses("\nNothing.\n", "q1", 1), "no questions")
  has(
    refuses(
      table.concat({ "## Offene Fragen", "### Two ticked [q1]", "- [x] A", "- [x] B" }, "\n"),
      "q1",
      1
    ),
    "more than one ticked"
  )

  -- the line endings of a file with CRLF stay
  local crlf = BODY:gsub("\n", "\r\n")
  local crlf_new = questions.answer(crlf, "q1", 1)
  ok(not crlf_new:find("[^\r]\n"), "every line ending is still CRLF")
  local crlf_keyed = questions.answer(crlf, 3, 1)
  has(crlf_keyed, "### Written without a key [q3]\r\n")

  -- ── through the write door ─────────────────────────────────────────────────
  local root = F.vault(H)
  local path =
    F.task(H, root, "lib.nvim", "asker", F.meta("Asker", "decision", { { "prio", "2" } }), BODY)

  ---@param method string
  ---@param params string  # JSON.
  ---@return table doc
  local function call(method, params)
    local text = api.call(method, params, { root = root, today = F.TODAY })
    return vim.json.decode(text)
  end

  ---@param list table[]
  ---@param extra? table
  ---@return table doc
  local function ops(list, extra)
    local text = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = list }, extra or {})),
      { root = root, today = F.TODAY }
    )
    return vim.json.decode(text)
  end
  ---@param op table
  ---@param extra? table
  ---@return table entry
  local function one(op, extra)
    local doc = ops({ op }, extra)
    if doc.kind ~= "tasks.result" then
      error((vim.inspect(doc):gsub("%s+", " "):sub(150, 700)))
    end
    return doc.results[1]
  end

  local before = H.read(path)
  local dry = one(
    { op = "answer", id = "lib.nvim/asker", question = "q1", option = 1 },
    { dry_run = true }
  )
  eq(dry.outcome, "would_change")
  eq(H.read(path), before, "a dry run writes nothing")

  local entry = one({ op = "answer", id = "lib.nvim/asker", question = "q1", option = 1 })
  eq(entry.ok, true, vim.inspect(entry))
  eq(entry.outcome, "changed")
  local written = H.read(path)
  has(written, "- [x] Section in the body (empfohlen)")
  ok(written:find("\nupdated: " .. F.TODAY, 1, true) ~= nil, "updated is set")
  eq(entry.inverse.op, "answer")
  eq(entry.inverse.question, "q1")
  eq(entry.inverse.clear, true, "the inverse takes the answer back")
  ok(entry.inverse.option == nil)
  eq(entry.inverse.if_match, fsio.etag(written))

  -- the inverse restores the text (apart from `updated`)
  local undone = one(entry.inverse)
  eq(undone.outcome, "changed")
  eq((H.read(path):gsub("\nupdated: [^\n]*", "")), (before:gsub("\nupdated: [^\n]*", "")))

  -- the same answer again is unchanged; a stale version is a conflict that writes nothing
  one({ op = "answer", id = "lib.nvim/asker", question = "q1", option = 2 })
  eq(
    one({ op = "answer", id = "lib.nvim/asker", question = "q1", option = 2 }).outcome,
    "unchanged"
  )
  local mid = H.read(path)
  local stale = one({
    op = "answer",
    id = "lib.nvim/asker",
    question = "q1",
    option = 1,
    if_match = "sha256:0000000000000000",
  })
  eq(stale.error.code, "conflict", vim.inspect(stale))
  eq(H.read(path), mid)

  local function refuses_op(op, why)
    local r = one(op)
    eq(r.ok, false, vim.inspect(r))
    has(r.error.message, why)
  end

  -- a question without a key: the inverse names the key it has now
  local keyless = one({ op = "answer", id = "lib.nvim/asker", question = "#3", option = 1 })
  eq(keyless.inverse.question, "q3")
  eq(keyless.inverse.clear, true)
  -- what was ticked before comes back as an option
  local swapped = one({ op = "answer", id = "lib.nvim/asker", question = "q3", option = 2 })
  eq(swapped.inverse.option, 1)
  ok(swapped.inverse.clear == nil)
  -- an option and clear together, or neither, are refused
  refuses_op(
    { op = "answer", id = "lib.nvim/asker", question = "q3", option = 1, clear = true },
    "not both"
  )
  refuses_op(
    { op = "answer", id = "lib.nvim/asker", question = "q3" },
    "needs id, question and option"
  )
  eq(
    one({ op = "answer", id = "lib.nvim/asker", question = "q3", clear = true }).outcome,
    "changed"
  )

  -- refusals leave the file as it was, and say why
  local fixed = H.read(path)
  for _, c in ipairs({
    {
      { op = "answer", id = "lib.nvim/asker", question = "q9", option = 1 },
      "there is no question q9",
    },
    {
      { op = "answer", id = "lib.nvim/asker", question = "q1", option = 7 },
      "there is no option 7",
    },
    { { op = "answer", id = "lib.nvim/asker", question = "q1" }, "needs id, question and option" },
  }) do
    local r = one(c[1])
    eq(r.ok, false, vim.inspect(r))
    has(r.error.message, c[2])
  end
  for _, shape in ipairs({
    { op = "answer", id = "lib.nvim/asker", question = "q1", option = "1" },
    { op = "answer", id = "lib.nvim/asker", question = 1, option = 1 },
    { op = "answer", id = "lib.nvim/asker", question = "q1", option = 1, surprise = true },
  }) do
    local doc = ops({ shape })
    eq(doc.kind, "tasks.error", vim.inspect(shape))
    eq(doc.code, "invalid_argument")
  end
  eq(
    one({ op = "answer", id = "lib.nvim/missing", question = "q1", option = 1 }).error.code,
    "not_found"
  )
  eq(H.read(path), fixed)

  -- ── what the model, check and the contract carry ───────────────────────────
  local task = model.from_file(path, { area = "lib.nvim", location = "roadmap" })
  ok(task.questions ~= nil and task.questions.total == 3, "the model keeps the questions")
  local doc = call("task", vim.json.encode({ params = { id = "lib.nvim/asker" } }))
  eq(#doc.questions, 3)
  eq(doc.questions[1].key, "q1")
  eq(doc.questions[1].options[1].recommended, true)
  eq(doc.task.open_questions, 1, "q3 was cleared again, q1 and q2 are answered")
  local snap = call("snapshot", "{}")
  local found
  for _, t in ipairs(snap.tasks) do
    if t.id == "lib.nvim/asker" then
      found = t
    end
  end
  eq(found.open_questions, 1)

  -- a task that waits for two answers says so, in the entry of the snapshot and of the document
  F.task(H, root, "lib.nvim", "waiting", F.meta("Waiting", "decision", {}), BODY)
  local snap2 = call("snapshot", "{}")
  for _, t in ipairs(snap2.tasks) do
    if t.id == "lib.nvim/waiting" then
      eq(t.open_questions, 2)
    end
  end

  -- a task without the section carries no field and an empty list
  F.task(H, root, "lib.nvim", "plain", F.meta("Plain", "open", {}), "\nNothing to ask.\n")
  local plain = call("task", vim.json.encode({ params = { id = "lib.nvim/plain" } }))
  eq(plain.questions, {}, "no section: an empty list")
  ok(plain.task.open_questions == nil, "and no count")

  -- a problem in the section is a hint of the model, so `check` says it
  F.task(
    H,
    root,
    "lib.nvim",
    "twice",
    F.meta("Twice", "open", {}),
    "\n## Offene Fragen\n\n### A [q1]\n- [x] a\n- [x] b\n"
  )
  local hints = {}
  for _, h in
    ipairs(
      model.from_file(
        root .. "/lib.nvim/ROADMAP/tasks/twice.md",
        { area = "lib.nvim", location = "roadmap" }
      ).hints or {}
    )
  do
    hints[#hints + 1] = h.code .. " " .. h.msg
  end
  has(table.concat(hints, "\n"), "question-problem")
  lacks(table.concat(hints, "\n"), "plan-acceptance")

  -- ── the command line ───────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(
      vim.list_extend(
        vim.deepcopy(argv),
        { "--vault=" .. root, "--today=" .. F.TODAY, "--no-index" }
      ),
      {
        out = function(x)
          out[#out + 1] = x
        end,
        err = function(x)
          err[#err + 1] = x
        end,
      }
    )
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function run_plain(argv)
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
  F.task(H, root, "lib.nvim", "cliask", F.meta("Cli ask", "decision", {}), BODY)
  local r = run({ "answer", "lib.nvim/cliask", "q1", "2" })
  eq(r.code, 0, r.err)
  has(r.out, "answer")
  has(r.out, "changed")
  has(H.read(root .. "/lib.nvim/ROADMAP/tasks/cliask.md"), "- [x] List in the frontmatter")
  eq(run({ "answer", "lib.nvim/cliask", "q1", "clear" }).code, 0)
  has(H.read(root .. "/lib.nvim/ROADMAP/tasks/cliask.md"), "- [ ] List in the frontmatter")
  eq(run({ "answer", "lib.nvim/cliask", "q1" }).code, 2, "usage")
  eq(run({ "answer", "lib.nvim/cliask", "q1", "x" }).code, 2, "a word that is no option")
  local refused = run({ "answer", "lib.nvim/cliask", "q9", "1" })
  eq(refused.code, 1)
  has(refused.err, "there is no question q9")
  local shown = run_plain({ "show", "lib.nvim/cliask" })
  has(shown.out, "open_questions: 2")

  -- ── a line of blanks is no way to stall the engine (SEC-32) ────────────────
  local blanks = string.rep(" ", 200000)
  local hostile = table.concat({
    "## Offene Fragen",
    "### " .. blanks .. "x",
    "- [ ] " .. blanks .. "x",
    "### " .. blanks .. "y [q2]" .. blanks,
    "- [ ] " .. blanks .. "(empfohlen)" .. blanks,
    "- [ ] option",
  }, "\n")
  local started = os.clock()
  local slow = questions.parse(hostile)
  local slow_answer = questions.answer(hostile, 1, 1)
  ok(os.clock() - started < 2, "parsing and answering a line of 200000 blanks stays linear")
  ok(slow ~= nil and slow.total == 2 and slow_answer ~= nil)
  eq(slow.items[2].key, "q2")
  eq(slow.items[2].options[1].recommended, true, "the marker counts at the end of the trimmed text")

  -- ── :Tasks task answer ─────────────────────────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local vault = require("tasks_nvim.vault")
  vault.set_root(root)
  local told = {}
  local orig = { notify = vim.notify, select = vim.ui.select }
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  F.task(H, root, "lib.nvim", "ed", F.meta("Ed", "decision", {}), BODY)
  local ed = root .. "/lib.nvim/ROADMAP/tasks/ed.md"
  -- with question= and option= the answer is written
  cmd.task_answer({
    rest = {},
    args = { id = "lib.nvim/ed" },
    kv = { question = "q1", option = "2" },
  })
  has(H.read(ed), "- [x] List in the frontmatter")
  has(table.concat(told, "\n"), "answer lib.nvim/ed q1: changed")
  cmd.task_answer({
    rest = {},
    args = { id = "lib.nvim/ed" },
    kv = { question = "q1", option = "clear" },
  })
  has(H.read(ed), "- [ ] List in the frontmatter")
  -- half of the pair, a word that is no option, an unknown question: nothing is written, each is said
  local bytes = H.read(ed)
  told = {}
  cmd.task_answer({ rest = {}, args = { id = "lib.nvim/ed" }, kv = { question = "q1" } })
  cmd.task_answer({
    rest = {},
    args = { id = "lib.nvim/ed" },
    kv = { question = "q1", option = "x" },
  })
  cmd.task_answer({
    rest = {},
    args = { id = "lib.nvim/ed" },
    kv = { question = "q9", option = "1" },
  })
  eq(H.read(ed), bytes)
  eq(#told, 3, table.concat(told, "|"))
  -- without them every open question is asked, the recommended option marked, and the choice written
  local asked = {}
  vim.ui.select = function(items, opts, on_choice)
    asked[#asked + 1] = { items = items, prompt = opts.prompt }
    on_choice(items[1], 1)
  end
  cmd.task_answer({ rest = {}, args = { id = "lib.nvim/ed" }, kv = {} })
  eq(#asked, 2, "q1 and the keyless question are open, q2 is answered")
  eq(asked[1].items[1], "Section in the body  (recommended)")
  has(asked[1].prompt, "Which format?")
  local after_ask = H.read(ed)
  has(after_ask, "- [x] Section in the body (empfohlen)")
  has(after_ask, "### Written without a key [q3]")
  -- a task without questions is told so
  F.task(H, root, "lib.nvim", "edplain", F.meta("Ed plain", "open", {}), "\nNothing.\n")
  told = {}
  cmd.task_answer({ rest = {}, args = { id = "lib.nvim/edplain" }, kv = {} })
  has(table.concat(told, "\n"), "has no questions")
  vim.notify, vim.ui.select = orig.notify, orig.select
end
