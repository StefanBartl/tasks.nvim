---@module 'tasks_nvim.plans'
---@brief Plan files: one Markdown file per undertaking under `<area>/ROADMAP/plans/`, that tasks point at with `plan:`.
---@description
--- A plan file holds what a human has to justify -- the goal, the boundaries, the definition of done, the names of the
--- stages -- and NO task list: the tasks carry the reference (`plan: <area>/<slug>`, `phase: <word>`), the plan is
--- drawn from them. Two tasks on two machines never collide on a list in the plan file.
---
--- Frontmatter (flat): `title`, `status` (`planning`, `doing`, `parked`, `done`), `areas` (the areas whose tasks may
--- belong), `target` (a task: "done when this is"), `phase_order` (stage names, in order), `gate` (`hard`: a stage
--- may not begin before the earlier ones are finished; absent: the order is only a soft hint), `created`, `updated`.
---
--- A plan is finished like a task (rule R6, moved to `Backlog/FEATURES/` with a row in the Backlog README) when its
--- last member task is done: `close` does it. Plans are optional: without a plan file and without `plan:` the world
--- is as before.
---
--- Not its job: drawing the plan from the members (`plan`), the engine's done chain (`done_flow` calls `close`).

local checkpoint = require("lib.nvim.checkpoint")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@type string[]
M.STATUSES = { "planning", "doing", "parked", "done" }

---@class Tasks.PlanFile
---@field id string                   # `<area>/<slug>`.
---@field area string
---@field slug string
---@field path string
---@field location "roadmap"|"backlog"
---@field title string
---@field status? string
---@field areas string[]
---@field target? string
---@field phase_order string[]
---@field gate? string                # `hard` or nil.
---@field created? string
---@field updated? string
---@field summary string
---@field errors string[]
---@field error_codes string[]
---@field valid boolean

---@param s any
---@return boolean
function M.is_status(s)
  return vim.tbl_contains(M.STATUSES, s)
end

---Read one plan file's text. Always returns a plan; a broken file carries `errors` (`valid = false`).
---@param text string
---@param ctx { path: string, area: string, slug?: string, location?: "roadmap"|"backlog" }
---@return Tasks.PlanFile
function M.parse(text, ctx)
  local slug = ctx.slug or model.slug_of(ctx.path, ctx.location or "roadmap")
  local errors, codes = {}, {}
  ---@param code string
  ---@param msg string
  local function bad(code, msg)
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end
  ---@type Tasks.PlanFile
  local plan = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    location = ctx.location or "roadmap",
    title = slug,
    areas = {},
    phase_order = {},
    summary = "",
    errors = errors,
    error_codes = codes,
    valid = false,
  }
  if not vault.valid_slug(slug) then
    bad("slug", "filename is not a kebab-case ASCII slug: " .. fsio.clean(slug))
  end
  local parsed, perr = fm.parse(text)
  if not parsed then
    bad("frontmatter-missing", "frontmatter unreadable: " .. tostring(perr))
  elseif not parsed.has_block then
    bad("frontmatter-missing", "no frontmatter block")
  else
    local meta = parsed.meta
    plan.title = model.field_text(meta.title, "title", bad) or slug
    if meta.title == nil then
      bad("title-missing", "title is missing")
    end
    local status = model.field_text(meta.status, "status", bad)
    if status then
      plan.status = status
      if not M.is_status(status) then
        bad(
          "plan-bad-status",
          ("unknown plan status '%s' (expected %s)"):format(status, table.concat(M.STATUSES, ", "))
        )
      end
    else
      bad("plan-bad-status", "status is missing")
    end
    plan.areas = model.field_list(meta.areas, "areas", bad)
    for _, a in ipairs(plan.areas) do
      if not vault.valid_area(a) then
        bad("plan-bad-area", "areas: invalid area name " .. fsio.clean(a))
      end
    end
    local target = model.field_text(meta.target, "target", bad)
    if target then
      local _, tslug, terr = vault.parse_id(target)
      if terr or not tslug then
        bad("plan-bad-target", "target: " .. (terr or ("expected <area>/<slug>, got " .. target)))
      else
        plan.target = target
      end
    end
    plan.phase_order = model.field_list(meta.phase_order, "phase_order", bad)
    for _, p in ipairs(plan.phase_order) do
      if not vault.valid_slug(p) then
        bad("bad-phase", "phase_order: '" .. fsio.clean(p) .. "' is no kebab-case word")
      end
    end
    local gate = model.field_text(meta.gate, "gate", bad)
    if gate then
      if gate == "hard" then
        plan.gate = "hard"
      else
        bad("plan-bad-gate", "gate must be `hard` or absent, got '" .. fsio.clean(gate) .. "'")
      end
    end
    for _, field in ipairs({ "created", "updated" }) do
      local date = model.field_text(meta[field], field, bad)
      if date then
        plan[field] = date
        if not model.is_date(date) then
          bad("bad-date", ("%s '%s' is not a date (YYYY-MM-DD)"):format(field, date))
        end
      end
    end
    plan.summary = model.field_text(meta.summary, "summary", bad)
      or model.first_paragraph(parsed.body)
  end
  plan.valid = #errors == 0
  return plan
end

---Read a plan file from disk.
---@param path string
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog" }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  local text, err = fsio.read(path)
  if not text then
    local plan = M.parse("", vim.tbl_extend("force", { path = path }, ctx))
    plan.errors = { "cannot read file: " .. tostring(err) }
    plan.error_codes = { "unreadable" }
    plan.valid = false
    return plan
  end
  return M.parse(text, vim.tbl_extend("force", { path = path }, ctx))
end

---The open plans of an area (`ROADMAP/plans/*.md`), by slug.
---@param area string
---@param opts? { root?: string }
---@return Tasks.PlanFile[]|nil plans
---@return string[]|string|nil errors
function M.area(area, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local dir = vault.plans_dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local errors = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.md$") then
      out[#out + 1] = M.from_file(dir .. "/" .. name, { area = area })
    end
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out, errors
end

---Every open plan of the vault.
---@param opts? { root?: string }
---@return Tasks.PlanFile[]|nil plans
---@return string|nil err
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out = {}
  for _, a in ipairs(vault.areas(root)) do
    local plans = M.area(a.name, { root = root })
    for _, plan in ipairs(plans or {}) do
      out[#out + 1] = plan
    end
  end
  return out, nil
end

---An open plan by id.
---@param id string
---@param opts? { root?: string }
---@return Tasks.PlanFile|nil plan
---@return string|nil err
function M.find(id, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local area, slug, id_err = vault.parse_id(id)
  if not area or not slug then
    return nil, id_err or ("expected <area>/<slug>, got " .. tostring(id))
  end
  local path = vault.plan_path(root, area, slug)
  if not fsio.is_file(path) then
    return nil, "no such open plan: " .. id
  end
  return M.from_file(path, { area = area, slug = slug }), nil
end

---The open tasks that belong to a plan (`plan: <id>`).
---@param plan_id string
---@param tasks Tasks.Task[]
---@return Tasks.Task[]
function M.members(plan_id, tasks)
  local out = {}
  for _, t in ipairs(tasks) do
    if t.plan == plan_id then
      out[#out + 1] = t
    end
  end
  return out
end

---@class Tasks.NewPlanOpts
---@field root? string
---@field title string
---@field areas? string[]|string
---@field target? string
---@field phases? string[]|string
---@field gate? string
---@field status? string
---@field summary? string
---@field slug? string
---@field today? string

---Create `<area>/ROADMAP/plans/<slug>.md` (never overwrites; a taken slug gets `-2`, `-3`, ...).
---@param area string
---@param opts Tasks.NewPlanOpts
---@return { id: string, path: string }|nil result
---@return string|nil err
function M.new(area, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area)
  end
  local title = type(opts.title) == "string" and vim.trim(fsio.clean(opts.title)) or ""
  if title == "" or title:find("[\r\n]") then
    return nil, "title must be one non-empty line"
  end
  local status = opts.status or "planning"
  if not M.is_status(status) or status == "done" then
    return nil,
      ("unknown plan status '%s' (expected planning, doing or parked)"):format(tostring(status))
  end
  local function list(value, what)
    if value == nil then
      return {}, nil
    end
    local out = {}
    local items = type(value) == "table" and value
      or vim.split(tostring(value), ",", { plain = true })
    for _, item in ipairs(items) do
      local t = vim.trim(tostring(item))
      if t ~= "" then
        if t:find("[,%[%]\"'#]") then
          return nil, what .. " item '" .. t .. "' must not contain , [ ] quotes or #"
        end
        out[#out + 1] = t
      end
    end
    return out, nil
  end
  local areas, aerr = list(opts.areas, "areas")
  if not areas then
    return nil, aerr
  end
  for _, a in ipairs(areas) do
    if not vault.valid_area(a) then
      return nil, "areas: invalid area name " .. a
    end
  end
  local phases, perr = list(opts.phases, "phases")
  if not phases then
    return nil, perr
  end
  for _, p in ipairs(phases) do
    if not vault.valid_slug(p) then
      return nil, "phases: '" .. p .. "' is no kebab-case word"
    end
  end
  if opts.target ~= nil then
    local _, tslug, terr = vault.parse_id(opts.target)
    if terr or not tslug then
      return nil, "target: " .. (terr or ("expected <area>/<slug>, got " .. tostring(opts.target)))
    end
  end
  if opts.gate ~= nil and opts.gate ~= "hard" then
    return nil, "gate must be `hard` or absent"
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local base = opts.slug or require("tasks_nvim.mutate").slugify(title)
  if not vault.valid_slug(base) or vault.is_reserved_name(base) then
    return nil, "invalid slug: " .. tostring(base)
  end

  local pairs_ = { { "title", title }, { "status", status } }
  if #areas > 0 then
    pairs_[#pairs_ + 1] = { "areas", areas }
  end
  if opts.target then
    pairs_[#pairs_ + 1] = { "target", opts.target }
  end
  if #phases > 0 then
    pairs_[#pairs_ + 1] = { "phase_order", phases }
  end
  if opts.gate then
    pairs_[#pairs_ + 1] = { "gate", opts.gate }
  end
  pairs_[#pairs_ + 1] = { "created", today }
  pairs_[#pairs_ + 1] = { "updated", today }
  local lead = opts.summary and (vim.trim(opts.summary) .. "\n\n") or ""
  local body = "\n"
    .. lead
    .. table.concat({
      "## Ziel und Abgrenzung",
      "",
      "<!-- Was dieses Vorhaben erreichen soll, und was nicht dazugehoert. -->",
      "",
      "## Definition of done",
      "",
      "<!-- Wann ist es fertig? -->",
      "",
      "## Entscheidungen",
      "",
      "<!-- Verweise auf decision-Tasks, nicht kopieren. -->",
      "",
      "## Notizen",
      "",
    }, "\n")
  local text, ferr = fm.update_text(body, pairs_, { create = true })
  if not text then
    return nil, "cannot build the plan file: " .. tostring(ferr)
  end

  local mkdir_ok, mkerr = fsio.mkdirp(vault.plans_dir(root, area))
  if not mkdir_ok then
    return nil, "cannot create " .. vault.plans_dir(root, area) .. ": " .. tostring(mkerr)
  end
  local n = 1
  while n < 1000 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local path = vault.plan_path(root, area, slug)
    local ok, err = fsio.create_exclusive(path, text)
    if ok then
      return { id = area .. "/" .. slug, path = path }, nil
    end
    if not fsio.is_exists(err) then
      return nil, "cannot create " .. path .. ": " .. tostring(err)
    end
    n = n + 1
  end
  return nil, "no free file name for plan " .. base
end

---Finish a plan: `status: done`, moved to `Backlog/FEATURES/YYYY-MM-DD_<slug>.md`, a row in the Backlog README. The
---finished copy and the README are snapshotted first and put back byte for byte when a step fails; the plan file
---is not removed before the finished copy is written.
---@param id string
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string }
---@return { id: string, from: string, to: string, readme: string }|nil result
---@return string|nil err
function M.close(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local plan, ferr = M.find(id, { root = root })
  if not plan then
    local finished = scan.find_done(id, { root = root })
    if finished then
      return { id = id, from = finished.path, to = finished.path, readme = "unchanged" }, nil
    end
    return nil, ferr
  end
  local today = opts.today or model.today()
  local date = opts.date or today
  if not (model.is_date(today) and model.is_date(date)) then
    return nil, "date must be YYYY-MM-DD"
  end
  local old_text, rd_err = fsio.read(plan.path)
  if not old_text then
    return nil, "cannot read " .. plan.path .. ": " .. tostring(rd_err)
  end
  local new_text, uerr = fm.update_text(old_text, { { "status", "done" }, { "updated", today } })
  if not new_text then
    return nil, "cannot update " .. plan.path .. ": " .. tostring(uerr)
  end
  local mutate = require("tasks_nvim.mutate")
  local rel = date .. "_" .. plan.slug .. ".md"
  local target = vault.backlog_dir(root, plan.area, "FEATURES") .. "/" .. rel
  if fsio.is_file(target) or fsio.is_dir(target) then
    return nil, "target exists: " .. target
  end
  local readme_path = vault.backlog_readme(root, plan.area)
  local readme_old
  if fsio.is_file(readme_path) then
    local text, r_err = fsio.read(readme_path)
    if not text then
      return nil, "cannot read " .. readme_path .. ": " .. tostring(r_err)
    end
    readme_old = text
  end
  local readme_new, readme_state = readme_old, "missing"
  if readme_old then
    local changed
    readme_new, changed = mutate.readme_add_row(
      readme_old,
      "FEATURES",
      rel,
      mutate.readme_row("FEATURES", rel, plan, date)
    )
    readme_state = changed and "updated" or "unchanged"
  end

  local tracked = { target }
  if readme_old then
    tracked[#tracked + 1] = readme_path
  end
  local cp, cerr = checkpoint.create(tracked, { dir = opts.checkpoint_dir })
  if not cp then
    return nil, "cannot snapshot before moving: " .. tostring(cerr)
  end
  local function fail(msg)
    local _, restore_errors = checkpoint.restore(cp)
    checkpoint.discard(cp)
    local stuck = {}
    for _, e in ipairs(restore_errors) do
      stuck[#stuck + 1] = e.path
    end
    if #stuck > 0 then
      msg = msg .. " (rollback incomplete: " .. table.concat(stuck, ", ") .. ")"
    end
    return nil, msg
  end
  local made, merr = fsio.mkdirp(fsio.dirname(target))
  if not made then
    return fail("cannot create " .. fsio.dirname(target) .. ": " .. tostring(merr))
  end
  local ok, werr = fsio.create_exclusive(target, new_text)
  if not ok then
    return fail("cannot create " .. target .. ": " .. tostring(werr))
  end
  if fsio.read(plan.path) ~= old_text then
    return fail(
      plan.path .. " changed while it was being finished; nothing was changed, run it again"
    )
  end
  local removed, rm_err = fsio.remove(plan.path)
  if not removed then
    return fail("cannot remove " .. plan.path .. ": " .. tostring(rm_err))
  end
  if readme_old and readme_new ~= readme_old then
    local wrote, rwerr = fsio.write_atomic(readme_path, readme_new)
    if not wrote then
      -- the plan file is gone and the finished copy is there: put the plan file back before the restore drops it
      fsio.create_exclusive(plan.path, old_text)
      return fail("cannot write " .. readme_path .. ": " .. tostring(rwerr))
    end
  end
  checkpoint.discard(cp)
  return { id = id, from = plan.path, to = target, readme = readme_state }, nil
end

return M
