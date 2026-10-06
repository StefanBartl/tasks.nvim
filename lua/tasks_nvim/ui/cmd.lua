---@module 'tasks_nvim.ui.cmd'
---@brief The handlers behind `:Tasks list | task | open` -- prompts, notifications and windows around the task engine.
---@description
--- Every function takes the composer's `ctx` (`ctx.args`, `ctx.flags`,
--- `ctx.kv`, `ctx.rest`, `ctx.raw.fargs`) and does one command. The engine
--- (`tasks.*`) holds all the rules and returns data or `nil, err`; this module
--- adds what an editor needs: the `--to=` delivery, a form for a missing
--- title, a confirmation before a task is finished, opening files and
--- re-pointing buffers, and a picker over the files of one area folder.
---
--- Key responsibilities:
---  - `list` (`tasks`), `index`, `task_new`, `task_set`, `task_done`,
---    `task_template`, `task_open`, `task_preview`, `open_area` (`open`)
---  - `parse_assignments`: `key=value` tokens whose values may contain spaces
---  - `M.dashboard`: the seam to the interactive dashboard (`tasks_dash`)
---
--- Not its job: the route table and the argument types (`tasks_routes`), the
--- rendering (`tasks_view`), any rule about tasks (the engine).

local harvest = require("lib.nvim.harvest")
local notify = require("lib.nvim.notify").create("[tasks]")

local check = require("tasks_nvim.check")
local filter_opts = require("tasks_nvim.filter_opts")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local staleness = require("tasks_nvim.staleness")
local vault = require("tasks_nvim.vault")

local confirm = require("tasks_nvim.ui.confirm")
local done_flow = require("tasks_nvim.done_flow")
local soft = require("tasks_nvim.soft")
local view = require("tasks_nvim.ui.view")

local M = {}

---Dashboard seam. `:Tasks list` calls it instead of delivering a table
---when neither `--to=` nor `--format=` was given. It receives the filtered,
---sorted open tasks. `nil` (the default) means the interactive dashboard
---(`tasks_dash`); assign a function to replace it, or `false` for the old
---behaviour, a scratch buffer.
---@type (fun(view: Tasks.View): any)|false|nil
M.dashboard = nil

---@class Tasks.View
---@field tasks Tasks.Task[]     # Open tasks that passed the filter, sorted.
---@field area string|nil        # nil: every area.
---@field filter Tasks.Filter
---@field sort? string           # `model.SORTS` word the list was ordered by (default: the default order).
---@field root string          # Vault root.

---Longest detail list put into a notification; longer ones open a buffer.
local MAX_NOTIFY_LINES = 10

---The subfolders of an area `:Tasks folder` can show, relative to the area.
---@type table<string, string>
M.FOLDERS = {
  tasks = "ROADMAP/tasks",
  roadmap = "ROADMAP",
  backlog = "Backlog",
  handover = "handovers",
  notes = "NOTES",
  all = "",
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local same_path = fsio.same_path

---@param path string
---@param root string
---@return string
local function rel(path, root)
  local p = fsio.norm(path)
  if p:sub(1, #root + 1) == root .. "/" then
    return p:sub(#root + 2)
  end
  return p
end

---Notify a summary; the detail lines go along when few, into a scratch buffer
---when many.
---@param level "info"|"warn"|"error"
---@param summary string
---@param details? string[]
---@param title? string
local function report(level, summary, details, title)
  details = details or {}
  if #details == 0 then
    notify[level](summary)
  elseif #details <= MAX_NOTIFY_LINES then
    notify[level](summary .. "\n" .. table.concat(details, "\n"))
  else
    harvest.sink.scratch(table.concat(details, "\n") .. "\n", {
      title = title,
      filetype = "text",
      split = "split",
    })
    notify[level](summary)
  end
end

---@return string|nil root
local function vault_root()
  local root, err = vault.root()
  if not root then
    notify.error(tostring(err))
    return nil
  end
  return root
end

---Strip one pair of surrounding double quotes: the command line does not
---interpret them, so `"Fix the thing"` arrives as three tokens with quotes on
---the outer two.
---@param s string
---@return string
local function unquote(s)
  s = vim.trim(s)
  local inner = s:match('^"(.*)"$')
  return inner and vim.trim(inner) or s
end

---Refuse words a command has no use for. Ignoring them is the worse outcome: the command line
---splits at spaces, so `--to=file:C:/my dir/x.md` arrives as `--to=file:C:/my` plus the stray
---`dir/x.md`, and the export would be written to a file called `my`.
---@param ctx table  composer context
---@return boolean ok  # false: the error is reported, the command must stop
local function no_stray_words(ctx)
  local rest = ctx.rest
  if rest == nil or #rest == 0 then
    return true
  end
  local to = ctx.flags and ctx.flags.to
  local hint = ""
  if type(to) == "string" and to:sub(1, 5) == "file:" then
    hint = " (put a backslash before each space of the --to=file: path)"
  end
  notify.error("unexpected argument: " .. table.concat(rest, " ") .. hint)
  return false
end

---Reload unchanged buffers of `path` after the file changed on disk.
---@param path string
local function refresh_buffers(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and not vim.bo[buf].modified
      and same_path(vim.api.nvim_buf_get_name(buf), path)
    then
      pcall(vim.cmd, "checktime " .. buf)
    end
  end
end

M.refresh_buffers = refresh_buffers

---Move windows showing `from` to `to` after a task file was moved, and drop
---the old buffer, so no buffer is left on a dead path (what `:File move` of
---fileops.nvim does for its own moves). A modified buffer is left alone.
---@param from string
---@param to string
function M.retarget_buffers(from, to)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and same_path(vim.api.nvim_buf_get_name(buf), from) then
      if vim.bo[buf].modified then
        notify.warn("buffer for the finished task has unsaved changes and still points at " .. from)
      else
        -- `edit` can refuse (a window with 'winfixbuf': E1513). The task is already finished on disk by now,
        -- so a refusal must not raise out of the command and eat its own report: it is collected and said.
        local refused = 0
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          local moved = pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("silent keepalt edit " .. vim.fn.fnameescape(to))
          end)
          if not moved then
            refused = refused + 1
          end
        end
        if refused > 0 then
          notify.warn(
            ("%d window(s) could not be moved to %s and still show the old file (it moved)"):format(
              refused,
              to
            )
          )
        else
          pcall(vim.api.nvim_buf_delete, buf, {})
        end
      end
    end
  end
end

---@param path string
local function open_file(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    notify.error(("cannot open %s: %s"):format(path, tostring(err)))
  end
end
M.open_file = open_file

---Describe the active filter for the table heading.
---@param flags table
---@return string|nil
local function filter_note(flags)
  local parts = {}
  for _, name in ipairs({
    "status",
    "prio",
    "effort",
    "kind",
    "category",
    "severity",
    "value",
    "actor",
    "tag",
  }) do
    if flags[name] ~= nil then
      parts[#parts + 1] = ("%s=%s"):format(name, flags[name])
    end
  end
  if flags.stale == "refs" then
    parts[#parts + 1] = "stale=refs"
  elseif flags.stale ~= nil then
    parts[#parts + 1] = "stale>=" .. tostring(flags.stale) .. "d"
  end
  if flags.blocked then
    parts[#parts + 1] = "blocked"
  end
  for _, name in ipairs({ "ready", "waiting", "unestimated" }) do
    if flags[name] then
      parts[#parts + 1] = name
    end
  end
  if #parts == 0 then
    return nil
  end
  return "Filter: " .. table.concat(parts, ", ")
end

-- ── tasks ────────────────────────────────────────────────────────────────────

---The filter flags the list-like commands share, as `filter_opts` wants them.
---@param flags table
---@return table
local function filter_options(flags)
  return {
    status = flags.status,
    prio = flags.prio,
    effort = flags.effort,
    kind = flags.kind,
    category = flags.category,
    severity = flags.severity,
    value = flags.value,
    actor = flags.actor,
    tag = flags.tag,
    stale = flags.stale,
    blocked = flags.blocked,
    unestimated = flags.unestimated,
  }
end

---The scope of `plan` and `estimate` from the command: area (or `all`), `--for=<id>`, the filters.
---@param ctx table
---@return Tasks.PlanScope|nil scope
local function load_scope(ctx)
  local flags = ctx.flags
  local filter, ferr = filter_opts.parse(filter_options(flags))
  if not filter then
    notify.error(tostring(ferr))
    return nil
  end
  local root = vault_root()
  if not root then
    return nil
  end
  filter.ref_opts = { root = root }
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local scope, err = require("tasks_nvim.plan_scope").load({
    root = root,
    area = area,
    for_id = flags["for"],
    plan_id = flags.plan,
    filter = filter,
  })
  if not scope then
    notify.error(tostring(err))
    return nil
  end
  if #scope.errors > 0 then
    notify.warn("cannot read directory " .. table.concat(scope.errors, ", "))
  end
  return scope
end

---`:Tasks plan [<area>|all] [--for=<id>] [filters] [--ready] [--format=md|tsv|ids] [--to=] [--force]`
---@param ctx table  composer context
function M.plan(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags
  local target, terr = view.parse_target(flags.to)
  if terr then
    notify.error(terr)
    return
  end
  local format = flags.format or "md"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    notify.error("--format must be md, tsv or ids")
    return
  end
  local scope = load_scope(ctx)
  if not scope then
    return
  end
  local plan_view = require("tasks_nvim.plan_view")
  if flags.write then
    return M.write_plan_block(ctx, scope)
  end
  if flags.check then
    notify.error("--check goes with --write=<file>")
    return
  end
  local text
  if format == "md" then
    text = plan_view.markdown(scope.plan, {
      title = scope.title,
      today = model.today(),
      done = scope.done,
      ready_only = flags.ready == true,
      with_steps = flags["with-steps"] == true,
      plan_file = scope.plan_file,
    })
  elseif format == "tsv" then
    text = table.concat(plan_view.tsv(scope.plan, { ready_only = flags.ready == true }), "\n")
      .. "\n"
  else
    text = table.concat(plan_view.ids(scope.plan, { ready_only = flags.ready == true }), "\n")
      .. "\n"
  end
  local ok, err = view.deliver_text(text, target, {
    force = flags.force,
    title = "tasks/plan/" .. scope.title:gsub("[^%w._-]+", "-"),
    filetype = format == "md" and "markdown" or "text",
  })
  if not ok then
    notify.error(tostring(err))
    return
  end
  notify.info(
    ("plan of %s: %d task(s), %d ready"):format(scope.title, #scope.tasks, #scope.plan.ready)
  )
end

---`:Tasks plan --write=<file> [--scope=<name>] [--check]`: replace only the generated block of the scope in a
---hand-written document; `--check` writes nothing and says whether it is out of date.
---@param ctx table
---@param scope Tasks.PlanScope
function M.write_plan_block(ctx, scope)
  local flags = ctx.flags
  local plan_view = require("tasks_nvim.plan_view")
  local path = fsio.doc_path(flags.write)
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local key = flags.scope
    or plan_view.default_scope({ area = area, for_id = flags["for"], plan_id = flags.plan })
  -- The marker records how the block was made (target, view, filters): the refresh after a finish builds the same.
  local plan_scope = require("tasks_nvim.plan_scope")
  local attrs, aerr = plan_scope.marker_attrs(
    filter_options(flags),
    { ready = flags.ready == true, steps = flags["with-steps"] == true },
    { area = area, plan_id = flags.plan, for_id = flags["for"] },
    key
  )
  if not attrs then
    notify.error(tostring(aerr))
    return
  end
  local res, err =
    plan_scope.write_block(path, scope, { key = key, attrs = attrs, check = flags.check })
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.state == "stale" then
    notify.warn(("the block `%s` in %s is out of date"):format(key, path))
  elseif res.state == "current" then
    notify.info(("the block `%s` in %s is current"):format(key, path))
  elseif res.state == "unchanged" then
    notify.info(("block `%s` in %s: unchanged"):format(key, path))
  else
    refresh_buffers(path)
    notify.info(("block `%s` in %s updated"):format(key, path))
  end
end

---`:Tasks planfile <area> <title...> [--areas=] [--phases=] [--gate=hard] [--target=] [--status=]`
---@param ctx table
function M.planfile(ctx)
  local flags = ctx.flags
  local title = unquote(table.concat(ctx.rest, " "))
  if title == "" then
    notify.error("a plan needs a title: :Tasks planfile <area> <title...>")
    return
  end
  local res, err = require("tasks_nvim.plans").new(ctx.args.area, {
    title = title,
    areas = flags.areas,
    phases = flags.phases,
    gate = flags.gate,
    target = flags.target,
    status = flags.status,
  })
  if not res then
    notify.error(tostring(err))
    return
  end
  notify.info(("created plan %s"):format(res.id))
  open_file(res.path)
end

---Walk the tasks that miss an effort or a value and ask for them one by one; everything given is written in ONE
---batch at the end (an index write per area). `Skip` leaves a field out, `Stop` ends the walk and keeps what was given.
---@param tasks Tasks.Task[]
local function walk_estimates(tasks)
  local queue = {}
  for _, t in ipairs(tasks) do
    if t.value == nil or model.effort_days(t.effort) == nil then
      queue[#queue + 1] = t
    end
  end
  if #queue == 0 then
    notify.info("every task has an effort and a value")
    return
  end
  local ask = M.chooser or confirm.choose
  local steps = {}

  local function finish()
    if #steps == 0 then
      notify.info("estimate: nothing given, nothing changed")
      return
    end
    local res = require("tasks_nvim.batch").set_many(steps, {})
    local level, text = require("tasks_nvim.ui.dash_core").describe_set("estimate", res)
    notify[level](text)
  end

  local function visit(i)
    local t = queue[i]
    if not t then
      finish()
      return
    end
    local patch = {}
    local function done_task()
      if next(patch) then
        steps[#steps + 1] = { id = t.id, patch = patch }
      end
      visit(i + 1)
    end
    -- `Stop`, and a dialog that was dismissed (Esc, `q`): the walk ends HERE; what was given so far is kept and
    -- written, not dropped without a word.
    local function stop_here()
      if next(patch) then
        steps[#steps + 1] = { id = t.id, patch = patch }
      end
      finish()
    end
    local function ask_value()
      if t.value ~= nil then
        done_task()
        return
      end
      local msg = ("%s -- %s\n\nValue (1 = little, 5 = a lot)  [%d of %d]"):format(
        t.id,
        confirm.shorten(t.title, 60),
        i,
        #queue
      )
      ask(msg, { "Skip", "Stop", "1", "2", "3", "4", "5" }, function(pos)
        if pos == nil or pos == 2 then
          stop_here()
          return
        end
        if pos >= 3 then
          patch.value = tostring(pos - 2)
        end
        done_task()
      end)
    end
    if model.effort_days(t.effort) ~= nil then
      ask_value()
      return
    end
    local msg = ("%s -- %s\n\nEffort  [%d of %d]"):format(
      t.id,
      confirm.shorten(t.title, 60),
      i,
      #queue
    )
    ask(msg, { "Skip", "Stop", "XS", "S", "M", "L", "XL" }, function(pos)
      if pos == nil or pos == 2 then
        stop_here()
        return
      end
      if pos >= 3 then
        patch.effort = ({ "XS", "S", "M", "L", "XL" })[pos - 2]
      end
      ask_value()
    end)
  end
  visit(1)
end

---Replaces the dialog of `estimate --walk` (specs): `function(msg, choices, cb)`.
---@type (fun(msg: string, choices: string[], cb: fun(index: integer|nil)))|nil
M.chooser = nil

---`:Tasks estimate [<area>|all] [--for=<id>] [filters] [--walk]`
---@param ctx table  composer context
function M.estimate(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local scope = load_scope(ctx)
  if not scope then
    return
  end
  local estimate = require("tasks_nvim.estimate")
  local sums = estimate.rollup(scope.tasks, { done = scope.done })
  local lines = { scope.title .. ": " .. estimate.describe(sums) }
  if #sums.quick_wins > 0 then
    lines[#lines + 1] = "Quick wins: " .. table.concat(sums.quick_wins, ", ")
  end
  if #sums.unestimated > 0 then
    lines[#lines + 1] = ("%d task(s) miss an effort or a value (:Tasks estimate --walk goes through them)"):format(
      #sums.unestimated
    )
  end
  notify.info(table.concat(lines, "\n"))
  if ctx.flags.walk then
    walk_estimates(scope.tasks)
  end
end

---`:Tasks next [<area>|all] [--n=3] [--actor=]`
---@param ctx table  composer context
function M.next(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags
  local count = 3
  if flags.n ~= nil then
    local n = tonumber(flags.n)
    if not n or n < 1 or n % 1 ~= 0 then
      notify.error("--n must be a whole number of at least 1, got " .. tostring(flags.n))
      return
    end
    count = n
  end
  if flags.actor and not (model.is_actor(flags.actor) or flags.actor == "none") then
    notify.error(
      "unknown actor in --actor: " .. tostring(flags.actor) .. " (expected cdx, me, pair or none)"
    )
    return
  end
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local root = vault_root()
  if not root then
    return
  end
  local pick, err = require("tasks_nvim.next_pick").pick_from_vault({
    root = root,
    area = area,
    actor = flags.actor,
    n = count - 1,
  })
  if not pick then
    notify.error(tostring(err))
    return
  end
  if pick.incomplete then
    notify.warn(
      "cannot read directory "
        .. table.concat(pick.incomplete, ", ")
        .. " (the answer may be incomplete)"
    )
  end
  require("tasks_nvim.ui.next_popup").show(pick, nil)
end

---`:Tasks list [<area>|all] [filters] [--to=] [--format=]`
---@param ctx table  composer context
function M.list(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags
  local target, terr = view.parse_target(flags.to)
  if terr then
    notify.error(terr)
    return
  end
  local filter, ferr = filter_opts.parse({
    status = flags.status,
    prio = flags.prio,
    effort = flags.effort,
    kind = flags.kind,
    category = flags.category,
    severity = flags.severity,
    value = flags.value,
    actor = flags.actor,
    tag = flags.tag,
    stale = flags.stale,
    blocked = flags.blocked,
    unestimated = flags.unestimated,
  })
  if not filter then
    notify.error(tostring(ferr))
    return
  end
  local order, oerr = model.parse_sort(flags.sort)
  if not order then
    notify.error(tostring(oerr))
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  filter.ref_opts = { root = root }

  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local open, skipped, errors = scan.open_tasks({ root = root, area = area })
  if not open then
    notify.error(tostring(skipped))
    return
  end
  if #errors > 0 then
    notify.warn("cannot read directory " .. table.concat(errors or {}, ", "))
  end
  local filtered, stale_report = model.filter(open, filter)
  if flags.ready or flags.waiting then
    if flags.ready and flags.waiting then
      notify.error("--ready and --waiting exclude each other")
      return
    end
    -- carried in the filter: the dashboard rescans (live refresh, `r`, a re-sort) and applies the same cut
    filter.readiness = flags.ready and "ready" or "waiting"
    local kept, kerr =
      require("tasks_nvim.plan_scope").filter_readiness(filtered, filter.readiness, root)
    if not kept then
      notify.error(tostring(kerr))
      return
    end
    filtered = kept
  end
  local shown = model.sort(filtered, order)
  local ref_note = nil
  if filter.stale_refs then
    -- The second result of `model.filter` is the report: name the files that changed.
    if stale_report then
      local lines = {}
      for _, t in ipairs(shown) do
        lines[#lines + 1] = ("%s: %s"):format(
          t.id,
          staleness.describe(stale_report.stale[t.id] or {}, 3)
        )
      end
      ref_note = #lines > 0 and ("Changed since updated: " .. table.concat(lines, " | ")) or nil
      for _, n in ipairs(stale_report.notes) do
        notify.warn(n)
      end
      notify.info(
        ("--stale=refs: %d file(s) of %d task(s) checked, %d ref(s) found nowhere, %d skipped"):format(
          stale_report.files,
          stale_report.tasks,
          stale_report.unresolved,
          stale_report.skipped
        )
      )
    end
  end
  if skipped > 0 then
    notify.warn(
      ("%d task file(s) not listed (missing or unknown status, or done); run :Tasks index --check"):format(
        skipped
      )
    )
  end

  if flags.to == nil and flags.format == nil then
    local dash = M.dashboard
    if dash == nil then
      dash = function(v)
        return require("tasks_nvim.ui.dash").open(v)
      end
    end
    if dash then
      dash({
        tasks = shown,
        area = area,
        filter = filter,
        sort = flags.sort ~= nil and order or nil,
        root = root,
      })
      return
    end
  end
  if #shown == 0 then
    notify.info("no open task matches")
    return
  end

  local label = area or "alle Bereiche"
  local ok, err = view.deliver(shown, target, {
    force = flags.force,
    format = flags.format,
    heading = ("Offene Tasks — %s (%d)"):format(label, #shown),
    note = (function()
      local base = filter_note(flags)
      if ref_note then
        return base and (base .. "\n\n" .. ref_note) or ref_note
      end
      return base
    end)(),
    title = "tasks://tasks/" .. (area or "all"),
  })
  if not ok then
    notify.error(("cannot deliver the task list: %s"):format(tostring(err)))
    return
  end
  notify.info(("%d open task(s) -> %s"):format(#shown, flags.to or "buffer"))
end

---`:Tasks index [<area>] [--all] [--check]`
---@param ctx table
function M.index(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local area = ctx.args.area
  if ctx.flags.all then
    area = nil
  end

  if ctx.flags.check then
    local res, err = check.run({ root = root, area = area })
    if not res then
      notify.error(tostring(err))
      return
    end
    local lines = {}
    for _, f in ipairs(res.findings) do
      lines[#lines + 1] = check.format(f, root)
    end
    local summary = ("tasks check: %d finding(s) (%d error, %d warning) in %d area(s), %d task file(s) read"):format(
      #res.findings,
      res.errors,
      res.warnings,
      res.areas,
      res.tasks
    )
    local level = (not res.ok) and "error" or (res.warnings > 0 and "warn" or "info")
    report(level, summary, lines, "tasks://tasks-check")
    return
  end

  local results, errors
  if area then
    local res, err = index.write_area(area, { root = root })
    results = res and { res } or {}
    errors = err and { area .. ": " .. err } or {}
  else
    results, errors = index.write_all({ root = root })
  end
  if not results then
    notify.error(tostring(errors[1]))
    return
  end
  local counts = { written = 0, removed = 0, unchanged = 0, stale = 0 }
  local lines = {}
  for _, r in ipairs(results) do
    counts[r.action] = counts[r.action] + 1
    if r.action ~= "unchanged" then
      lines[#lines + 1] = ("%s  %s  (%d open)"):format(r.action, rel(r.path, root), r.open)
    end
  end
  for _, e in ipairs(errors) do
    lines[#lines + 1] = "error  " .. e
  end
  local summary = ("tasks index: %d area(s), %d written, %d removed, %d unchanged, %d error(s)"):format(
    #results,
    counts.written,
    counts.removed,
    counts.unchanged,
    #errors
  )
  report(#errors > 0 and "error" or "info", summary, lines, "tasks://tasks-index")
end

-- ── task new ─────────────────────────────────────────────────────────────────

---Ask for the fields a `task new` call did not carry. Uses `ui.kit.form`
---(ui.nvim) when it is installed, else a chain of `vim.ui.input` prompts.
---`cb(nil)` means cancelled; otherwise a map of the non-empty answers.
---@param given table<string, string>  kv values already supplied
---@param cb fun(values: table<string, string>|nil)
function M.ask_new_fields(given, cb)
  ---@type { name: string, label: string, required?: boolean, default?: string }[]
  local fields = { { name = "title", label = "Title", required = true } }
  if not given.kind then
    fields[#fields + 1] = {
      name = "kind",
      label = "Kind (" .. table.concat(model.KINDS, "|") .. ")",
      default = "task",
    }
  end
  if not given.prio then
    fields[#fields + 1] = { name = "prio", label = "Prio (1|2|3, empty: none)" }
  end
  if not given.effort then
    fields[#fields + 1] = { name = "effort", label = "Effort (XS|S|M|L|XL|0.5d, empty: none)" }
  end

  ---@param raw table<string, string>
  local function finish(raw)
    local values = {}
    for k, v in pairs(raw) do
      local t = vim.trim(v or "")
      if t ~= "" then
        values[k] = t
      end
    end
    cb(values)
  end

  local kit = soft.require("ui.kit", { "form" })
  if kit then
    kit.form({
      fields = fields,
      on_submit = finish,
      on_cancel = function()
        cb(nil)
      end,
    })
    return
  end

  local answers = {}
  local function step(i)
    local field = fields[i]
    if not field then
      finish(answers)
      return
    end
    vim.ui.input({ prompt = field.label .. ": ", default = field.default }, function(value)
      if value == nil then
        if field.required then
          cb(nil)
          return
        end
        value = field.default or ""
      end
      answers[field.name] = value
      step(i + 1)
    end)
  end
  step(1)
end

---Form seam: `:Tasks new` without arguments calls it instead of
---opening the form buffer of `tasks_form`. Same signature as `tasks_form.open`.
---@type (fun(opts: table): any)|nil
M.form_open = nil

---Explorer seam: shows a folder after a task with assets was created.
---`nil` means filetree.nvim (`:Filetree open`), else the built-in `:edit <dir>`.
---@type (fun(dir: string): any)|nil
M.explorer_open = nil

---Open `dir` in a file explorer: filetree.nvim when its command exists, else
---Neovim's own directory browser.
---@param dir string
local function open_explorer(dir)
  if M.explorer_open then
    M.explorer_open(dir)
    return
  end
  if vim.fn.exists(":Filetree") == 2 then
    -- Table form: the argument reaches the command as one word, no `fnameescape` backslashes to undo.
    local ok = pcall(vim.cmd, { cmd = "Filetree", args = { "open", dir } })
    if ok then
      return
    end
  end
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape(dir))
end

---The form flow of `:Tasks new` without arguments: a Markdown form
---(`tasks.form`), then the question "attach assets?", then `mutate.new` -- the
---one write path the CLI uses too. A failure shows in the form, which stays
---open with everything typed; cancelling creates nothing.
---@param given table<string, string>  kv values from the command line, pre-ticked
function M.task_new_form(given)
  local root = vault_root()
  if not root then
    return
  end
  local areas = {}
  for _, a in ipairs(vault.areas(root)) do
    areas[#areas + 1] = a.name
  end
  local ticks = {}
  for _, key in ipairs({ "kind", "prio", "effort", "value", "actor", "severity", "status" }) do
    ticks[key] = given[key]
  end
  if given.category then
    ticks.category = vim.split(given.category, ",", { trimempty = true })
  end

  local ui = require("tasks_nvim.ui.form")
  local open = M.form_open or ui.open
  -- No "busy" flag: a second `<C-s>` only reopens the dialog (the kit holds one at a time and calls back only
  -- on an answer), whereas a flag that waited for a callback stayed set when the dialog was closed from outside.
  open({
    areas = areas,
    title = given.title,
    tags = given.tags,
    refs = given.refs,
    ticks = ticks,
    on_cancel = function()
      notify.info("task new cancelled")
    end,
    on_submit = function(values, buf)
      confirm.yesno(
        "Attach assets (screenshots, logs) to the new task?\n\nYes makes a folder task with an assets/ folder and opens the file explorer on it.",
        "attach assets",
        function(with_assets)
          -- after=/order=/plan=/phase= are no fields of the form: they go on as they were typed on the command line
          local carried =
            { after = given.after, order = given.order, plan = given.plan, phase = given.phase }
          local opts = vim.tbl_extend("force", carried, values.opts, { folder = with_assets })
          local res, err = mutate.new(values.area, opts)
          if not res then
            if buf and vim.api.nvim_buf_is_valid(buf) then
              ui.show_errors(buf, { tostring(err) })
            else
              notify.error(tostring(err))
            end
            return
          end
          if buf then
            ui.close(buf)
          end
          if res.index_err then
            notify.warn("task created, but the index was not updated: " .. res.index_err)
          end
          notify.info(("created %s"):format(res.id))
          open_file(res.path)
          if with_assets then
            local assets = vim.fs.dirname(res.path) .. "/" .. mutate.ASSETS_DIR
            local made, merr = fsio.mkdirp(assets)
            if made then
              open_explorer(assets)
            else
              notify.warn(
                ("task created, but %s could not be created: %s"):format(assets, tostring(merr))
              )
            end
          end
        end
      )
    end,
  })
end

---The code a range names: `:'<,'>Tasks new` (from a visual selection or any `:5,10Tasks new`) makes a task about
---those lines. `ref` is the buffer's file relative to the working directory plus the first line (`lua/a.lua:5`, a
---ref the staleness check understands), `text` the first non-blank line, squeezed and cut, for a title nobody typed.
---@param ctx table  composer context; `ctx.range = { range, line1, line2 }`
---@param buf? integer  default: the current buffer
---@return { ref?: string, text?: string }|nil source  # nil: no range given
function M.range_source(ctx, buf)
  local r = ctx.range
  if not r or (r.range or 0) == 0 then
    return nil
  end
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local first_line = math.max(1, math.min(r.line1 or 1, last))
  local last_line = math.max(first_line, math.min(r.line2 or first_line, last))
  local source = {}
  local name = vim.api.nvim_buf_get_name(buf)
  -- A real file only: `term://`, `tasks://` and the like name no path a ref could point at.
  if name ~= "" and not name:match("^%a[%w+.-]*://") and vim.bo[buf].buftype == "" then
    source.ref = ("%s:%d"):format(fsio.norm(vim.fn.fnamemodify(name, ":.")), first_line)
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false)) do
    local squeezed = vim.trim((line:gsub("%s+", " ")))
    if squeezed ~= "" then
      source.text = vim.fn.strcharpart(squeezed, 0, 80)
      break
    end
  end
  return source
end

---`:Tasks new [<area> [title...]] [kind= prio= effort= tags= status=]`. With a range, the task is about those lines:
---it gets a `refs:` entry for them, and the first selected line as its title when none was typed.
---@param ctx table
function M.task_new(ctx)
  local area = ctx.args.area
  local source = M.range_source(ctx)
  if area == nil or area == "" then
    local given = {}
    for _, key in ipairs({
      "kind",
      "prio",
      "effort",
      "value",
      "actor",
      "tags",
      "category",
      "severity",
      "status",
      -- not fields of the form: carried through to `mutate.new` as they were typed
      "after",
      "order",
      "plan",
      "phase",
    }) do
      if ctx.kv[key] ~= nil and ctx.kv[key] ~= "" then
        given[key] = ctx.kv[key]
      end
    end
    if source then
      given.refs, given.title = source.ref, source.text
    end
    M.task_new_form(given)
    return
  end
  local title = unquote(table.concat(ctx.rest, " "))
  if title == "" and source and source.text then
    title = source.text
  end
  local given = {}
  for _, key in ipairs({
    "kind",
    "prio",
    "effort",
    "value",
    "actor",
    "after",
    "order",
    "plan",
    "phase",
    "tags",
    "category",
    "severity",
    "status",
  }) do
    if ctx.kv[key] ~= nil and ctx.kv[key] ~= "" then
      given[key] = ctx.kv[key]
    end
  end

  ---@param values table<string, string>
  local function create(values)
    local res, err = mutate.new(area, {
      title = values.title,
      kind = values.kind,
      prio = values.prio,
      effort = values.effort,
      tags = values.tags,
      category = values.category,
      severity = values.severity,
      value = values.value,
      actor = values.actor,
      after = values.after,
      order = values.order,
      plan = values.plan,
      phase = values.phase,
      status = values.status,
      -- a list: a string would be split at the commas of a file name (`a,b.lua`)
      refs = source and source.ref and { source.ref } or nil,
      folder = ctx.flags.folder == true,
    })
    if not res then
      notify.error(tostring(err))
      return
    end
    if res.index_err then
      notify.warn("task created, but the index was not updated: " .. res.index_err)
    end
    notify.info(("created %s"):format(res.id))
    open_file(res.path)
  end

  if title ~= "" then
    create(vim.tbl_extend("force", given, { title = title }))
    return
  end
  M.ask_new_fields(given, function(values)
    if not values then
      notify.info("task new cancelled")
      return
    end
    if not values.title then
      notify.warn("no title given, nothing created")
      return
    end
    create(vim.tbl_extend("force", given, values))
  end)
end

-- ── task set ─────────────────────────────────────────────────────────────────

---Turn `key=value` tokens into a patch. A value may contain spaces: a token
---that does not start with a known `key=` continues the value before it, so
---`title=Fix the thing status=doing` sets two keys. An empty value (`kind=`)
---removes the key.
---@param tokens string[]
---@param known string[]  accepted keys
---@return table<string, any>|nil patch
---@return string|nil err
function M.parse_assignments(tokens, known)
  local is_known = {}
  for _, k in ipairs(known) do
    is_known[k] = true
  end
  ---@type { key: string, words: string[] }[]
  local items = {}
  for _, tok in ipairs(tokens) do
    local key, value = tok:match("^([%a_][%w_]*)=(.*)$")
    if key and is_known[key] then
      items[#items + 1] = { key = key, words = { value } }
    elseif #items > 0 then
      local words = items[#items].words
      words[#words + 1] = tok
    elseif key then
      return nil, ("unknown field '%s' (settable: %s)"):format(key, table.concat(known, ", "))
    else
      return nil, ("expected key=value, got '%s'"):format(tok)
    end
  end
  if #items == 0 then
    return nil, "nothing to set (expected key=value ...)"
  end
  local patch = {}
  for _, item in ipairs(items) do
    if patch[item.key] ~= nil then
      return nil, ("'%s' given twice"):format(item.key)
    end
    local text = vim.trim(table.concat(item.words, " "))
    patch[item.key] = text == "" and mutate.REMOVE or unquote(text)
  end
  return patch, nil
end

---`:Tasks set <id> key=value ...`
---@param ctx table
function M.task_set(ctx)
  local fargs = ctx.raw.fargs or {}
  local tokens = {}
  for i = #ctx.path + 2, #fargs do
    tokens[#tokens + 1] = fargs[i]
  end
  local patch, perr = M.parse_assignments(tokens, mutate.SETTABLE)
  if not patch then
    notify.error(tostring(perr))
    return
  end
  local res, err = mutate.set(ctx.args.id, patch)
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.index_err then
    notify.warn("task changed, but the index was not updated: " .. res.index_err)
  end
  if res.changed then
    refresh_buffers(res.path)
  end
  notify.info(("set %s: %s"):format(res.id, res.changed and "changed" or "unchanged"))
end

-- ── task done ────────────────────────────────────────────────────────────────

---What a finish leaves to say: the tasks that still read `blocked` although this was their last blocker (offered to be
---set to open, with a question, never silently), then the next task. Needs somebody to answer; a headless session
---only gets the next-task message.
---@param flow { next?: Tasks.NextPick, plans_closed?: string[], plan_summaries?: table<string, table> }
---@param id string
function M.after_finish(flow, id)
  local nxt = flow.next
  if not nxt then
    return
  end
  local show = function()
    require("tasks_nvim.ui.next_popup").show(nxt, id, flow)
  end
  if #nxt.freed_blocked > 0 and #vim.api.nvim_list_uis() > 0 then
    local names = table.concat(nxt.freed_blocked, "\n")
    confirm.yesno(
      ("These tasks waited only on %s and still say blocked:\n\n%s\n\nSet them to open?"):format(
        id,
        names
      ),
      "set to open",
      function(yes)
        if yes then
          local steps = {}
          for _, task_id in ipairs(nxt.freed_blocked) do
            steps[#steps + 1] = { id = task_id, patch = { status = "open" } }
          end
          local res = require("tasks_nvim.batch").set_many(steps, {})
          local level, text = require("tasks_nvim.ui.dash_core").describe_set("status", res)
          notify[level](text)
        end
        show()
      end
    )
    return
  end
  show()
end

---@param id string
---@param opts { done_in?: string, date?: string }
local function finish_task(id, opts)
  local flow, err = done_flow.run(id, { done_in = opts.done_in, date = opts.date })
  if not flow then
    notify.error(tostring(err))
    return
  end
  local res = flow.done
  if res.already then
    notify.info(("%s is already finished (%s)"):format(id, res.to))
    return
  end
  M.retarget_buffers(res.from, res.to)
  if res.index_err then
    notify.warn("task finished, but the index was not updated: " .. res.index_err)
  end
  if res.readme == "missing" then
    notify.warn("Backlog/README.md does not exist: no row added for the finished task")
  end
  local root = vault.root()
  notify.info(("done %s -> %s"):format(id, root and rel(res.to, root) or res.to))
  if flow.steps_ticked > 0 then
    notify.info(
      ("%d plan step%s ticked off"):format(flow.steps_ticked, flow.steps_ticked == 1 and "" or "s")
    )
  end
  for _, doc in ipairs(flow.docs_refreshed) do
    notify.info("plan block refreshed in " .. doc)
  end
  for _, note in ipairs(flow.notes) do
    notify.warn(("%s: %s"):format(id, note))
  end
  M.after_finish(flow, id)
end

---Finish a task with the messages and the dialog of `:Tasks done` (without the confirmation: the caller asked).
---@param id string
---@param opts? { done_in?: string, date?: string }
function M.finish(id, opts)
  finish_task(id, opts or {})
end

---`:Tasks folderize <id>`
---@param ctx table
function M.task_folderize(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local before = scan.find(ctx.args.id)
  local res, err = mutate.folderize(ctx.args.id)
  if not res then
    notify.error(tostring(err))
    return
  end
  if not res.changed then
    notify.info(("%s is already a folder task"):format(res.id))
    return
  end
  if before then
    M.retarget_buffers(before.path, res.path)
  end
  if res.index_err then
    notify.warn("task moved, but the index was not updated: " .. res.index_err)
  end
  notify.info(("%s is now a folder task"):format(res.id))
end

---`:Tasks attach <id> <file> [name=<file name>]`: copy the file into
---`assets/`, put the Markdown link in the `+` register and say so.
---@param ctx table
function M.task_attach(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local before = scan.find(ctx.args.id)
  -- The composer's FILE type has resolved `~` and variables already (and checked the file is
  -- there). A second `vim.fn.expand` would read `[1]` in `shot[1].png` as a wildcard (attaching
  -- `shot1.png` instead) and run a backtick in a downloaded file's name through the shell.
  local res, err = mutate.attach(
    ctx.args.id,
    vim.fn.fnamemodify(ctx.args.file, ":p"),
    { name = ctx.kv.name ~= "" and ctx.kv.name or nil }
  )
  if not res then
    -- The engine speaks CLI (`--name=`); here the same option is `name=<file name>`.
    notify.error((tostring(err):gsub("pass %-%-name=", "pass name=<file name>")))
    return
  end
  if res.folderized and before then
    M.retarget_buffers(before.path, res.path)
  end
  if res.index_err then
    notify.warn("asset attached, but the index was not updated: " .. res.index_err)
  end
  if res.updated_err then
    notify.warn("asset attached, but `updated` was not changed: " .. res.updated_err)
  end
  local copied = pcall(vim.fn.setreg, "+", res.link)
  notify.info(
    ("attached %s -> %s%s"):format(
      res.id,
      res.rel,
      copied and (" (link copied: " .. res.link .. ")") or (": " .. res.link)
    )
  )
end

---`:Tasks done <id> [done_in=...] [date=YYYY-MM-DD] [--yes]`
---@param ctx table
function M.task_done(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local id = ctx.args.id
  local opts = { done_in = ctx.kv.done_in, date = ctx.kv.date }
  local task = scan.find(id)
  if not task or ctx.flags.yes then
    -- A finished task answers "already" without asking anything.
    finish_task(id, opts)
    return
  end
  local bucket = vault.BUCKET_OF_KIND[task.kind or "task"] or "?"
  local date = opts.date or model.today()
  confirm.yesno(
    ("Finish task %s?\n\n%s\n\nIt moves to Backlog/%s/%s_%s%s."):format(
      id,
      confirm.shorten(task.title, 70),
      bucket,
      date,
      task.slug,
      task.folder and " (the whole folder)" or ".md"
    ),
    "finish",
    function(accepted)
      if not accepted then
        notify.info("cancelled -- the task stays open")
        return
      end
      finish_task(id, opts)
    end
  )
end

-- ── task template / open ─────────────────────────────────────────────────────

---`:Tasks template [--to=clipboard|buffer|file:<path>]`
---@param ctx table
function M.task_template(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local target, terr = view.parse_target(ctx.flags.to or "clipboard")
  if terr or not target or target.kind == "qf" then
    notify.error(terr or "--to=qf makes no sense for the template")
    return
  end
  local blocked = view.overwrite_guard(target, ctx.flags.force)
  if blocked then
    notify.error(blocked .. " (pass --force to overwrite it)")
    return
  end
  local text = mutate.template({ with_plan = ctx.flags["with-plan"] == true })
  local ok, err = harvest.emit(text, target.kind, {
    path = target.path,
    title = "tasks://task-template",
    filetype = "markdown",
  })
  if not ok then
    if target.kind == "clipboard" then
      harvest.sink.scratch(text, { title = "tasks://task-template", filetype = "markdown" })
      notify.warn(("no clipboard (%s): the template is in a buffer instead"):format(tostring(err)))
      return
    end
    notify.error(tostring(err))
    return
  end
  if target.kind == "clipboard" then
    notify.info("task template copied to the + register")
  else
    notify.info("task template -> " .. target.kind)
  end
end

---`:Tasks open <id>` -- an open task, else its finished copy in `Backlog/`.
---@param ctx table
function M.task_open(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local id = ctx.args.id
  local task, find_err = scan.find(id)
  task = task or scan.find_done(id)
  if not task then
    notify.error(find_err or ("no such task: " .. id))
    return
  end
  open_file(task.path)
end

---`:Tasks preview <id>` -- the task file (an open one, else its finished
---copy) rendered in the browser by mdview.nvim; read-only for the vault.
---@param ctx table
function M.task_preview(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local id = ctx.args.id
  local task, find_err = scan.find(id)
  task = task or scan.find_done(id)
  if not task then
    notify.error(find_err or ("no such task: " .. id))
    return
  end
  local ok, err = require("tasks_nvim.ui.preview").open_file(task.path)
  if not ok then
    notify.warn(("cannot preview %s: %s"):format(id, tostring(err)))
    return
  end
  notify.info("previewing " .. id .. " in the browser")
end

-- ── open <area> <folder> ─────────────────────────────────────────────────────

---Markdown files below `dir`, relative to it, sorted.
---@param dir string
---@return string[]
local function markdown_below(dir)
  local out = {}
  for _, p in ipairs((require("lib.nvim.fs.collect_recursive").files(dir))) do
    local n = fsio.norm(p)
    if n:match("%.md$") then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

---The pickers.nvim engine and its dispatcher, when that plugin is installed.
---@return table|nil command  `pickers.command`
---@return table|nil engine
local function pickers_backend()
  local command = soft.require("pickers.command", { "dispatch" })
  if not command then
    return nil, nil
  end
  local engines = soft.require("pickers.engines", { "load" })
  if not engines then
    return nil, nil
  end
  local engine = engines.load()
  if not engine then
    return nil, nil
  end
  return command, engine
end

---`:Tasks folder <area> [folder] [--action=files|grep|smart] [--list] [--to=]`
---
---Opens a pickers.nvim picker whose search root is exactly that one folder of
---the area (`pickers.command.dispatch` with an explicit `roots` source, so
---the picker can be repeated). Without pickers.nvim it falls back to a
---`vim.ui.select` over the folder's `*.md` files -- no content search.
---`--list` (or `--to=`) delivers the file list instead of opening a picker.
---@param ctx table
function M.open_area(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local area = ctx.args.area
  local folder = ctx.args.folder or "all"
  local sub = M.FOLDERS[folder]
  if sub == nil then
    notify.error(
      ("unknown folder '%s' (expected %s)"):format(
        folder,
        "tasks|roadmap|backlog|handover|notes|all"
      )
    )
    return
  end
  local dir = root .. "/" .. area .. (sub ~= "" and ("/" .. sub) or "")
  if not fsio.is_dir(dir) then
    notify.warn(("%s has no %s folder (%s)"):format(area, folder, rel(dir, root)))
    return
  end

  local target, terr = view.parse_target(ctx.flags.to)
  if terr or (target and target.kind == "qf") then
    notify.error(terr or "--to=qf is not supported for :Tasks folder")
    return
  end

  if ctx.flags.list or target then
    local lines = {}
    for _, p in ipairs(markdown_below(dir)) do
      lines[#lines + 1] = p:sub(#dir + 2)
    end
    if #lines == 0 then
      notify.info(("no Markdown file in %s"):format(rel(dir, root)))
      return
    end
    local kind = target and target.kind or "buffer"
    local blocked = view.overwrite_guard(target, ctx.flags.force)
    if blocked then
      notify.error(blocked .. " (pass --force to overwrite it)")
      return
    end
    local ok, err = harvest.emit(table.concat(lines, "\n") .. "\n", kind, {
      path = target and target.path or nil,
      title = ("tasks://open/%s/%s"):format(area, folder),
      filetype = "text",
    })
    if not ok then
      notify.error(tostring(err))
    end
    return
  end

  local action = ctx.flags.action or "files"
  local command, engine = pickers_backend()
  if command then
    command.dispatch(action, {
      roots = { dir },
      prompt = ("%s/%s> "):format(area, folder),
    }, engine)
    return
  end

  if action ~= "files" then
    notify.warn(
      "pickers.nvim is not available: --action=" .. action .. " needs it, listing files instead"
    )
  end
  local files = markdown_below(dir)
  if #files == 0 then
    notify.info(("no Markdown file in %s"):format(rel(dir, root)))
    return
  end
  harvest.sink.select(files, {
    prompt = ("%s/%s"):format(area, folder),
    format = function(p)
      return p:sub(#dir + 2)
    end,
  }, function(path)
    open_file(path)
  end)
end

return M
