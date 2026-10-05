-- TESTS/tasks_steps_spec.lua -- the optional `## Plan` section: progress, ticking, dropped steps, the acceptance hint,
-- and how the model, the template and `plan --with-steps` carry it.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local steps = require("tasks_nvim.steps")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local cli = require("tasks_nvim.cli")

  local BODY = table.concat({
    "Summary line.",
    "",
    "## Akzeptanz",
    "",
    "- [ ] one",
    "- [ ] two",
    "- [x] three",
    "",
    "## Plan",
    "",
    "- [x] 1. config table -- Akzeptanz 1",
    "- [ ] 2. validators -- Akzeptanz 2, 3",
    "  - [ ] nested sub step",
    "- [ ] 3. spec (dropped)",
    "- [ ] 4. docs",
    "",
    "```",
    "- [ ] not a step, it is inside a fence",
    "## Not a heading either",
    "```",
    "",
    "## Notizen",
    "",
    "- [ ] not a step: another section",
    "",
  }, "\n")

  -- ── parse ──
  local sum = steps.parse(BODY)
  eq(sum.total, 4, "steps that count: 1, 2, nested, 4 (the dropped one is struck)")
  eq(sum.ticked, 1)
  eq(sum.dropped, 1)
  eq(#sum.items, 5)
  eq(sum.items[1].text, "1. config table -- Akzeptanz 1")
  eq(sum.items[1].done, true)
  eq(sum.items[4].dropped, true)
  eq(sum.items[4].n, 4)
  eq(steps.parse("no plan here\n- [ ] a checkbox\n"), nil, "no section, no progress, no finding")
  eq(steps.parse("## Plan\n\njust prose\n"), nil, "a section without a checkbox")
  eq(steps.parse("## Plan\n\n- [ ] a\r\n- [X] b\r\n").ticked, 1, "CRLF and an upper-case X")
  eq(steps.parse("## Plans\n\n- [ ] a\n"), nil, "only the heading `## Plan` itself")
  eq(steps.parse("# Plan\n\n- [ ] a\n"), nil, "and only at level two")

  -- ── tick_all: every other byte stays, dropped steps stay open ──
  local ticked_text, n = steps.tick_all(BODY)
  eq(n, 3, "step 2, the nested one and step 4")
  has(ticked_text, "- [x] 2. validators")
  has(ticked_text, "  - [x] nested sub step")
  has(ticked_text, "- [ ] 3. spec (dropped)")
  has(ticked_text, "- [x] 4. docs")
  has(ticked_text, "- [ ] not a step, it is inside a fence")
  has(ticked_text, "- [ ] not a step: another section")
  has(ticked_text, "- [ ] one", "the acceptance list is not the plan")
  local back = ticked_text
    :gsub("%- %[x%] 2%. validators", "- [ ] 2. validators")
    :gsub("  %- %[x%] nested", "  - [ ] nested")
    :gsub("%- %[x%] 4%. docs", "- [ ] 4. docs")
  eq(back, BODY, "the rest is byte for byte the same")
  local again, again_n = steps.tick_all(ticked_text)
  eq(again_n, 0)
  eq(again, ticked_text, "nothing left to tick: the very same text")
  local crlf = "## Plan\r\n\r\n- [ ] a\r\n- [ ] b\r\n"
  local crlf_out, crlf_n = steps.tick_all(crlf)
  eq(crlf_out, "## Plan\r\n\r\n- [x] a\r\n- [x] b\r\n", "line endings are kept")
  eq(crlf_n, 2)
  eq(select(2, steps.tick_all("no plan")), 0)

  -- ── the acceptance hint ──
  eq(steps.uncovered_acceptance(BODY), {}, "points 1, 2 and 3 are all named by a step")
  local gap = BODY:gsub("Akzeptanz 2, 3", "Akzeptanz 2")
  eq(steps.uncovered_acceptance(gap), { 3 })
  eq(
    steps.uncovered_acceptance(
      "## Akzeptanz\n\n- [ ] a\n- [ ] b\n\n## Plan\n\n- [ ] 1. x -- Acceptance 1 and 2\n"
    ),
    {}
  )
  eq(
    steps.uncovered_acceptance(
      "## Akzeptanz\n\n- [ ] a\n- [ ] b\n\n## Plan\n\n- [ ] 1. x -- Akzeptanz 1 und 2\n"
    ),
    {}
  )
  eq(steps.uncovered_acceptance("## Akzeptanz\n\n- [ ] a\n"), {}, "no plan: nothing to say")
  eq(
    steps.uncovered_acceptance("## Plan\n\n- [ ] 1. x\n"),
    {},
    "no acceptance list: nothing to say"
  )

  -- ── the model carries the progress, and the hint ──
  local function parse(body)
    return model.parse_text(
      "---\ntitle: T\nstatus: open\n---\n" .. body,
      { path = "/v/a/ROADMAP/tasks/t.md", area = "a" }
    )
  end
  local t = parse(BODY)
  eq(t.plan_steps.total, 4)
  eq(t.plan_steps.ticked, 1)
  eq(t.hints, {}, "everything covered: no hint")
  local t2 = parse(gap)
  eq(#t2.hints, 1)
  eq(t2.hints[1].code, "plan-acceptance-uncovered")
  has(t2.hints[1].msg, "3")
  eq(parse("plain body\n").plan_steps, nil, "no section: nothing")
  ok(t2.valid, "a hint is no error")

  -- ── template ──
  local with = mutate.template({ with_plan = true, today = F.TODAY })
  has(with, "## Plan")
  local pos_plan, pos_notes = with:find("## Plan", 1, true), with:find("## Notizen", 1, true)
  ok(pos_plan < pos_notes, "the section sits before the notes")
  lacks(mutate.template({ today = F.TODAY }), "## Plan", "the standard template does not change")
  has(mutate.template({ with_plan = true, lang = "en", today = F.TODAY }), "## Plan")

  -- ── check: a hint, not an error; and the CLI ──
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "With steps" })))
  local text = assert(H.read(made.path))
  H.write(made.path, text .. "\n" .. "## Plan\n\n- [ ] 1. only step\n")
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local md = run({ "plan", "lib.nvim", "--with-steps" })
  eq(md.code, 0, md.err)
  has(md.out, "**" .. made.id .. "** -- 0/1 steps")
  has(md.out, "- [ ] 1. only step")
  lacks(run({ "plan", "lib.nvim" }).out, "only step", "steps only with --with-steps")
  local tpl = run({ "template", "--with-plan" })
  has(tpl.out, "## Plan")
  lacks(run({ "template" }).out, "## Plan")
end
