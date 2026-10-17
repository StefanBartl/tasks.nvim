---@module 'tasks_nvim.moves'
---@brief Moving a task to another area: the report of what the move would break (`preview`) and the move (`move`).
---@description
--- A task id is `<area>/<slug>`, so moving a task changes its id, and every place that names the old id would point
--- nowhere afterwards: the `blocked_by` and `after` of other tasks, the `target` of a plan file, a `refs:` entry that
--- is the id, a generated block in a document. `preview` answers the question a front end has to ask first: can it
--- be done at all (the area exists, the slug is free there) and what would dangle (nothing is written).
---
--- `move` (stage 2) moves the file, or the folder of a folder task, rewrites the `blocked_by`, `after` and `refs` of
--- the tasks and the `target` of the plans that name the old id, regenerates the index of both areas and puts every
--- file back when a step fails (`rollback incomplete: <path>` names what could not be). A document that names the id
--- is not rewritten: its generated blocks are refreshed, a hand-written mention is told in `notes`.
---
--- Not its job: `check` (which finds dangling ids after the fact).

local checkpoint = require("lib.nvim.checkpoint")
local fm = require("lib.nvim.markdown.frontmatter")

local done_flow = require("tasks_nvim.done_flow")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@class Tasks.MoveReference
---@field kind "blocked_by"|"after"|"plan_target"|"refs"|"document"
---@field id? string        # The task or plan that names the old id.
---@field path? string      # For a document: the file.

---@class Tasks.MovePreview
---@field id string
---@field to_area string
---@field new_id string
---@field from string            # The task file now.
---@field to string              # Where it would be.
---@field folder boolean
---@field ok boolean             # No conflict: the move could be made.
---@field conflicts { code: string, message: string }[]
---@field references Tasks.MoveReference[]   # Places that name the old id and would dangle.
---@field notes string[]

---What moving `id` to `to_area` would do and break.
---@param id string
---@param to_area string
---@param opts { root?: string }
---@return Tasks.MovePreview|nil preview
---@return string|nil err
---@return table|nil info   # `{ code = "not_found"|"invalid_argument" }`
function M.preview(id, to_area, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr, { code = "not_found" }
  end
  local task, ferr = scan.find(id, { root = root })
  if not task then
    return nil, ferr, { code = "not_found" }
  end
  if type(to_area) ~= "string" or not vault.valid_area(to_area) then
    return nil, "invalid area name: " .. tostring(to_area), { code = "invalid_argument" }
  end
  if not vault.has_area(root, to_area) then
    return nil, "unknown area: " .. to_area, { code = "not_found" }
  end
  if to_area == task.area then
    return nil, id .. " is in that area already", { code = "invalid_argument" }
  end
  local new_id = to_area .. "/" .. task.slug
  ---@type Tasks.MovePreview
  local out = {
    id = id,
    to_area = to_area,
    new_id = new_id,
    from = task.path,
    to = task.folder and vault.folder_task_path(root, to_area, task.slug)
      or vault.task_path(root, to_area, task.slug),
    folder = task.folder,
    ok = true,
    conflicts = {},
    references = {},
    notes = {},
  }

  -- the slug must be free in the target area: ids of tasks, finished tasks and plans are one namespace there
  ---@param code string
  ---@param message string
  local function conflict(code, message)
    out.conflicts[#out.conflicts + 1] = { code = code, message = message }
  end
  local open_path = vault.resolve_task(root, to_area, task.slug)
  if open_path then
    conflict("slug-taken", ("%s is an open task already"):format(new_id))
  end
  local slugs, serr = scan.backlog_slugs(to_area, { root = root })
  if not slugs then
    return nil, tostring(serr), { code = "io" }
  end
  if slugs[task.slug] then
    conflict("slug-taken", ("%s is a finished task already"):format(new_id))
  end
  if plans.find(new_id, { root = root }) then
    conflict("slug-taken", ("%s is a plan already"):format(new_id))
  end

  -- who names the old id
  local all, scan_errors = scan.all({ root = root })
  if not all then
    return nil, tostring(scan_errors), { code = "io" }
  end
  for _, t in ipairs(all) do
    if t.location == "roadmap" and t.id ~= id then
      if vim.tbl_contains(t.blocked_by or {}, id) then
        out.references[#out.references + 1] = { kind = "blocked_by", id = t.id }
      end
      if vim.tbl_contains(t.after or {}, id) then
        out.references[#out.references + 1] = { kind = "after", id = t.id }
      end
      if vim.tbl_contains(t.refs or {}, id) then
        out.references[#out.references + 1] = { kind = "refs", id = t.id }
      end
    end
  end
  local files = plans.all({ root = root }) or {}
  for _, file in ipairs(files) do
    if file.target == id then
      out.references[#out.references + 1] = { kind = "plan_target", id = file.id }
    end
  end
  for _, doc in ipairs(done_flow.marker_docs()) do
    local text = fsio.read(doc)
    if text and text:find(id, 1, true) then
      out.references[#out.references + 1] = { kind = "document", path = doc }
    end
  end
  table.sort(out.references, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return (a.id or a.path or "") < (b.id or b.path or "")
  end)

  -- what the task itself carries along
  if task.plan then
    for _, file in ipairs(files) do
      if file.id == task.plan and #file.areas > 0 and not vim.tbl_contains(file.areas, to_area) then
        out.notes[#out.notes + 1] = ("the plan %s does not list the area %s (check would warn)"):format(
          task.plan,
          to_area
        )
      end
    end
  end
  out.ok = #out.conflicts == 0
  return out, nil
end

---Replace `old` by `new` in a list of ids; nil when `old` is not in it.
---@param list string[]|nil
---@param old string
---@param new string
---@return string[]|nil
local function replaced(list, old, new)
  if not list or not vim.tbl_contains(list, old) then
    return nil
  end
  local out = {}
  for _, v in ipairs(list) do
    out[#out + 1] = v == old and new or v
  end
  return out
end

---Call an `fsio` function the way a rollback needs it: never raise.
---@param fn function
---@param ... any
---@return boolean ok
---@return string|nil err
local function attempt(fn, ...)
  local called, ok, err = pcall(fn, ...)
  if not called then
    return false, tostring(ok)
  end
  return ok == true, err
end

---@class Tasks.MoveOpts
---@field root? string
---@field today? string
---@field index? boolean           # Regenerate the index of both areas (default true).
---@field if_match? string         # The `etag` of the task file the caller saw.
---@field checkpoint_dir? string

---Move the open task `id` to `to_area`: the file (or folder) goes to the other area under the same slug, `updated` is
---set, every task that names the old id in `blocked_by`, `after` or `refs` and every plan whose `target` it is names the
---new id. A failure puts every file back (`rollback incomplete: <path>` names what could not be).
---@param id string
---@param to_area string
---@param opts? Tasks.MoveOpts
---@return table|nil result  # `{ id, new_id, area, from_area, from, to, rewritten, notes, etag_before, etag_after }`
---@return string|nil err
---@return table|nil info    # `{ code = "conflict"|"invalid_argument"|"not_found"|"io", ... }`
function M.move(id, to_area, opts)
  opts = opts or {}
  local report, err, info = M.preview(id, to_area, opts)
  if not report then
    return nil, err, info
  end
  if not report.ok then
    return nil, report.conflicts[1].message, { code = "invalid_argument" }
  end
  local root = vault.root(opts)
  ---@cast root string
  local today = opts.today or model.today()
  local task = scan.find(id, { root = root })
  if not task then
    return nil, "no such open task: " .. id, { code = "not_found" }
  end
  if fsio.is_link(task.path) then
    return nil, id .. " is a symbolic link: it is not moved", { code = "forbidden" }
  end
  local old_text, rerr = fsio.read(task.path)
  if not old_text then
    return nil, "cannot read " .. task.path .. ": " .. tostring(rerr), { code = "io" }
  end
  local etag = fsio.etag(old_text)
  if opts.if_match ~= nil and opts.if_match ~= etag then
    return nil,
      ("%s changed since it was read (its version is %s, not %s)"):format(
        id,
        etag,
        tostring(opts.if_match)
      ),
      { code = "conflict", id = id, expected = opts.if_match, actual = etag }
  end
  local new_text, uerr = fm.update_text(old_text, { { "updated", today } })
  if not new_text then
    return nil, "cannot update " .. task.path .. ": " .. tostring(uerr), { code = "io" }
  end

  -- what has to be rewritten: one patch per task, the plans, and the files the snapshot holds
  local patches, order = {}, {}
  local plan_files = {}
  local rewritten = {}
  local tracked = {
    vault.index_path(root, task.area),
    vault.index_path(root, to_area),
  }
  if not task.folder then
    tracked[#tracked + 1] = report.to
  end
  local notes = vim.deepcopy(report.notes)
  for _, ref in ipairs(report.references) do
    if ref.kind == "plan_target" then
      local file = plans.find(ref.id, { root = root })
      if file then
        plan_files[#plan_files + 1] = file
        tracked[#tracked + 1] = file.path
        rewritten[#rewritten + 1] = { kind = ref.kind, id = ref.id }
      end
    elseif ref.kind == "document" then
      notes[#notes + 1] = "a document names "
        .. id
        .. " and is not rewritten: "
        .. tostring(ref.path)
    else
      local other = scan.find(ref.id, { root = root })
      if other then
        if not patches[ref.id] then
          patches[ref.id] = { patch = {} }
          order[#order + 1] = ref.id
          tracked[#tracked + 1] = other.path
        end
        local list = replaced(other[ref.kind], id, report.new_id)
        if list then
          patches[ref.id].patch[ref.kind] = list
          rewritten[#rewritten + 1] = { kind = ref.kind, id = ref.id }
        end
      end
    end
  end

  local cp, cerr = checkpoint.create(tracked, { dir = opts.checkpoint_dir })
  if not cp then
    return nil, "cannot snapshot before moving: " .. tostring(cerr), { code = "io" }
  end

  local progress = { renamed = false, created = false, removed = false }
  local src_dir = task.folder and vault.task_dir(root, task.area, task.slug) or nil
  local dst_dir = task.folder and vault.task_dir(root, to_area, task.slug) or nil

  local function execute()
    local changed_msg = id .. " changed while it was being moved; nothing was changed, run it again"
    if task.folder then
      if fsio.is_dir(dst_dir) then
        return nil, dst_dir .. " exists"
      end
      local made, merr = fsio.mkdirp(fsio.dirname(dst_dir))
      if not made then
        return nil, "cannot create " .. fsio.dirname(dst_dir) .. ": " .. tostring(merr)
      end
      if fsio.read(task.path) ~= old_text then
        return nil, changed_msg
      end
      local ok, rn = fsio.rename(src_dir, dst_dir)
      if not ok then
        return nil, "cannot move " .. src_dir .. ": " .. tostring(rn)
      end
      progress.renamed = true
      local wrote, werr = fsio.write_atomic(report.to, new_text)
      if not wrote then
        return nil, "cannot write " .. report.to .. ": " .. tostring(werr)
      end
    else
      local ok, cerr2 = fsio.create_exclusive(report.to, new_text)
      if not ok then
        return nil, "cannot create " .. report.to .. ": " .. tostring(cerr2)
      end
      progress.created = true
      if fsio.read(task.path) ~= old_text then
        return nil, changed_msg
      end
      local removed, rm = fsio.remove(task.path)
      if not removed then
        return nil, "cannot remove " .. task.path .. ": " .. tostring(rm)
      end
      progress.removed = true
    end
    for _, other_id in ipairs(order) do
      local entry = patches[other_id]
      if next(entry.patch) ~= nil then
        local r, serr, sinfo =
          mutate.set(other_id, entry.patch, { root = root, today = today, index = false })
        if not r then
          return nil, "cannot rewrite " .. other_id .. ": " .. tostring(serr), sinfo
        end
      end
    end
    -- the target in the form it has (a bare `[[slug]]` still names the moved task and stays; an id or an
    -- `[[<area>/<slug>]]` names the old one and is written anew, in the form `links` asks for), like `set` does
    local resolver = wikilinks.resolver(root)
    local mode = wikilinks.mode()
    for _, file in ipairs(plan_files) do
      local wrote, werr = fsio.with_lock(file.path, function()
        local text = fsio.read(file.path)
        local parsed = text and fm.parse(text)
        local current = parsed and parsed.meta and parsed.meta.target
        local value = wikilinks.forms(current, mode, resolver)(report.new_id)
        return fm.update(file.path, { { "target", value }, { "updated", today } })
      end)
      if not wrote then
        return nil, "cannot rewrite " .. file.path .. ": " .. tostring(werr)
      end
    end
    if opts.index ~= false then
      for _, area in ipairs({ task.area, to_area }) do
        local res, ierr = index.write_area(area, { root = root })
        if not res then
          return nil, "cannot regenerate the index of " .. area .. ": " .. tostring(ierr)
        end
      end
    end
    return true
  end

  local called, ok, xerr, xinfo = pcall(execute)
  if not called then
    ok, xerr, xinfo = nil, tostring(ok), nil
  end
  if not ok then
    local stuck = {}
    if progress.renamed then
      local back, berr = attempt(fsio.rename, dst_dir, src_dir)
      if not back then
        stuck[#stuck + 1] = ("%s (cannot move it back to %s: %s)"):format(
          dst_dir,
          src_dir,
          tostring(berr)
        )
      else
        -- the moved file got `updated`: the original text again
        local w, werr = attempt(fsio.write_atomic, task.path, old_text)
        if not w then
          stuck[#stuck + 1] = ("%s (cannot restore it: %s)"):format(task.path, tostring(werr))
        end
      end
    end
    if progress.removed then
      local back, berr = attempt(fsio.create_exclusive, task.path, old_text)
      if not back and not fsio.is_file(task.path) then
        stuck[#stuck + 1] = ("%s (cannot restore it: %s; %s holds the text)"):format(
          task.path,
          tostring(berr),
          report.to
        )
        -- `report.to` is now the only holder of the text: the restore must not delete it
        checkpoint.forget(cp, report.to)
      end
    end
    local _, restore_errors = checkpoint.restore(cp)
    checkpoint.discard(cp)
    for _, e in ipairs(restore_errors) do
      stuck[#stuck + 1] = e.path
    end
    local msg = tostring(xerr)
    if #stuck > 0 then
      msg = msg .. " (rollback incomplete: " .. table.concat(stuck, ", ") .. ")"
    end
    -- the reason of the failing step keeps its code (`lock_stuck`, `conflict`, ...): the caller may act on it
    return nil, msg, xinfo or { code = "io" }
  end
  checkpoint.discard(cp)

  local after = fsio.read(report.to)
  local _, refresh_notes = done_flow.refresh_marker_docs({ root = root })
  for _, n in ipairs(refresh_notes or {}) do
    notes[#notes + 1] = n
  end
  return {
    id = id,
    new_id = report.new_id,
    area = to_area,
    from_area = task.area,
    from = task.path,
    to = report.to,
    folder = task.folder,
    rewritten = rewritten,
    notes = notes,
    etag_before = etag,
    etag_after = after and fsio.etag(after) or nil,
  },
    nil
end

return M
