---@module 'tasks_nvim.moves'
---@brief Moving a task to another area, stage 1: the report of what the move would break. Nothing is written.
---@description
--- A task id is `<area>/<slug>`, so moving a task changes its id, and every place that names the old id would point
--- nowhere afterwards: the `blocked_by` and `after` of other tasks, the `target` of a plan file, a `refs:` entry that
--- is the id, a generated block in a document. `preview` answers the question a front end has to ask first: can it
--- be done at all (the area exists, the slug is free there) and what would dangle. Stage 2 (rewriting those places
--- with a rollback) is a later step; until it exists the move itself is refused.
---
--- Not its job: the move (stage 2), `check` (which finds dangling ids after the fact).

local done_flow = require("tasks_nvim.done_flow")
local fsio = require("tasks_nvim.fsio")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

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

return M
