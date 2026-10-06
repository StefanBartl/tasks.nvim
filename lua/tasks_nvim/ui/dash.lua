---@module 'tasks_nvim.ui.dash'
---@brief The interactive task dashboard behind `:Tasks list [<area>|all]` (concept section 6).
---@description
--- A `Snacks.picker` source (the engine `picker.lua` uses): one line per open
--- task, the task file as the preview, the counts and the filter chips in the
--- title. Without snacks.nvim a small `vim.ui.select` flow offers the same
--- actions for one task at a time (no batch).
---
--- Keys (list window; the input window has them as Alt chords, `<M-s>` `<M-p>` `<M-d>`
--- `<M-f>` `<M-o>` `<M-e>` `<M-r>` `<M-b>` (backlog) `<M-m>` (roadmap) `<M-?>`, in normal and insert mode):
---  - `<CR>` open the file(s)    `<Tab>` / `<S-Tab>` mark (snacks' own multi-select)
---  - `s` / `p`  advance status / prio of the marked (else the current) tasks,
---    ONE batch, ONE notification, each touched area's index regenerated once
---  - `D` finish (asks first)   `f` set a filter chip   `o` sort order   `e` export   `r` rescan
---  - `gb` / `gr` Backlog / ROADMAP.md of the area under the cursor   `g?` help
---  - `gp` preview the task file in the browser (mdview.nvim; Alt chord `<M-v>`);
---    `e` offers "Preview in browser" for the list as well
---
--- Prompting keys (`D`, `f`, `e`, `gb`, `gr`, `gp`) close the picker first -- snacks
--- closes a picker whose window loses focus -- and `D` and `f` reopen it when
--- the prompt is over. `s` / `p` refresh in place.
---
--- Live refresh: while the picker is open, `tasks_dash_watch` watches the task
--- and Backlog folders and the list rescans by itself when a file changed (not
--- for the dashboard's own writes). Cursor and marks are found again by task id;
--- filter and sort are untouched. `M.config.watch = false` (or `opts.watch =
--- false`) turns it off; when no folder can be watched it says so once and `r`
--- stays the way to rescan. The plain `vim.ui.select` fallback has no live list.
---
--- Frecency: opening (`<CR>`) or changing (`s` / `p`) a task counts as a visit
--- (`tasks.frecency`); `o` also cycles to `frecency`, which lists the most-visited
--- tasks first (opt-in: it does mix statuses and prios).
---
--- Not its job: the rules about a line, a filter or a cycle (`tasks_dash_core`),
--- the delivery sinks (`tasks_view`), the rules of tasks (the engine).

local confirm = require("tasks_nvim.ui.confirm")
local soft = require("tasks_nvim.soft")
local core = require("tasks_nvim.ui.dash_core")
local notify = require("lib.nvim.notify").create("[tasks.dash]")
local view = require("tasks_nvim.ui.view")

local M = {}

---Overrides of the dashboard settings, for a script or a spec (`require(...).config.watch = false`); the
---settings themselves are `dashboard = { watch, debounce_ms }` of `setup()`. `nil` means "from `setup()`".
---`watch_opts` is merged into the `dash_watch.new` options (the seam the specs use).
---@class Tasks.DashConfig
---@field watch? boolean              # Rescan on file changes while open.
---@field watch_debounce_ms? integer  # Quiet period before a rescan.
---@field watch_opts? table
M.config = {}

---@return Tasks.DashboardConfig
local function settings()
  return require("tasks_nvim.config").get().dashboard
end

---Key under which the last filter is remembered (`lib.nvim.store.project`).
local STORE_KEY = "tasks/dashboard-filter"

---Most task lines the finish confirmation lists before it says "... and n more".
local MAX_CONFIRM_LINES = 8

---@class Tasks.DashState
---@field refresh_error_seen? boolean  # A failed live refresh has been announced.
---@field errors_seen? string  # The read errors of the last reload (so the same set is not announced twice).
---@field notes_seen? string   # Likewise for the `--stale=refs` notes.
---@field root string
---@field area string|nil
---@field filter Tasks.Filter
---@field sort string          # One of `model.SORTS` (`o` cycles it).
---@field shown Tasks.Task[]
---@field widths { area: integer, effort: integer, status: integer }
---@field persist boolean
---@field signature? string                          # `core.signature` of `shown`.
---@field readiness? Tasks.DashReadiness              # Where each shown task stands, and the sums (nil when the vault could not be read).
---@field preload? Tasks.DashLoad        # A load the next `reload` uses instead of scanning again.
---@field watch? boolean                             # Live refresh for this dashboard.
---@field view? "list"|"stages"                      # The stage view groups the tasks by stage (`v` switches).
---@field plan? Tasks.Plan                           # The plan of the shown tasks, from the last load.

---@class Tasks.DashOpts
---@field persist? boolean   # Remember the filter between sessions (default true).
---@field backend? "auto"|"snacks"|"kit"|"select"   # Force a backend (default: `dashboard.backend`, `auto`: snacks when present, else kit).
---@field watch? boolean     # Live refresh (default: `M.config.watch`).

-- ── small helpers ────────────────────────────────────────────────────────────

---@return table
local function cmd()
  return require("tasks_nvim.ui.cmd")
end

-- "statusline" reports into the shared lib.nvim.progress registry, like picker.lua.
local progress_mod = soft.require("lib.nvim.progress")
---@param title string
local function new_progress(title)
  if not progress_mod then
    return nil
  end
  return progress_mod.create({ title = title, style = "statusline" })
end

---@param state Tasks.DashState
local function persist(state)
  if not state.persist then
    return
  end
  local store = soft.require("lib.nvim.store.project")
  if store then
    pcall(
      store.save,
      STORE_KEY,
      { filter = core.filter_to_options(state.filter), sort = state.sort },
      { path = state.root }
    )
  end
end

---@param root string
---@return Tasks.Filter filter
---@return string sort
local function remembered(root)
  local store = soft.require("lib.nvim.store.project")
  if not store then
    return {}, "default"
  end
  local ok_load, data = pcall(store.load, STORE_KEY, { path = root })
  if not ok_load or type(data) ~= "table" then
    return {}, "default"
  end
  return core.filter_from_stored(data.filter), core.sort_from_stored(data.sort)
end

---Dashboard state for a `Tasks.View`: the command's own filter and
---sort order if it carried them, else the ones remembered from the last session.
---@param v Tasks.View
---@param opts? Tasks.DashOpts
---@return Tasks.DashState
local function new_state(v, opts)
  opts = opts or {}
  local filter = v.filter or {}
  -- A sort the command carried (even `default`) is the user's explicit choice; only an absent one falls
  -- back to the remembered order (LUA-87: stored state never overrules an explicit input).
  local explicit_sort = v.sort ~= nil and v.sort ~= ""
  local sort = explicit_sort and v.sort or "default"
  local do_persist = opts.persist ~= false
  if do_persist then
    local last_filter, last_sort = remembered(v.root)
    if core.filter_is_empty(filter) then
      filter = last_filter
    end
    if not explicit_sort then
      sort = last_sort
    end
  end
  return {
    root = v.root,
    area = v.area,
    filter = filter,
    sort = sort,
    shown = {},
    widths = core.widths({}),
    persist = do_persist,
    watch = (function()
      if opts.watch ~= nil then
        return opts.watch
      end
      if M.config.watch ~= nil then
        return M.config.watch
      end
      return settings().watch
    end)(),
  }
end

---@param state Tasks.DashState
---@return Tasks.DashLoad|nil res
---@return string|nil err
local function load_state(state)
  return core.load({
    root = state.root,
    area = state.area,
    filter = state.filter,
    sort = state.sort,
    want_plan = state.view == "stages",
  })
end

---Rescan and refilter; the result is `state.shown`. A `state.preload` (what the
---watcher just compared against the list) is used once instead of scanning again.
---@param state Tasks.DashState
---@return Tasks.Task[]
local function reload(state)
  local res, err = state.preload, nil
  state.preload = nil
  if not res then
    res, err = load_state(state)
  end
  if not res then
    notify.error(("cannot read the tasks: %s"):format(tostring(err)))
    state.shown = {}
  else
    state.shown = res.tasks
    state.plan = res.plan or state.plan
    -- Files or folders that could not be read are not "no tasks": say so once per distinct set of errors
    -- (the watcher reloads often), so a transiently locked folder does not make tasks vanish silently.
    local errs = res.errors or {}
    local sig = #errs > 0 and table.concat(errs, "\n") or ""
    if sig ~= "" and sig ~= state.errors_seen then
      notify.warn(
        ("%d path(s) could not be read, the list may be incomplete: %s"):format(
          #errs,
          tostring(errs[1])
        )
      )
    end
    state.errors_seen = sig
    -- `--stale=refs` reports through the notes of its report (git missing, a cap hit, a failed check). Without
    -- this a failed check looked like "no stale tasks" in the list.
    if state.filter and state.filter.stale_refs then
      local joined = table.concat(res.stale_report and res.stale_report.notes or {}, " | ")
      if joined ~= "" and joined ~= state.notes_seen then
        notify.warn("stale-refs filter: " .. joined)
      end
      state.notes_seen = joined
    end
  end
  state.widths = core.widths(state.shown)
  -- the load carries the readiness it was judged from (one scan); only a failed load has none
  state.readiness = res and res.readiness or core.readiness(state.shown, state.root)
  state.signature =
    core.signature(state.shown, state.readiness, state.view == "stages" and state.plan or nil)
  return state.shown
end

---Count a visit for each task (opened, or changed from the dashboard): what
---`--sort=frecency` ranks by. Never raises; a file that cannot be written is
---not worth interrupting the user for.
---@param tasks Tasks.Task[]|{ id: string }[]
---@return boolean recorded
local function touch(tasks)
  local ids = {}
  for _, t in ipairs(tasks) do
    ids[#ids + 1] = t.id
  end
  if #ids == 0 then
    return false
  end
  local ok, res = pcall(function()
    return require("tasks_nvim.frecency").record(ids)
  end)
  return ok and res == true
end

---@param state Tasks.DashState
---@return string
local function title_of(state)
  return core.header(state.shown, state.filter, state.area, state.sort, state.readiness)
end

---@param tasks Tasks.Task[]
---@return string[] lines
local function describe(tasks)
  local lines = {}
  for i, t in ipairs(tasks) do
    if i > MAX_CONFIRM_LINES then
      lines[#lines + 1] = ("... and %d more"):format(#tasks - MAX_CONFIRM_LINES)
      break
    end
    lines[#lines + 1] = ("%s  %s"):format(t.id, confirm.shorten(t.title, 70))
  end
  return lines
end

---The tasks of the vault's open list by id (for the refresh of buffers after a write).
---@param res Tasks.DashSetResult
local function refresh_buffers(res)
  local c = cmd()
  if type(c.refresh_buffers) ~= "function" then
    return
  end
  for _, ch in ipairs(res.changed) do
    c.refresh_buffers(ch.path)
  end
end

-- ── the actions (shared by the picker and the fallback) ──────────────────────

---`s` / `p`: advance the field of every target in one batch; a count (`3p`) advances it that many steps.
---@param state Tasks.DashState
---@param tasks Tasks.Task[]
---@param field "status"|"prio"
---@param count? integer
---@return Tasks.DashSetResult|nil result
function M.cycle(state, tasks, field, count)
  if #tasks == 0 then
    return nil
  end
  local prog = new_progress("[tasks.dash] " .. field)
  local ran, res =
    pcall(core.apply_set, core.plan_cycle(tasks, field, count), { root = state.root })
  if not ran then
    -- An unexpected error must not leave the statusline progress (and its timer) running for good.
    if prog then
      prog:finish("failed")
    end
    error(res, 0)
  end
  refresh_buffers(res)
  touch(res.changed)
  local level, text = core.describe_set(field, res)
  if prog then
    prog:finish(("%d changed, %d failed"):format(#res.changed, #res.failed))
  end
  notify[level](text)
  return res
end

---Apply steps from the stage view (assign, move) as one batch, with the message `s` / `p` give.
---@param state Tasks.DashState
---@param steps Tasks.BatchSetStep[]
---@param what string
---@return Tasks.DashSetResult|nil
local function apply_steps(state, steps, what)
  if #steps == 0 then
    return nil
  end
  local res = core.apply_set(steps, { root = state.root })
  refresh_buffers(res)
  touch(res.changed)
  local level, text = core.describe_set(what, res)
  notify[level](text)
  return res
end

---`P`: give tasks a plan (an open plan file) and a stage of it.
---@param state Tasks.DashState
---@param tasks Tasks.Task[]
---@param after fun(changed: boolean)
function M.assign(state, tasks, after)
  if #tasks == 0 then
    after(false)
    return
  end
  local files = require("tasks_nvim.plans").all({ root = state.root }) or {}
  local labels = { "(no plan)" }
  for _, f in ipairs(files) do
    labels[#labels + 1] = f.id
  end
  vim.ui.select(
    labels,
    { prompt = ("Plan for %d task%s"):format(#tasks, #tasks == 1 and "" or "s") },
    function(choice, idx)
      if not choice then
        after(false)
        return
      end
      local file = idx > 1 and files[idx - 1] or nil
      local function finish(phase)
        local res =
          apply_steps(state, core.assign_steps(tasks, file and file.id or nil, phase), "assign")
        after(res ~= nil and #res.changed > 0)
      end
      if not file or #file.phase_order == 0 then
        finish(nil)
        return
      end
      local phases = vim.list_extend({ "(no stage)" }, file.phase_order)
      vim.ui.select(phases, { prompt = "Stage of " .. file.id }, function(phase, pidx)
        if not phase then
          after(false)
          return
        end
        finish(pidx > 1 and phase or nil)
      end)
    end
  )
end

---`J` / `K` in the stage view: the neighbours of `task` in its group (up to the headings).
---@param state Tasks.DashState
---@param task Tasks.Task
---@param dir integer
---@return boolean moved
function M.move(state, task, dir)
  if state.view ~= "stages" or not state.plan then
    notify.info("moving needs the stage view (v)")
    return false
  end
  local list, seen = {}, false
  for _, row in ipairs(core.stage_rows(state.plan)) do
    if row.header then
      if seen then
        break
      end
      list = {}
    else
      list[#list + 1] = row.task
      if row.task.id == task.id then
        seen = true
      end
    end
  end
  local steps, why = core.order_steps(list, task.id, dir)
  if not steps then
    notify.info(("not moved: %s"):format(tostring(why)))
    return false
  end
  local res = apply_steps(state, steps, "order")
  return res ~= nil and #res.changed > 0
end

---`D`: ask once for the whole batch, then finish every target.
---@param state Tasks.DashState
---@param tasks Tasks.Task[]
---@param after fun(done: boolean)  # Called once, after the answer and the work.
function M.finish(state, tasks, after)
  if #tasks == 0 then
    after(false)
    return
  end
  local msg = ("Finish %d task%s?\n\n%s\n\nThey move to Backlog/."):format(
    #tasks,
    #tasks == 1 and "" or "s",
    table.concat(describe(tasks), "\n")
  )
  confirm.yesno(msg, "finish", function(accepted)
    if not accepted then
      notify.info("cancelled -- the tasks stay open")
      after(false)
      return
    end
    local ids = {}
    for _, t in ipairs(tasks) do
      ids[#ids + 1] = t.id
    end
    local prog = new_progress("[tasks.dash] done")
    local ran, res = pcall(core.apply_done, ids, { root = state.root })
    if not ran then
      if prog then
        prog:finish("failed")
      end
      error(res, 0)
    end
    for _, d in ipairs(res.done) do
      cmd().retarget_buffers(d.from, d.to)
    end
    local level, text = core.describe_done(res)
    if prog then
      prog:finish(("%d finished, %d failed"):format(#res.done, #res.failed))
    end
    notify[level](text)
    after(#res.done > 0)
    -- ONE answer for the whole stack, after the list is back: the tasks that still read `blocked` (offered to be
    -- opened) and what to start next, from the last finished task.
    local last = res.done[#res.done]
    if last and res.next then
      vim.schedule(function()
        cmd().after_finish(
          { next = res.next, plans_closed = res.plans_closed, plan_summaries = res.plan_summaries },
          last.id
        )
      end)
    end
  end)
end

---`f`: pick a dimension, then a value; empty choices clear.
---@param state Tasks.DashState
---@param after fun()  # Called once, changed or not.
local function set_filter(state, after)
  local dims = vim.deepcopy(core.FILTER_DIMS)
  dims[#dims + 1] = core.CLEAR_ALL
  local chips = core.chips(state.filter)
  vim.ui.select(dims, {
    prompt = "Filter: " .. (#chips > 0 and table.concat(chips, ", ") or "none"),
  }, function(dim)
    if not dim then
      after()
      return
    end
    if dim == core.CLEAR_ALL then
      state.filter = {}
      persist(state)
      after()
      return
    end
    if dim == "blocked" then
      state.filter = core.set_dim(state.filter, "blocked", not state.filter.blocked or nil)
      persist(state)
      after()
      return
    end
    if dim == "unestimated" then
      state.filter = core.set_dim(state.filter, "unestimated", not state.filter.unestimated or nil)
      persist(state)
      after()
      return
    end
    if dim == "stale-refs" then
      state.filter = core.set_dim(state.filter, "stale-refs", not state.filter.stale_refs or nil)
      persist(state)
      after()
      return
    end
    -- only the tag, plan and phase menus need the tasks (to offer the values in use); the others are fixed lists
    local scope = (dim == "tag" or dim == "plan" or dim == "phase")
        and core.load({ root = state.root, area = state.area, filter = {} })
      or nil
    local choices = core.dim_choices(dim, scope and scope.tasks or {})
    table.insert(choices, 1, core.CLEAR)
    vim.ui.select(choices, { prompt = "Filter " .. dim }, function(value)
      if value then
        state.filter = core.set_dim(state.filter, dim, value ~= core.CLEAR and value or nil)
        persist(state)
      end
      after()
    end)
  end)
end

---`o`: the next sort order (default -> prio-effort -> severity -> frecency -> default).
---@param state Tasks.DashState
---@param count? integer  steps to advance (`3o`)
function M.cycle_sort(state, count)
  for _ = 1, math.max(1, count or 1) do
    state.sort = core.cycle_sort(state.sort)
  end
  persist(state)
end

---`e`: ask where, deliver the tasks with the `--to=` sinks.
---@param state Tasks.DashState
---@param tasks Tasks.Task[]
---@param after fun(delivered: boolean)
function M.export(state, tasks, after)
  if #tasks == 0 then
    notify.info("nothing to export")
    after(false)
    return
  end
  vim.ui.select(core.EXPORT_CHOICES, {
    prompt = ("Export %d task%s"):format(#tasks, #tasks == 1 and "" or "s"),
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice then
      after(false)
      return
    end
    ---@param path string|nil
    local function deliver(path)
      local target, terr = core.export_target(choice, path)
      if not target then
        notify.warn(tostring(terr))
        after(false)
        return
      end
      -- The path goes as typed: `harvest.sink.file` resolves `~` and environment variables itself.
      -- `vim.fn.expand` here would run a backtick span through the shell, throw on `<cfile>` and
      -- replace a wildcard by whatever file it happens to match.
      local chips = core.chips(state.filter)
      local sort_chip = core.sort_chip(state.sort)
      if sort_chip then
        chips[#chips + 1] = sort_chip
      end
      ---@param force boolean
      local function go(force)
        local ok, err = view.deliver(tasks, target, {
          force = force,
          format = choice.format,
          heading = ("Open tasks -- %s (%d)"):format(state.area or "all areas", #tasks),
          note = #chips > 0 and ("Filter: " .. table.concat(chips, ", ")) or nil,
          title = "tasks://tasks/" .. (state.area or "all"),
        })
        if not ok then
          notify.error(("cannot export: %s"):format(tostring(err)))
          after(false)
          return
        end
        notify.info(("%d task(s) -> %s"):format(#tasks, target.path or choice.label))
        after(true)
      end
      -- An existing file is replaced only after the user says yes.
      local blocked = view.overwrite_guard(target, false)
      if blocked then
        confirm.yesno(blocked .. ". Overwrite it?", "overwrite", function(yes)
          if yes then
            go(true)
          else
            notify.info("export cancelled")
            after(false)
          end
        end)
      else
        go(false)
      end
    end
    if choice.ask_path then
      vim.ui.input({ prompt = "File path: ", completion = "file" }, deliver)
    else
      deliver(nil)
    end
  end)
end

---`gp`: the task file rendered in the browser (mdview.nvim, a soft dependency).
---@param task Tasks.Task|nil
local function preview_task(task)
  if not task then
    return
  end
  local ok, err = require("tasks_nvim.ui.preview").open_file(task.path)
  if not ok then
    notify.warn(("cannot preview %s: %s"):format(task.id, tostring(err)))
  end
end

---`gb` / `gr`: the Backlog picker, or ROADMAP.md, of an area.
---@param state Tasks.DashState
---@param task Tasks.Task|nil
---@param which "backlog"|"roadmap"
local function open_area_doc(state, task, which)
  if not task then
    return
  end
  if which == "backlog" then
    cmd().open_area({ args = { area = task.area, folder = "backlog" }, flags = {} })
    return
  end
  local path = ("%s/%s/ROADMAP/ROADMAP.md"):format(state.root, task.area)
  if vim.fn.filereadable(path) == 1 then
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    if not ok then
      notify.error(("cannot open %s: %s"):format(path, tostring(err)))
    end
  else
    notify.warn(("%s has no ROADMAP/ROADMAP.md"):format(task.area))
  end
end

-- ── help ─────────────────────────────────────────────────────────────────────

---The dashboard actions, in the order the help lists them: the name in `setup({ keys.dashboard })`, the picker
---action behind it and what it does. `help_lines` and the key binding below both read this one table.
---@type { name: string, action: string, text: string }[]
local ACTIONS = {
  {
    name = "status",
    action = "tasks_status",
    text = "advance the status of the marked (else current) tasks",
  },
  { name = "prio", action = "tasks_prio", text = "advance the prio: none -> 1 -> 2 -> 3 -> none" },
  { name = "done", action = "tasks_done", text = "finish (asks first, moves to Backlog/)" },
  {
    name = "filter",
    action = "tasks_filter",
    text = "set a filter chip (" .. table.concat(core.FILTER_DIMS, " ") .. ")",
  },
  {
    name = "sort",
    action = "tasks_sort",
    text = "cycle the sort: "
      .. table.concat(require("tasks_nvim.model").SORTS, " -> ")
      .. " -> "
      .. require("tasks_nvim.model").SORTS[1],
  },
  {
    name = "export",
    action = "tasks_export",
    text = "export the marked (else all shown) tasks, or preview them",
  },
  {
    name = "preview",
    action = "tasks_preview",
    text = "preview the task file in the browser (mdview.nvim)",
  },
  {
    name = "rescan",
    action = "tasks_rescan",
    text = "rescan the vault now (the list also refreshes by itself when a task file changes)",
  },
  {
    name = "backlog",
    action = "tasks_backlog",
    text = "Backlog picker of the area under the cursor",
  },
  { name = "roadmap", action = "tasks_roadmap", text = "ROADMAP.md of the area under the cursor" },
  {
    name = "view",
    action = "tasks_view",
    text = "switch between the list and the stage view (tasks grouped by stage, what each waits for)",
  },
  {
    name = "assign",
    action = "tasks_assign",
    text = "give the marked (else current) tasks a plan and a stage",
  },
  {
    name = "move_up",
    action = "tasks_move_up",
    text = "stage view: move the task up among its stage's tasks (`order`, a fraction between the neighbours)",
  },
  {
    name = "move_down",
    action = "tasks_move_down",
    text = "stage view: move the task down",
  },
  { name = "help", action = "tasks_help", text = "this help" },
}

---The help text, from the keys in force: what `setup({ keys })` bound is what is shown, a key set to `false` is
---listed as unbound.
---@param keys? Tasks.KeysConfig  # Default: the configured keys.
---@return string[]
function M.help_lines(keys)
  keys = keys or require("tasks_nvim.config").get().keys
  local lines = {
    " Task dashboard ",
    "",
    " list key / input key    what it does",
    " <CR>                    open the file(s)  (counts as a visit for the frecency sort)",
    " <Tab>                   mark / unmark (marked tasks are the target of status, prio, done, export)",
  }
  for _, a in ipairs(ACTIONS) do
    local list_key = keys.dashboard[a.name] or "-"
    local input_key = keys.dashboard_input[a.name] or "-"
    lines[#lines + 1] = (" %-23s %s"):format(list_key .. " / " .. input_key, a.text)
  end
  vim.list_extend(lines, {
    "",
    " The first key works in the list window; in the input window use the second (the first would be typed).",
    " A count before status / prio / sort repeats it.",
    " (any key closes this help)",
  })
  return lines
end

---Float with the key help; any key closes it again (the picker keeps focus).
local function show_help()
  require("tasks_nvim.ui.help_float").open(M.help_lines(), "tasks_dash_help")
end

-- ── snacks backend ───────────────────────────────────────────────────────────

local open_state

---Rebuild the list in place and put the cursor back on the task it was on
---(found by id: the rescan may have moved or dropped rows), and with
---`keep_marks` the marks too. `picker:refresh()` alone keeps the line number
---and drops the marks.
---@param picker table
---@param keep_marks boolean
local function refresh_keep(picker, keep_marks)
  if picker.closed then
    return
  end
  if picker.refresh_keep then
    -- the kit backend rebuilds its own list
    picker.refresh_keep(keep_marks)
    return
  end
  local cur = picker:current()
  local cursor_id = cur and cur.task and cur.task.id or nil
  local marked = {}
  if keep_marks then
    for _, item in ipairs(picker.list.selected) do
      if item.task then
        marked[#marked + 1] = item.task.id
      end
    end
  end
  picker.list:set_selected()
  picker.list:set_target()
  picker:find({
    refresh = true,
    on_done = function()
      if picker.closed then
        return
      end
      local items = picker:items()
      local ids = {}
      for i, item in ipairs(items) do
        ids[i] = item.task and item.task.id or ""
      end
      local plan = core.relocate(ids, cursor_id, marked)
      if #plan.marked > 0 then
        local selected = {}
        for _, i in ipairs(plan.marked) do
          selected[#selected + 1] = items[i]
        end
        picker.list:set_selected(selected)
      end
      if plan.cursor then
        picker.list:view(plan.cursor)
      end
    end,
  })
end

---The items of the dashboard list: tasks (list view) or headings and tasks (stage view).
---@param state Tasks.DashState
---@return table[] items
local function build_items(state)
  local items = {}
  local shown = reload(state)
  if state.view == "stages" and state.plan then
    for _, row in ipairs(core.stage_rows(state.plan)) do
      if row.header then
        items[#items + 1] = { text = row.header, header = row.header }
      else
        items[#items + 1] = {
          text = core.search_text(row.task),
          file = row.task.path,
          task = row.task,
          waits = row.waits,
        }
      end
    end
  else
    for _, t in ipairs(shown) do
      items[#items + 1] = { text = core.search_text(t), file = t.path, task = t }
    end
  end
  return items
end

---The text parts of one row (both pickers).
---@param state Tasks.DashState
---@param item table
---@return table[] parts
local function format_item(state, item)
  if item.header then
    return { { "-- " .. item.header .. " --", "Title" } }
  end
  local parts = core.parts(item.task, state.widths, state.readiness)
  if item.waits then
    parts[#parts + 1] = { "  waits: " .. item.waits, "Comment" }
  end
  return parts
end

---What the file watcher calls: rescan, and only when the result differs from
---the list on screen redraw it. A scan that fails is not reported -- nobody
---asked for it -- the next change or `r` tries again.
---@param state Tasks.DashState
---@param picker table
---@return boolean refreshed
function M.refresh_if_changed(state, picker)
  if picker.closed then
    return false
  end
  local res = load_state(state)
  if
    not res
    or core.signature(
        res.tasks,
        res.readiness or core.readiness(res.tasks, state.root),
        state.view == "stages" and res.plan or nil
      )
      == state.signature
  then
    return false
  end
  state.preload = res
  refresh_keep(picker, true)
  return true
end

---Start the live refresh of a picker. Returns the watcher, or nil when it is
---off or could not start (said once; `r` still works).
---@param state Tasks.DashState
---@param picker table
---@return Tasks.DashWatcher|nil
local function start_watch(state, picker)
  if not state.watch then
    return nil
  end
  local w = require("tasks_nvim.ui.dash_watch").new(vim.tbl_extend("force", {
    root = state.root,
    area = state.area,
    debounce_ms = M.config.watch_debounce_ms or settings().debounce_ms,
    on_refresh = function()
      M.refresh_if_changed(state, picker)
    end,
    on_error = function(err)
      -- Once per picker: a refresh that keeps failing must not flood the message area.
      if not state.refresh_error_seen then
        state.refresh_error_seen = true
        notify.warn(("the live refresh failed: %s (press r to rescan)"):format(tostring(err)))
      end
    end,
  }, M.config.watch_opts or {}))
  -- A handle factory that raises must not take the open picker down with it (the caller's pcall
  -- would open the plain list on top of it) and must not leave the handles it did start behind.
  local ran, res, err = pcall(w.start, w)
  local started = ran and res == true
  if not ran then
    pcall(w.stop, w)
    err = tostring(res)
  end
  if not started then
    notify.info(("no live refresh (%s) -- press r to rescan"):format(tostring(err)))
    return nil
  end
  if w.partial then
    notify.info(
      ("live refresh watches %d of %d folders -- press r to rescan the rest"):format(
        w.partial.started,
        w.partial.wanted
      )
    )
  end
  return w
end

---@param engine "snacks"|"kit"
---@param Snacks table|nil
---@param state Tasks.DashState
local function open_picker(engine, Snacks, state)
  ---@type Tasks.DashWatcher|nil
  local watcher

  ---Run a write batch of the dashboard so its own file events do not trigger a rescan.
  ---@generic T
  ---@param fn fun(): T
  ---@return T
  local function held(fn)
    if watcher then
      return watcher:hold(fn)
    end
    return fn()
  end

  ---Marked tasks, else (with `fallback`) the current one.
  ---@param picker table
  ---@param fallback boolean
  ---@return Tasks.Task[]
  local function targets(picker, fallback)
    local out = {}
    for _, item in ipairs(picker:selected({ fallback = fallback })) do
      if item and item.task then
        out[#out + 1] = item.task
      end
    end
    return out
  end

  ---Close the picker, run `fn`, and reopen the dashboard when `fn` says so.
  ---@param picker table
  ---@param fn fun(reopen: fun())
  local function detour(picker, fn)
    picker:close()
    vim.schedule(function()
      fn(function()
        open_state(state, { backend = engine })
      end)
    end)
  end

  local function current_task(picker)
    local item = picker:current()
    return item and item.task or nil
  end

  local actions = {
    tasks_status = function(picker)
      local tasks = targets(picker, true)
      if
        held(function()
          return M.cycle(state, tasks, "status", vim.v.count1)
        end)
      then
        refresh_keep(picker, false)
      end
    end,
    tasks_prio = function(picker)
      local tasks = targets(picker, true)
      if held(function()
        return M.cycle(state, tasks, "prio", vim.v.count1)
      end) then
        refresh_keep(picker, false)
      end
    end,
    tasks_rescan = function(picker)
      refresh_keep(picker, true)
      if watcher then
        -- also aims the watcher at areas and folders that appeared meanwhile
        pcall(watcher.sync, watcher)
      end
    end,
    tasks_sort = function(picker)
      M.cycle_sort(state, vim.v.count1)
      -- Only the order changes: sort the list that is on screen instead of scanning and parsing the whole
      -- vault again (3.5 ms against ~120 ms). The finder uses `state.preload` once.
      state.preload = {
        tasks = require("tasks_nvim.model").sort(vim.list_slice(state.shown), state.sort),
        errors = {},
        -- the same tasks, so the same readiness: handing it over is what makes the shortcut a shortcut
        readiness = state.readiness,
      }
      refresh_keep(picker, true)
    end,
    ---`<CR>`: a visit for the frecency sort, then snacks' own jump.
    tasks_open = function(picker, item, action)
      -- a stage heading is a row, not a task: it is neither opened nor marked for opening
      local chosen = picker:selected({ fallback = true })
      local only_tasks = {}
      for _, it in ipairs(chosen) do
        if it.task then
          only_tasks[#only_tasks + 1] = it
        end
      end
      if #only_tasks == 0 then
        return
      end
      if Snacks and #only_tasks ~= #chosen then
        picker.list:set_selected(only_tasks)
      end
      touch(targets(picker, true))
      if Snacks then
        return Snacks.picker.actions.jump(picker, item, action)
      end
      return picker:jump(item)
    end,
    tasks_done = function(picker)
      local tasks = targets(picker, true)
      detour(picker, function(reopen)
        M.finish(state, tasks, function()
          reopen()
        end)
      end)
    end,
    tasks_filter = function(picker)
      detour(picker, function(reopen)
        set_filter(state, reopen)
      end)
    end,
    tasks_export = function(picker)
      local tasks = targets(picker, false)
      if #tasks == 0 then
        tasks = vim.deepcopy(state.shown)
      end
      detour(picker, function(reopen)
        M.export(state, tasks, function(delivered)
          if not delivered then
            reopen()
          end
        end)
      end)
    end,
    tasks_backlog = function(picker)
      local task = current_task(picker)
      if not task then
        return
      end
      picker:close()
      vim.schedule(function()
        open_area_doc(state, task, "backlog")
      end)
    end,
    tasks_roadmap = function(picker)
      local task = current_task(picker)
      if not task then
        return
      end
      picker:close()
      vim.schedule(function()
        open_area_doc(state, task, "roadmap")
      end)
    end,
    tasks_preview = function(picker)
      local task = current_task(picker)
      if not task then
        return
      end
      picker:close()
      vim.schedule(function()
        preview_task(task)
      end)
    end,
    tasks_view = function(picker)
      state.view = state.view == "stages" and "list" or "stages"
      refresh_keep(picker, true)
    end,
    tasks_assign = function(picker)
      local tasks = targets(picker, true)
      detour(picker, function(reopen)
        M.assign(state, tasks, function()
          reopen()
        end)
      end)
    end,
    tasks_move_up = function(picker)
      local task = current_task(picker)
      if task and held(function()
        return M.move(state, task, -1)
      end) then
        refresh_keep(picker, false)
      end
    end,
    tasks_move_down = function(picker)
      local task = current_task(picker)
      if task and held(function()
        return M.move(state, task, 1)
      end) then
        refresh_keep(picker, false)
      end
    end,
    tasks_help = function()
      show_help()
    end,
  }

  -- Letters in the list window (nothing is typed there); Alt chords in the input window, so its normal-mode edits
  -- (`s` `p` `D` `e` ...) and the search typing in insert mode stay untouched. Both come from
  -- `setup({ keys = { dashboard = ..., dashboard_input = ... } })` (defaults in `config/DEFAULTS.lua`); `false`
  -- switches an action's key off.
  local configured = require("tasks_nvim.config").get().keys
  local list_keys, input_keys = {}, {}
  for _, a in ipairs(ACTIONS) do
    local list_key = configured.dashboard[a.name]
    if list_key then
      list_keys[list_key] = a.action
    end
    local input_key = configured.dashboard_input[a.name]
    if input_key then
      input_keys[input_key] = { a.action, mode = { "n", "i" } }
    end
  end

  if engine == "kit" then
    -- lib.nvim's picker: no snacks needed. The prompt keeps the focus, so the keys are the Alt chords
    -- (`keys.dashboard_input`) and <Tab> marks. The actions above only need the few picker methods defined here.
    local kit = require("lib.nvim.ui.kit")
    local handle
    local adapter = { closed = false }
    function adapter:selected(o)
      local marked = handle.marked()
      if #marked > 0 then
        return marked
      end
      local item = o and o.fallback and handle.current() or nil
      return item and { item } or {}
    end
    function adapter:current()
      return handle.current()
    end
    function adapter:close()
      handle.close()
    end
    function adapter:jump(item)
      handle.close()
      if item and item.file then
        pcall(vim.cmd, "edit " .. vim.fn.fnameescape(item.file))
      end
    end
    adapter.refresh_keep = function(keep_marks)
      if adapter.closed then
        return
      end
      local items = build_items(state)
      handle.set_items(items, { keep_marks = keep_marks })
      handle.set_title(title_of(state))
    end
    local keys = {}
    for lhs, spec in pairs(input_keys) do
      keys[lhs] = function()
        actions[spec[1]](adapter)
      end
    end
    local first = build_items(state)
    handle = kit.picker({
      items = first,
      key = function(item)
        return item.task and item.task.id or ("# " .. item.header)
      end,
      text = function(item)
        return item.text
      end,
      selectable = function(item)
        return item.task ~= nil
      end,
      format = function(item)
        return format_item(state, item)
      end,
      preview = function(item, surface)
        if not item.task then
          surface:set_lines({})
          return
        end
        local read, lines = pcall(vim.fn.readfile, item.file, "", 200)
        surface:set_lines(read and lines or { "(cannot read the file)" })
        if vim.bo[surface.bufnr].filetype ~= "markdown" then
          -- setting it fires FileType (ftplugin, treesitter, renderers): once per preview buffer, not per row
          pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = surface.bufnr })
        end
      end,
      keys = keys,
      title = title_of(state),
      results_width = 0.62,
      on_submit = function(_, _, item)
        if item.task then
          touch({ item.task })
          adapter:jump(item)
        end
      end,
      on_close = function()
        adapter.closed = true
        state.preload = nil
        if watcher then
          watcher:stop()
          watcher = nil
        end
      end,
    })
    if not handle then
      error("the kit picker could not be opened")
    end
    watcher = start_watch(state, adapter)
    if watcher and adapter.closed then
      watcher:stop()
      watcher = nil
    end
    return
  end

  local picker = Snacks.picker({
    source = "tasks_nvim",
    title = title_of(state),
    finder = function(_, ctx)
      local items = build_items(state)
      local picker = ctx and ctx.picker
      if picker then
        picker.title = title_of(state)
        vim.schedule(function()
          if not picker.closed then
            picker:update_titles()
          end
        end)
      end
      return items
    end,
    format = function(item)
      return format_item(state, item)
    end,
    preview = function(ctx)
      if ctx.item.header then
        -- a stage heading has no file
        ctx.preview:reset()
        return true
      end
      return Snacks.picker.preview.file(ctx)
    end,
    confirm = "tasks_open",
    -- An empty result (a filter that matches nothing) must stay open: `f` is how
    -- the user gets out of it.
    show_empty = true,
    actions = actions,
    win = { input = { keys = input_keys }, list = { keys = list_keys } },
    -- Every way out of the picker (jump, detour, <Esc>, focus lost) ends here:
    -- the watcher's handles and timer go with it.
    on_close = function()
      -- A scan the watcher left for the next finder run belongs to this picker: dropped with it, so a reopened
      -- picker (after a detour) never shows the list of the version before.
      state.preload = nil
      if watcher then
        watcher:stop()
        watcher = nil
      end
    end,
  })
  watcher = start_watch(state, picker)
  if watcher and picker.closed then
    -- Closed before we got here (`on_close` found no watcher to stop): nobody else will release it.
    watcher:stop()
    watcher = nil
  end
end

-- ── fallback backend ─────────────────────────────────────────────────────────

---@param state Tasks.DashState
local function open_select(state)
  local shown = reload(state)
  if #shown == 0 then
    notify.info("no open task matches (" .. title_of(state) .. ")")
    return
  end
  local function again()
    open_select(state)
  end
  vim.ui.select(shown, {
    prompt = title_of(state),
    format_item = function(t)
      return core.line(t, state.widths, state.readiness)
    end,
  }, function(task)
    if not task then
      return
    end
    ---@type { label: string, run: fun() }[]
    local menu = {
      {
        label = "open the file",
        run = function()
          touch({ task })
          local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(task.path))
          if not ok then
            notify.error(("cannot open %s: %s"):format(task.path, tostring(err)))
          end
        end,
      },
      {
        label = "preview the file (mdview)",
        run = function()
          preview_task(task)
        end,
      },
      {
        label = "advance status",
        run = function()
          M.cycle(state, { task }, "status")
          again()
        end,
      },
      {
        label = "advance prio",
        run = function()
          M.cycle(state, { task }, "prio")
          again()
        end,
      },
      {
        label = "finish",
        run = function()
          M.finish(state, { task }, again)
        end,
      },
      {
        label = "filter ...",
        run = function()
          set_filter(state, again)
        end,
      },
      {
        label = "next sort order",
        run = function()
          M.cycle_sort(state)
          again()
        end,
      },
      {
        label = "export the list ...",
        run = function()
          M.export(state, vim.deepcopy(shown), function(delivered)
            if not delivered then
              again()
            end
          end)
        end,
      },
      {
        label = "Backlog of the area",
        run = function()
          open_area_doc(state, task, "backlog")
        end,
      },
      {
        label = "ROADMAP.md of the area",
        run = function()
          open_area_doc(state, task, "roadmap")
        end,
      },
    }
    vim.ui.select(menu, {
      prompt = task.id,
      format_item = function(m)
        return m.label
      end,
    }, function(choice)
      if choice then
        choice.run()
      end
    end)
  end)
end

-- ── entry ────────────────────────────────────────────────────────────────────

---Whether the "no snacks.nvim" hint was shown already.
local told_no_snacks = false

---@param state Tasks.DashState
---@param opts? Tasks.DashOpts
function open_state(state, opts)
  opts = opts or {}
  local backend = opts.backend or settings().backend or "auto"
  local Snacks = backend ~= "select" and backend ~= "kit" and soft.require("snacks", { "picker" })
    or nil
  if backend == "auto" and not Snacks then
    backend = "kit"
  end
  if backend == "snacks" or (backend == "auto" and Snacks) then
    if Snacks then
      local opened, err = pcall(open_picker, "snacks", Snacks, state)
      if opened then
        return
      end
      notify.warn(("snacks picker failed (%s), using the plain list"):format(tostring(err)))
    else
      -- Said once per session: a plain list that silently lacks marks, filters and the live refresh reads as a bug.
      if not told_no_snacks then
        told_no_snacks = true
        notify.info(
          "snacks.nvim is not installed: showing a plain selection list (no marks, filter chips or live refresh); "
            .. '`dashboard.backend = "kit"` uses the picker of lib.nvim instead'
        )
      end
    end
  elseif backend == "kit" then
    local opened, err = pcall(open_picker, "kit", nil, state)
    if opened then
      return
    end
    notify.warn(("the kit picker failed (%s), using the plain list"):format(tostring(err)))
  end
  open_select(state)
end

---Open the dashboard for what `:Tasks list` collected. Never raises.
---@param v Tasks.View
---@param opts? Tasks.DashOpts
---@return Tasks.DashState|nil state
function M.open(v, opts)
  local ok, state = pcall(new_state, v, opts)
  if not ok then
    notify.error(("cannot open the dashboard: %s"):format(tostring(state)))
    return nil
  end
  local opened, err = pcall(open_state, state, opts)
  if not opened then
    notify.error(("cannot open the dashboard: %s"):format(tostring(err)))
    return nil
  end
  return state
end

return M
