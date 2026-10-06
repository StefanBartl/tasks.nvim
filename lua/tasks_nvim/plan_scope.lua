---@module 'tasks_nvim.plan_scope'
---@brief Reads the vault and hands `plan` what it needs: the open tasks, which ids are finished, the scope asked for.
---@description
--- The impure edge of the plan: `plan`, `estimate` and `next_pick` take data, this module fetches it. One scan of the
--- open tasks, finished ids looked up in the Backlogs only when a blocker is not open (and remembered), the scope
--- cut the way `task plan` is called: an area, `--for=<id>` (the task and everything before it, across areas), or the
--- whole vault, narrowed by a `Tasks.Filter` like `list`.
---
--- Also the marker blocks of hand-written documents (`<!-- GENERATED:plan scope=... -->`): `refresh_document` (every
--- block of one file, after a finish) and `write_block` (`plan --write=<file>`).
---
--- Not its job: the calculation (`plan`), rendering (`plan_view`), the command line (`cli`, `ui.cmd`).

local filter_opts = require("tasks_nvim.filter_opts")
local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")
local plan_view = require("tasks_nvim.plan_view")
local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")

local M = {}

---@class Tasks.PlanScopeOpts
---@field root? string
---@field area? string
---@field for_id? string
---@field plan_id? string             # The plan file (`<area>/<slug>`): the tasks that name it with `plan:`.
---@field filter? Tasks.Filter

---@class Tasks.PlanScope
---@field plan Tasks.Plan
---@field tasks Tasks.Task[]          # The scope.
---@field index Tasks.PlanIndex
---@field done? Tasks.Task[]          # Finished tasks of the area (only for an unfiltered area scope): the progress figure.
---@field plan_file? Tasks.PlanFile   # The plan file of a `plan_id` scope.
---@field errors string[]             # Folders that could not be read: the plan may be incomplete.
---@field title string

---What one pass over the vault yields, shared by everything that needs it (a document with ten marker blocks must not
---scan the vault ten times).
---@class Tasks.PlanShared
---@field root? string
---@field index Tasks.PlanIndex
---@field open Tasks.Task[]           # Every open task of the vault.
---@field errors string[]             # Folders that could not be read.
---@field files Tasks.PlanFile[]      # Every open plan file.
---@field finished? table<string, boolean>  # Slugs of every Backlog file (filled when a block name is looked up).

---Every open task of the vault and a finished-id lookup: what `plan.ready` and `plan.classify` need, whatever the
---area of the list being filtered (a blocker may live anywhere). A task that says `status: done` but still sits in
---`ROADMAP/tasks/` is finished too: it blocks nobody.
---`scanned` is a scan the caller already made (`{ all, errors }`, what `scan.all` returns): it is not repeated.
---@param root? string
---@param scanned? { all: Tasks.Task[], errors?: string[] }
---@return Tasks.PlanShared|nil shared
---@return string|nil err
function M.shared(root, scanned)
  local all, errors
  if scanned then
    all, errors = scanned.all, scanned.errors
  else
    all, errors = scan.all({ root = root })
  end
  if not all then
    return nil, tostring(errors)
  end
  local open, done_here = {}, {}
  for _, t in ipairs(all) do
    if model.is_open_status(t.status) then
      open[#open + 1] = t
    elseif t.status == "done" then
      done_here[t.id] = true
    end
  end
  local finished = scan.finished_lookup({ root = root })
  local files = plans.all({ root = root }) or {}
  local index = plan.index(open, function(id)
    return done_here[id] == true or finished(id)
  end, files)
  -- which file a ref means (the files two tasks "both change" are the same file, not the same name)
  index.file_key = require("tasks_nvim.staleness").file_key({ root = root })
  return {
    root = root,
    index = index,
    open = open,
    errors = type(errors) == "table" and errors or {},
    files = files,
  },
    nil
end

---@param root? string
---@param scanned? { all: Tasks.Task[], errors?: string[] }
---@return Tasks.PlanIndex|nil index
---@return Tasks.Task[]|string open_or_err
---@return string[]|nil errors
function M.index(root, scanned)
  local shared, err = M.shared(root, scanned)
  if not shared then
    return nil, tostring(err), nil
  end
  return shared.index, shared.open, shared.errors
end

---Keep the tasks that are ready (`which = "ready"`) or wait on an open blocker (`which = "waiting"`), judged against
---EVERY open task of the vault: a blocker may sit in another area than the list being filtered.
---@param tasks Tasks.Task[]
---@param which "ready"|"waiting"
---@param root? string
---@param shared? Tasks.PlanShared   # The pass over the vault the caller already made.
---@return Tasks.Task[]|nil kept
---@return string|nil err
function M.filter_readiness(tasks, which, root, shared)
  local index, everything
  if shared then
    index = shared.index
  else
    index, everything = M.index(root)
    if not index then
      return nil, tostring(everything)
    end
  end
  local kept = {}
  for _, t in ipairs(tasks) do
    local state = plan.classify(t, index)
    local is_ready = state == "ready" or state == "decision"
    local is_waiting = state == "waiting" or state == "stuck"
    if (which == "ready" and is_ready) or (which == "waiting" and is_waiting) then
      kept[#kept + 1] = t
    end
  end
  return kept, nil
end

---The ids of the candidates, for "it is ambiguous: a/x, b/x".
---@param list { id: string }[]
---@return string
local function ids_of(list)
  local ids = {}
  for _, item in ipairs(list) do
    ids[#ids + 1] = item.id
  end
  return table.concat(ids, ", ")
end

---Slugs of everything below an area's `Backlog/`, over all areas (one walk, remembered in `shared`).
---@param shared Tasks.PlanShared
---@return table<string, boolean>
local function finished_slugs(shared)
  if not shared.finished then
    local set = {}
    for _, area in ipairs(vault.areas(shared.root)) do
      for slug in pairs(scan.backlog_slugs(area.name, { root = shared.root }) or {}) do
        set[slug] = true
      end
    end
    shared.finished = set
  end
  return shared.finished
end

---What a block stands for. The attributes of its start marker name the target exactly (`plan=<id>`, `for=<id>`,
---`area=<name>`: `plan --write` records them); without them the block's name is read: an area, an open plan's slug
---or id, `all`, or `for-<slug>` (the open task of that slug). A slug that two plans (or tasks) share is ambiguous:
---the block is skipped with the candidates named, never refreshed from a guess.
---`nil, reason, finished` when it names nothing that is open; `finished` is true when it names something that was
---finished (a closed plan's block is history: it is left as it is, and nothing is said about it).
---@param key string
---@param root string
---@param attrs? table<string, string>
---@param shared? Tasks.PlanShared
---@return Tasks.PlanScopeOpts|nil opts
---@return string|nil reason
---@return boolean|nil finished
function M.resolve_block(key, root, attrs, shared)
  attrs = attrs or {}
  if attrs.plan then
    -- A recorded target that is no longer open: finished (history, said nothing about) or gone (a skip).
    local found, ferr = plans.find(attrs.plan, { root = root })
    if not found then
      return nil, tostring(ferr), scan.find_done(attrs.plan, { root = root }) ~= nil
    end
    return { root = root, plan_id = attrs.plan }, nil
  elseif attrs["for"] then
    if not shared then
      local err
      shared, err = M.shared(root)
      if not shared then
        return nil, tostring(err), nil
      end
    end
    if not shared.index.open[attrs["for"]] then
      return nil,
        ("the block `%s` names the task %s, which is not open"):format(key, attrs["for"]),
        scan.find_done(attrs["for"], { root = root }) ~= nil
    end
    return { root = root, for_id = attrs["for"] }, nil
  elseif attrs.area then
    if not vault.has_area(root, attrs.area) then
      return nil,
        ("the block `%s` names an area that does not exist: %s"):format(key, attrs.area),
        false
    end
    return { root = root, area = attrs.area }, nil
  end
  if key == "all" then
    return { root = root }, nil
  end
  if vault.has_area(root, key) then
    return { root = root, area = key }, nil
  end
  if not shared then
    local err
    shared, err = M.shared(root)
    if not shared then
      return nil, tostring(err), nil
    end
  end
  local matches = {}
  for _, file in ipairs(shared.files) do
    if file.slug == key or file.id == key then
      matches[#matches + 1] = file
    end
  end
  if #matches == 1 then
    return { root = root, plan_id = matches[1].id }, nil
  elseif #matches > 1 then
    return nil,
      ("the block `%s` is ambiguous (%s): name one with plan=<id> in its marker"):format(
        key,
        ids_of(matches)
      ),
      false
  end
  local slug = key:match("^for%-(.+)$")
  if slug then
    for _, t in ipairs(shared.open) do
      if t.slug == slug or t.id == slug then
        matches[#matches + 1] = t
      end
    end
    if #matches == 1 then
      return { root = root, for_id = matches[1].id }, nil
    elseif #matches > 1 then
      return nil,
        ("the block `%s` is ambiguous (%s): name one with for=<id> in its marker"):format(
          key,
          ids_of(matches)
        ),
        false
    end
  end
  local name = slug or key
  local finished
  if name:find("/", 1, true) then
    finished = scan.find_done(name, { root = root }) ~= nil
  else
    finished = finished_slugs(shared)[name] == true
  end
  if finished then
    return nil, ("the block `%s` names something that is finished"):format(key), true
  end
  return nil, ("the block `%s` names no area, open plan or open task"):format(key), false
end

-- ── the attributes of a marker: how the block was made ──

local FILTER_KEYS = {
  "status",
  "prio",
  "effort",
  "kind",
  "tag",
  "category",
  "severity",
  "value",
  "actor",
  "stale",
}
local FILTER_FLAGS = { "stale_refs", "blocked", "unestimated" }

---What a marker records of a `plan --write`: the target, the view (`ready`, `steps`) and the filters, so the refresh
---after a finish builds the SAME block (and `--check` agrees with it). A value that cannot live on a marker line
---(whitespace, `--`) is an error: it would silently not be recorded.
---@param filter_opt table                       # What `filter_opts.parse` was given (`today` is not recorded).
---@param view { ready?: boolean, steps?: boolean }
---@param target { area?: string, plan_id?: string, for_id?: string }
---@param key? string                            # The block's name: an area that IS the name needs no `area=`.
---@return table<string, string>|nil attrs
---@return string|nil err
function M.marker_attrs(filter_opt, view, target, key)
  local attrs = {}
  ---@param name string
  ---@param value any
  ---@return string|nil err
  local function put(name, value)
    local text = tostring(value)
    if text == "" or text:find("%s") or text:find("--", 1, true) then
      return ("--%s=%s cannot be recorded in a marker line (no blanks, no `--`)"):format(
        name:gsub("_", "-"),
        text
      )
    end
    attrs[name] = text
  end
  for _, word in ipairs(FILTER_KEYS) do
    if filter_opt[word] ~= nil then
      local err = put(word, filter_opt[word])
      if err then
        return nil, err
      end
    end
  end
  for _, word in ipairs(FILTER_FLAGS) do
    if filter_opt[word] == true then
      attrs[word] = "1"
    end
  end
  if view.ready then
    attrs.ready = "1"
  end
  if view.steps then
    attrs.steps = "1"
  end
  local area = target.area ~= key and target.area or nil
  for name, value in pairs({ plan = target.plan_id, ["for"] = target.for_id, area = area }) do
    local err = put(name, value)
    if err then
      return nil, err
    end
  end
  return attrs, nil
end

---The filter a marker records.
---@param attrs table<string, string>
---@param root string
---@return Tasks.Filter|nil filter
---@return string|nil err
local function filter_of(attrs, root)
  local opt = {}
  for _, key in ipairs(FILTER_KEYS) do
    opt[key] = attrs[key]
  end
  for _, key in ipairs(FILTER_FLAGS) do
    opt[key] = attrs[key] == "1" or nil
  end
  local filter, err = filter_opts.parse(opt)
  if not filter then
    return nil, err
  end
  filter.ref_opts = { root = root }
  return filter, nil
end

---The Markdown of a loaded scope, as a block body.
---@param scope Tasks.PlanScope
---@param attrs table<string, string>
---@return string
local function block_body(scope, attrs)
  return plan_view.markdown(scope.plan, {
    title = scope.title,
    done = scope.done,
    ready_only = attrs.ready == "1",
    with_steps = attrs.steps == "1",
    plan_file = scope.plan_file,
    block = true,
  })
end

---The text of a plan that was finished a moment ago, for the block that stands for it: by the recorded `plan=`, by an
---id as block name, or by a slug that no OPEN plan shares (then it is the closed one).
---@param block Tasks.MarkerBlock
---@param closed table<string, string>
---@param shared fun(): Tasks.PlanShared|nil
---@param root string
---@return string|nil
local function closed_text(block, closed, shared, root)
  if block.attrs.plan then
    return closed[block.attrs.plan]
  elseif block.scope:find("/", 1, true) then
    return closed[block.scope]
  end
  -- the order of `resolve_block`: a recorded area / task, `all` and an area's name stand for what they name, never
  -- for a plan that merely has the same slug
  if
    block.attrs.area
    or block.attrs["for"]
    or block.scope == "all"
    or vault.has_area(root, block.scope)
  then
    return nil
  end
  local found
  for id, text in pairs(closed) do
    if (id:match("([^/]+)$")) == block.scope then
      if found then
        return nil
      end
      found = text
    end
  end
  if found then
    local sh = shared()
    for _, file in ipairs(sh and sh.files or {}) do
      if file.slug == block.scope then
        return nil
      end
    end
  end
  return found
end

---Refresh every marker block of a document: only the blocks change, the rest of the file (and its line endings, line
---by line) stays. Nothing is written when nothing changed. The vault is read once for all the blocks, and the file is
---read again right before it is written: a change made while the blocks were being worked out is kept (the blocks
---are put into the NEW text), never overwritten.
---`closed` names plans finished a moment ago (plan id -> text): their block gets that text as its last state
---instead of being left showing tasks that are done.
---@param path string
---@param root string
---@param closed? table<string, string>
---@return { changed: boolean, refreshed: string[], skipped: { scope: string, reason: string }[] }|nil result
---@return string|nil err
function M.refresh_document(path, root, closed)
  local text, err = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local shared_value, shared_err, shared_done
  ---@return Tasks.PlanShared|nil
  local function shared()
    if not shared_done then
      shared_done = true
      shared_value, shared_err = M.shared(root)
    end
    return shared_value
  end
  -- what each distinct block (its start marker line is its identity) turned out to be: { body } or { skip } or {}
  local computed = {}
  ---@param block Tasks.MarkerBlock
  ---@return { body?: string, skip?: string }
  local function compute(block)
    local sh
    local closed_body = closed and closed_text(block, closed, shared, root)
    if closed_body then
      return { body = closed_body }
    end
    sh = shared()
    if not sh then
      return { skip = tostring(shared_err) }
    end
    local scope_opts, reason, finished = M.resolve_block(block.scope, root, block.attrs, sh)
    if finished then
      return {} -- history: left exactly as it is
    elseif not scope_opts then
      return { skip = reason or "could not be read" }
    end
    local filter, ferr = filter_of(block.attrs, root)
    if not filter then
      return { skip = "its recorded filter is invalid: " .. tostring(ferr) }
    end
    scope_opts.filter = filter
    local scope, lerr = M.load(scope_opts, sh)
    if not scope then
      return { skip = tostring(lerr) }
    elseif #scope.errors > 0 then
      return {
        skip = ("a folder could not be read (%s): the block was left as it is"):format(
          tostring(scope.errors[1])
        ),
      }
    end
    return { body = block_body(scope, block.attrs) }
  end

  local result = { changed = false, refreshed = {}, skipped = {} }
  for _ = 1, 3 do
    local skipped, noted = {}, {}
    ---@param scope_name string
    ---@param reason string
    local function skip(scope_name, reason)
      local note = scope_name .. "\n" .. reason
      if not noted[note] then
        noted[note] = true
        skipped[#skipped + 1] = { scope = scope_name, reason = reason }
      end
    end
    local fresh, rerr, _, refreshed = plan_view.replace_blocks(text, function(block)
      if block.err then
        skip(block.scope, block.err)
        return nil
      end
      local identity = plan_view.start_line(block.scope, block.attrs)
      local res = computed[identity]
      if not res then
        res = compute(block)
        computed[identity] = res
      end
      if res.skip then
        skip(block.scope, res.skip)
      end
      return res.body
    end)
    if not fresh then
      return nil, ("%s: %s"):format(path, tostring(rerr))
    end
    result.skipped = skipped
    result.refreshed = refreshed or {}
    if fresh == text then
      return result, nil
    end
    local now = fsio.read(path)
    if now == text then
      -- a document the user named may be a symlink to the original: write through it
      local ok, werr = fsio.write_atomic(path, fresh, { follow_symlinks = true })
      if not ok then
        return nil, ("cannot write %s: %s"):format(path, tostring(werr))
      end
      result.changed = true
      return result, nil
    end
    if not now then
      break
    end
    text = now -- edited meanwhile: the same blocks go into the new text
  end
  return nil, ("%s changed while its blocks were being refreshed; nothing was written"):format(path)
end

---`plan --write=<file>` (and `--check`): the block of `opts.key` in a hand-written document gets the generated text of
---a loaded scope, nothing else in the file changes. The start marker is rewritten with `opts.attrs`: it records how
---the block was made, which is what a later refresh reads. `--check` (`opts.check`) writes nothing and says whether
---the block is out of date. A scope some folder of which could not be read is not written: the block would be a
---degraded copy of the plan.
---@param path string
---@param scope Tasks.PlanScope
---@param opts { key: string, attrs: table<string, string>, check?: boolean, today?: string }
---@return { state: "written"|"unchanged"|"stale"|"current" }|nil result
---@return string|nil err
function M.write_block(path, scope, opts)
  if #scope.errors > 0 then
    return nil,
      ("a folder could not be read (%s): the block would be incomplete, nothing was written"):format(
        tostring(scope.errors[1])
      )
  end
  local text, rerr = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(rerr))
  end
  local fresh, err, changed =
    plan_view.replace_block(text, opts.key, block_body(scope, opts.attrs), opts.attrs)
  if not fresh then
    return nil, tostring(err)
  end
  if opts.check then
    return { state = changed and "stale" or "current" }, nil
  end
  if not changed then
    return { state = "unchanged" }, nil
  end
  -- Read again before writing: an edit made since the first read is not overwritten.
  if fsio.read(path) ~= text then
    return nil,
      ("%s changed while it was being read; nothing was written, run it again"):format(path)
  end
  local ok, werr = fsio.write_atomic(path, fresh, { follow_symlinks = true })
  if not ok then
    return nil, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return { state = "written" }, nil
end

---@param opts Tasks.PlanScopeOpts
---@param shared? Tasks.PlanShared   # The pass over the vault the caller already made (see `shared`).
---@return Tasks.PlanScope|nil scope
---@return string|nil err
function M.load(opts, shared)
  if not shared then
    local err
    shared, err = M.shared(opts.root)
    if not shared then
      return nil, tostring(err)
    end
  end
  local index, open, errors = shared.index, shared.open, shared.errors
  local tasks, title, plan_file
  local whole_area = false
  if opts.plan_id then
    local found, perr = plans.find(opts.plan_id, { root = opts.root })
    if not found then
      return nil, tostring(perr)
    end
    plan_file = found
    tasks = plans.members(found.id, open)
    title = "plan " .. found.id
  elseif opts.for_id then
    local closure = plan.scope_for(index, opts.for_id)
    if not closure then
      return nil, "no such open task: " .. opts.for_id
    end
    tasks = closure
    title = "for " .. opts.for_id
  elseif opts.area then
    tasks = {}
    for _, t in ipairs(open) do
      if t.area == opts.area then
        tasks[#tasks + 1] = t
      end
    end
    title = opts.area
    whole_area = true
  else
    tasks = open
    title = "all areas"
  end
  local before = #tasks
  if opts.filter and next(opts.filter) ~= nil then
    tasks = model.filter(tasks, opts.filter)
  end

  ---@type Tasks.PlanScope
  local scope = {
    plan = plan.build(tasks, index),
    tasks = tasks,
    index = index,
    errors = errors or {},
    title = title or "",
    plan_file = plan_file,
  }
  -- The area's history is the progress figure's other half; it only fits the whole, unfiltered area (against a
  -- narrowed list it would read "98 % done").
  if whole_area and #tasks == before then
    local finished = scan.backlog(opts.area, { root = opts.root })
    scope.done = finished or {}
  end
  return scope, nil
end

return M
