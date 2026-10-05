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
---@field root string
---@field area string|nil
---@field filter Tasks.Filter
---@field sort string          # One of `model.SORTS` (`o` cycles it).
---@field shown Tasks.Task[]
---@field widths { area: integer, effort: integer, status: integer }
---@field persist boolean
---@field signature? string                          # `core.signature` of `shown`.
---@field preload? Tasks.DashLoad        # A load the next `reload` uses instead of scanning again.
---@field watch? boolean                             # Live refresh for this dashboard.

---@class Tasks.DashOpts
---@field persist? boolean   # Remember the filter between sessions (default true).
---@field backend? "snacks"|"select"   # Force a backend (default: snacks when present).
---@field watch? boolean     # Live refresh (default: `M.config.watch`).

-- ── small helpers ────────────────────────────────────────────────────────────

---@return table
local function cmd()
  return require("tasks_nvim.ui.cmd")
end

-- "statusline" reports into the shared lib.nvim.progress registry, like picker.lua.
local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")
---@param title string
local function new_progress(title)
  if not ok_progress then
    return nil
  end
  return progress_mod.create({ title = title, style = "statusline" })
end

---@param state Tasks.DashState
local function persist(state)
  if not state.persist then
    return
  end
  local ok, store = pcall(require, "lib.nvim.store.project")
  if ok then
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
  local ok, store = pcall(require, "lib.nvim.store.project")
  if not ok then
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
function M.new_state(v, opts)
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
    -- `--stale=refs` reports through `staleness.last.notes` (git missing, a cap hit, a failed check). Without
    -- this a failed check looked like "no stale tasks" in the list.
    if state.filter and state.filter.stale_refs then
      local last = require("tasks_nvim.staleness").last
      local joined = table.concat(last and last.notes or {}, " | ")
      if joined ~= "" and joined ~= state.notes_seen then
        notify.warn("stale-refs filter: " .. joined)
      end
      state.notes_seen = joined
    end
  end
  state.widths = core.widths(state.shown)
  state.signature = core.signature(state.shown)
  return state.shown
end

---Count a visit for each task (opened, or changed from the dashboard): what
---`--sort=frecency` ranks by. Never raises; a file that cannot be written is
---not worth interrupting the user for.
---@param tasks Tasks.Task[]|{ id: string }[]
---@return boolean recorded
function M.touch(tasks)
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
  return core.header(state.shown, state.filter, state.area, state.sort)
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

---`s` / `p`: advance the field of every target in one batch.
---@param state Tasks.DashState
---@param tasks Tasks.Task[]
---@param field "status"|"prio"
---@return Tasks.DashSetResult|nil result
function M.cycle(state, tasks, field)
  if #tasks == 0 then
    return nil
  end
  local prog = new_progress("[tasks.dash] " .. field)
  local ran, res = pcall(core.apply_set, core.plan_cycle(tasks, field), { root = state.root })
  if not ran then
    -- An unexpected error must not leave the statusline progress (and its timer) running for good.
    if prog then
      prog:finish("failed")
    end
    error(res, 0)
  end
  refresh_buffers(res)
  M.touch(res.changed)
  local level, text = core.describe_set(field, res)
  if prog then
    prog:finish(("%d changed, %d failed"):format(#res.changed, #res.failed))
  end
  notify[level](text)
  return res
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
  end)
end

---`f`: pick a dimension, then a value; empty choices clear.
---@param state Tasks.DashState
---@param after fun()  # Called once, changed or not.
function M.set_filter(state, after)
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
    if dim == "stale-refs" then
      state.filter = core.set_dim(state.filter, "stale-refs", not state.filter.stale_refs or nil)
      persist(state)
      after()
      return
    end
    local scope = core.load({ root = state.root, area = state.area, filter = {} })
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
function M.cycle_sort(state)
  state.sort = core.cycle_sort(state.sort)
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
function M.preview_task(task)
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
function M.open_area_doc(state, task, which)
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

M.HELP = {
  " Task dashboard ",
  "",
  " <CR>        open the file(s)  (counts as a visit for the frecency sort)",
  " <Tab>       mark / unmark (marked tasks are the target of s p D e)",
  " s           advance status of marked (else current) tasks",
  " p           advance prio:  none -> 1 -> 2 -> 3 -> none",
  " D           finish (asks first, moves to Backlog/)",
  " f           set a filter chip (status prio effort kind category severity tag blocked stale-refs)",
  " o           cycle the sort: default -> prio-effort (small first) -> severity (critical first)",
  "             -> frecency (most opened / changed first, fades over ~2 weeks) -> default",
  " e           export marked (else all shown) tasks (also: preview in the browser)",
  " gp          preview the task file in the browser (mdview.nvim)",
  " r           rescan the vault now (the list also refreshes by itself when a task",
  "             or Backlog file changes; cursor and marks stay on the same tasks)",
  " gb / gr     Backlog picker / ROADMAP.md of the area under the cursor",
  " g?          this help",
  "",
  " Letters work in the list. In the input window use Alt:",
  " <M-s> <M-p> <M-d> <M-f> <M-o> <M-e> <M-r> <M-b>(backlog) <M-m>(roadmap) <M-v>(preview) <M-?>",
  " (any key closes this help)",
}

---Float with the key help; any key closes it again (the picker keeps focus).
function M.show_help()
  require("tasks_nvim.ui.help_float").open(M.HELP, "tasks_dash_help")
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
  if not res or core.signature(res.tasks) == state.signature then
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
  }, M.config.watch_opts or {}))
  -- A handle factory that raises must not take the open picker down with it (the caller's pcall
  -- would open the plain list on top of it) and must not leave the handles it did start behind.
  local ran, ok, err = pcall(w.start, w)
  if not ran then
    pcall(w.stop, w)
    ok, err = false, ok
  end
  if not ok then
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

---@param Snacks table
---@param state Tasks.DashState
local function open_snacks(Snacks, state)
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
        open_state(state, { backend = "snacks" })
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
      if held(function()
        return M.cycle(state, tasks, "status")
      end) then
        refresh_keep(picker, false)
      end
    end,
    tasks_prio = function(picker)
      local tasks = targets(picker, true)
      if held(function()
        return M.cycle(state, tasks, "prio")
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
      M.cycle_sort(state)
      refresh_keep(picker, true)
    end,
    ---`<CR>`: a visit for the frecency sort, then snacks' own jump.
    tasks_open = function(picker, item, action)
      M.touch(targets(picker, true))
      return Snacks.picker.actions.jump(picker, item, action)
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
        M.set_filter(state, reopen)
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
      picker:close()
      vim.schedule(function()
        M.open_area_doc(state, task, "backlog")
      end)
    end,
    tasks_roadmap = function(picker)
      local task = current_task(picker)
      picker:close()
      vim.schedule(function()
        M.open_area_doc(state, task, "roadmap")
      end)
    end,
    tasks_preview = function(picker)
      local task = current_task(picker)
      picker:close()
      vim.schedule(function()
        M.preview_task(task)
      end)
    end,
    tasks_help = function()
      M.show_help()
    end,
  }

  -- Letters in the list window (nothing is typed there); Alt chords in the input
  -- window, so its normal-mode edits (`s` `p` `D` `e` ...) and the search typing
  -- in insert mode stay untouched.
  local letters = {
    s = { "tasks_status", "<M-s>" },
    p = { "tasks_prio", "<M-p>" },
    D = { "tasks_done", "<M-d>" },
    f = { "tasks_filter", "<M-f>" },
    o = { "tasks_sort", "<M-o>" },
    e = { "tasks_export", "<M-e>" },
    r = { "tasks_rescan", "<M-r>" },
    gb = { "tasks_backlog", "<M-b>" },
    gr = { "tasks_roadmap", "<M-m>" },
    gp = { "tasks_preview", "<M-v>" },
    ["g?"] = { "tasks_help", "<M-?>" },
  }
  local list_keys, input_keys = {}, {}
  for key, spec in pairs(letters) do
    list_keys[key] = spec[1]
    input_keys[spec[2]] = { spec[1], mode = { "n", "i" } }
  end

  local picker = Snacks.picker({
    source = "wkdbook_tasks",
    title = title_of(state),
    finder = function(_, ctx)
      local items = {}
      for _, t in ipairs(reload(state)) do
        items[#items + 1] = { text = core.search_text(t), file = t.path, task = t }
      end
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
      return core.parts(item.task, state.widths)
    end,
    preview = "file",
    confirm = "tasks_open",
    -- An empty result (a filter that matches nothing) must stay open: `f` is how
    -- the user gets out of it.
    show_empty = true,
    actions = actions,
    win = { input = { keys = input_keys }, list = { keys = list_keys } },
    -- Every way out of the picker (jump, detour, <Esc>, focus lost) ends here:
    -- the watcher's handles and timer go with it.
    on_close = function()
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
      return core.line(t, state.widths)
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
          M.touch({ task })
          local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(task.path))
          if not ok then
            notify.error(("cannot open %s: %s"):format(task.path, tostring(err)))
          end
        end,
      },
      {
        label = "preview the file (mdview)",
        run = function()
          M.preview_task(task)
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
          M.set_filter(state, again)
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
          M.open_area_doc(state, task, "backlog")
        end,
      },
      {
        label = "ROADMAP.md of the area",
        run = function()
          M.open_area_doc(state, task, "roadmap")
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

---@param state Tasks.DashState
---@param opts? Tasks.DashOpts
function open_state(state, opts)
  opts = opts or {}
  if opts.backend ~= "select" then
    local ok, Snacks = pcall(require, "snacks")
    if ok and type(Snacks) == "table" and Snacks.picker then
      local opened, err = pcall(open_snacks, Snacks, state)
      if opened then
        return
      end
      notify.warn(("snacks picker failed (%s), using the plain list"):format(tostring(err)))
    end
  end
  open_select(state)
end

---Open the dashboard for what `:Tasks list` collected. Never raises.
---@param v Tasks.View
---@param opts? Tasks.DashOpts
---@return Tasks.DashState|nil state
function M.open(v, opts)
  local ok, state = pcall(M.new_state, v, opts)
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
