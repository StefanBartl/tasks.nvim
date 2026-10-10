-- TESTS/tasks_dash_fallback_spec.lua -- the dashboard without a picker plugin (plugin_repos/tasks_dash.lua): the plain
-- vim.ui.select list and its menu, the default seam of `:Tasks list` (dashboard, scratch buffer), the export prompt and
-- the progress of a batch that fails. Prompts (confirm, select, input) are stubbed with scripted answers. It needs no
-- snacks.nvim, so it always runs; the Snacks.picker half of the dashboard is tasks_dash_picker_spec.lua, which skips
-- itself without snacks.nvim.

---@diagnostic disable: duplicate-set-field, param-type-mismatch
-- Why: specs replace module functions with test doubles on purpose.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local dash = require("tasks_nvim.ui.dash")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)

  -- ── scripted prompts and captured notifications ─────────────────────────
  local orig = {
    notify = vim.notify,
    select = vim.ui.select,
    input = vim.ui.input,
    yesno = confirm.yesno,
  }
  ---@type { msg: string, level: integer }[]
  local notes = {}
  ---@type table[]  prompts the stubs were asked, in order
  local asked = {}
  ---@type (fun(items: any[], opts: table): any)[]
  local select_queue = {}
  ---@type string[]
  local input_queue = {}
  local yesno_answer = true

  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end
  vim.ui.select = function(items, opts, cb)
    asked[#asked + 1] = { kind = "select", items = items, opts = opts }
    local answer = table.remove(select_queue, 1)
    cb(answer and answer(items, opts) or nil)
  end
  vim.ui.input = function(opts, cb)
    asked[#asked + 1] = { kind = "input", opts = opts }
    cb(table.remove(input_queue, 1))
  end
  confirm.yesno = function(msg, label, cb)
    asked[#asked + 1] = { kind = "confirm", msg = msg, label = label }
    cb(yesno_answer)
  end

  ---@param value string
  ---@return fun(items: any[]): any
  local function pick(value)
    return function(items)
      for _, item in ipairs(items) do
        local label = type(item) == "table" and (item.label or item.id) or item
        if label == value then
          return item
        end
      end
      error("the prompt has no entry " .. vim.inspect(value) .. " in " .. vim.inspect(items), 0)
    end
  end

  local function said()
    local out = {}
    for _, n in ipairs(notes) do
      out[#out + 1] = n.msg
    end
    return table.concat(out, "\n")
  end

  local function reset()
    notes, asked, select_queue, input_queue, yesno_answer = {}, {}, {}, {}, true
  end

  local function flush()
    vim.wait(60, function()
      return false
    end)
  end

  -- ── fixture ─────────────────────────────────────────────────────────────
  local today = os.date("%Y-%m-%d") --[[@as string]]
  local function add(area, slug, title, status, extra)
    local m = F.meta(title, status, extra)
    m[#m + 1] = { "created", today }
    m[#m + 1] = { "updated", "2026-01-01" }
    return F.task(H, root, area, slug, m)
  end
  local alpha = add("lib.nvim", "alpha", "Alpha feature", "doing", {
    { "kind", "feature" },
    { "prio", "1" },
    { "effort", "M" },
    { "tags", "[ui]" },
  })
  add("lib.nvim", "beta", "Beta bug", "open", { { "kind", "bug" }, { "prio", "2" } })
  add("cascade.nvim", "gamma", "Gamma idea", "decision", { { "kind", "idea" } })
  add("cascade.nvim", "delta", "Delta task", "open", {
    { "kind", "task" },
    { "tags", "[x]" },
  })

  local function restore()
    vim.notify, vim.ui.select, vim.ui.input = orig.notify, orig.select, orig.input
    confirm.yesno = orig.yesno
    cmd.dashboard = nil
    vault.set_root(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end

  local ok_run, err = pcall(function()
    reset()
    -- pick the first row (alpha, doing), advance its prio 1 -> 2, then leave the reopened list
    select_queue = {
      function(items)
        eq(#items, 4, "the plain list shows every open task")
        eq(items[1].id, "lib.nvim/alpha", "sorted like the dashboard")
        return items[1]
      end,
      pick("advance prio"),
      function()
        return nil
      end,
    }
    dash.open({ tasks = {}, root = root, filter = {} }, { persist = false, backend = "select" })
    flush()
    has(H.read(alpha), "prio: 2", "the fallback advanced the prio of the chosen task")
    has(said(), "prio: 1 changed", "one summary notification")
    eq(#asked, 3, "list, menu, list again")
    has(asked[1].opts.prompt, "4 open", "the prompt carries the header")

    -- the menu offers the single-task actions
    reset()
    select_queue = {
      function(items)
        return items[1]
      end,
      function(items)
        local labels = vim.tbl_map(function(m)
          return m.label
        end, items)
        eq(labels, {
          "open the file",
          "preview the file (mdview)",
          "advance status",
          "advance prio",
          "finish",
          "filter ...",
          "lists ...",
          "next sort order",
          "export the list ...",
          "Backlog of the area",
          "ROADMAP.md of the area",
        })
        return nil
      end,
    }
    dash.open({ tasks = {}, root = root, filter = {} }, { persist = false, backend = "select" })
    flush()

    -- an empty result says so instead of opening an empty list
    reset()
    dash.open({ tasks = {}, root = root, filter = { status = { "parked" } } }, {
      persist = false,
      backend = "select",
    })
    flush()
    has(said(), "no open task matches")
    eq(#asked, 0)

    -- the default seam: `tasks_cmd.dashboard == nil` opens the dashboard, `false` the scratch buffer
    reset()
    local opened
    local orig_open = dash.open
    dash.open = function(v)
      opened = v
    end
    cmd.dashboard = nil
    cmd.list({ flags = {}, args = {} })
    ok(opened, "no --to/--format: the dashboard opens by default")
    eq(opened.root, root)
    eq(#opened.tasks, 4)
    opened = nil
    cmd.list({ flags = { to = "buffer" }, args = {} })
    eq(opened, nil, "--to=buffer keeps the old behaviour")
    vim.cmd("silent! bwipeout!")
    cmd.dashboard = false
    cmd.list({ flags = {}, args = {} })
    eq(opened, nil, "dashboard = false means the scratch buffer")
    vim.cmd("silent! bwipeout!")
    dash.open = orig_open
    cmd.dashboard = nil

    -- ── export: the path typed at the prompt goes as typed ───────────────
    -- `vim.fn.expand` on it would turn the wildcard in `report[1].csv` into the existing
    -- `report1.csv` (which the export then overwrote), run backticks through the shell, ...
    reset()
    local out_dir = H.tmpdir()
    H.write(out_dir .. "/report1.csv", "precious\n")
    local export_state = { root = root, filter = {}, sort = "default" }
    local export_tasks = scan.all({ root = root })
    local delivered
    select_queue = { pick("File ... (CSV)") }
    input_queue = { out_dir .. "/report[1].csv" }
    dash.export(export_state, export_tasks, function(d)
      delivered = d
    end)
    eq(delivered, true, "the export went through: " .. said())
    eq(
      H.read(out_dir .. "/report1.csv"),
      "precious\n",
      "the file the wildcard matches is untouched"
    )
    has(H.read(out_dir .. "/report[1].csv") or "", "Task,Status", "the literal name was written")

    -- ── an unexpected error in a batch still ends the progress it started ──
    -- (a statusline progress that is never finished keeps its timer running for good)
    local core = require("tasks_nvim.ui.dash_core")
    local progress = require("lib.nvim.progress")
    local real_create, real_apply_set, real_apply_done =
      progress.create, core.apply_set, core.apply_done
    local finished = {}
    progress.create = function()
      return {
        update = function() end,
        finish = function(_, text)
          finished[#finished + 1] = text
        end,
      }
    end
    core.apply_set = function()
      error("engine exploded", 0)
    end
    core.apply_done = function()
      error("engine exploded again", 0)
    end
    local alpha_task = assert(scan.find("lib.nvim/alpha", { root = root }))
    local raised, raised_err = pcall(dash.cycle, export_state, { alpha_task }, "status")
    eq(raised, false, "the error still propagates")
    has(raised_err, "engine exploded")
    eq(#finished, 1, "but the progress of `s` was finished")
    yesno_answer = true
    local fin_raised, fin_err = pcall(dash.finish, export_state, { alpha_task }, function() end)
    eq(fin_raised, false)
    has(fin_err, "engine exploded again")
    eq(#finished, 2, "and the progress of `D` too")
    progress.create, core.apply_set, core.apply_done = real_create, real_apply_set, real_apply_done
  end)
  restore()
  if not ok_run then
    error(err, 0)
  end
end
