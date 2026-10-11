-- TESTS/tasks_done_preview_spec.lua -- done_preview: what finishing a task would do, with nothing written, and a
-- confirm token that binds the version of the file that was shown.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local done_flow = require("tasks_nvim.done_flow")
  local fm = require("lib.nvim.markdown.frontmatter")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, date = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }

  --- Every file under the vault with its bytes: what a preview must leave exactly as it is.
  ---@return table<string, string>
  local function everything()
    local out = {}
    for _, path in ipairs(vim.fn.globpath(root, "**/*", true, true)) do
      if vim.fn.isdirectory(path) == 0 then
        out[path] = H.read(path)
      end
    end
    return out
  end

  local made = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Ship",
    areas = "lib.nvim",
  }))
  F.task(
    H,
    root,
    "lib.nvim",
    "last-member",
    F.meta("Last member", "doing", { { "plan", made.id }, { "kind", "task" } }),
    "\nA summary.\n\n## Plan\n\n- [ ] 1. first step\n- [ ] 2. second step\n"
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "waits",
    F.meta("Waits", "open", { { "blocked_by", "lib.nvim/last-member" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "waits-twice",
    F.meta("Waits twice", "open", { { "blocked_by", "[lib.nvim/last-member, lib.nvim/other]" } })
  )
  F.task(H, root, "lib.nvim", "other", F.meta("Other", "open"))
  F.task(H, root, "lib.nvim", "a-feature", F.meta("A feature", "open", { { "kind", "feature" } }))

  -- ── the preview writes nothing ───────────────────────────────────────────────
  local before = everything()
  local pv = assert(done_flow.preview("lib.nvim/last-member", o))
  eq(everything(), before, "not a byte of the vault changed")
  eq(pv.id, "lib.nvim/last-member")
  eq(pv.area, "lib.nvim")
  eq(pv.bucket, "TASKS")
  ok(
    pv.to:find("Backlog/TASKS/" .. F.TODAY .. "_last-member.md", 1, true),
    "where the finished file goes: " .. pv.to
  )
  ok(pv.from:find("ROADMAP/tasks/last-member.md", 1, true))
  eq(pv.readme, "updated", "the Backlog README gets a row")
  has(pv.readme_row, "last-member")
  eq(pv.steps_ticked, 2, "the open steps of its own plan section would be ticked")
  eq(pv.plan_id, made.id)
  eq(pv.closes_plan, made.id, "it is the last open member of its plan")
  eq(pv.freed, { "lib.nvim/waits" }, "waits-twice still waits on `other`")
  eq(
    pv.etag,
    scan.find("lib.nvim/last-member", { root = root }).etag,
    "the version of the file that was read"
  )
  ok(pv.confirm:match("^done%-%x+%-%x+$"), "a token: " .. pv.confirm)

  eq(done_flow.preview("lib.nvim/a-feature", o).bucket, "FEATURES")
  eq(done_flow.preview("lib.nvim/other", o).closes_plan, nil, "a task of no plan closes none")

  -- ── the token binds id and version ──────────────────────────────────────────
  eq(mutate.confirm_etag("lib.nvim/last-member", pv.confirm), pv.etag)
  eq(mutate.confirm_etag("lib.nvim/other", pv.confirm), nil, "a token for another task is none")
  eq(mutate.confirm_etag("lib.nvim/last-member", nil), nil)
  eq(mutate.confirm_etag("lib.nvim/last-member", 42), nil)
  eq(
    mutate.confirm_etag("lib.nvim/last-member", "done-0000000000000000-aaaaaa"),
    nil,
    "a made-up one"
  )
  eq(
    mutate.confirm_etag("lib.nvim/last-member", pv.confirm:sub(1, -2) .. "0"),
    nil,
    "a changed one"
  )
  eq(mutate.confirm_etag("lib.nvim/last-member", "garbage"), nil)

  -- ── if_match: the version shown is the one finished ─────────────────────────
  assert(fm.update(scan.find("lib.nvim/last-member", { root = root }).path, { { "prio", "1" } }))
  local res, err, info =
    done_flow.run("lib.nvim/last-member", vim.tbl_extend("force", o, { if_match = pv.etag }))
  eq(res, nil, "the file changed after the preview")
  eq(info.code, "conflict")
  eq(info.expected, pv.etag)
  eq(info.actual, scan.find("lib.nvim/last-member", { root = root }).etag)
  has(err, "changed since it was read")
  ok(scan.find("lib.nvim/last-member", { root = root }), "and the task is still open")

  -- a new preview, a new token; finishing with it works
  local again = assert(done_flow.preview("lib.nvim/last-member", o))
  ok(
    again.etag ~= pv.etag and again.confirm ~= pv.confirm,
    "a changed file has a new version and a new token"
  )
  local flow = assert(
    done_flow.run("lib.nvim/last-member", vim.tbl_extend("force", o, { if_match = again.etag }))
  )
  eq(flow.done.to, again.to, "finished exactly where the preview said")
  eq(flow.steps_ticked, 2)
  eq(flow.plans_closed, { made.id }, "and the plan closed, as the preview said")
  eq(flow.freed, { "lib.nvim/waits" })

  -- ── a finished task has nothing to confirm; an unknown one is an error ──────
  local done_again = assert(done_flow.preview("lib.nvim/last-member", o))
  eq(done_again.already, true)
  eq(done_again.confirm, nil)
  local none, nerr = done_flow.preview("lib.nvim/ghost", o)
  eq(none, nil)
  has(nerr, "no such open task")
  local bad = done_flow.preview("nonsense", o)
  eq(bad, nil, "a bad id is an error")

  -- the same reasons `done` has
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/odd.md",
    F.text(F.meta("Odd", "open", { { "kind", "mystery" } }))
  )
  local odd, oerr = done_flow.preview("lib.nvim/odd", o)
  eq(odd, nil)
  has(oerr, "unknown kind")
end
