---@module 'tasks_nvim.filter_opts'
---@brief The textual filter options of a front end (`--status=a,b`, `--prio=<=2`) turned into a `Tasks.Filter`.
---@description
--- Shared by the headless CLI, the editor commands and the dashboard, so all of them read the same words the same
--- way. Unknown words are an error, never silently ignored; "no value" (`--status=`) is an error too.
---
--- Not its job: applying a filter (`model.filter`), the grammar of the commands (`ui.routes`).

local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")

local M = {}

---Split a comma list (`doing, decision`) into trimmed, non-empty items.
---@param s string
---@return string[]
function M.split_commas(s)
  local out = {}
  if type(s) ~= "string" then
    return out
  end
  for item in s:gmatch("[^,]+") do
    local t = fsio.trim(item)
    if t ~= "" then
      out[#out + 1] = t
    end
  end
  return out
end

---An effort word as the file spells it: size words are case-insensitive here
---(`s` -> `S`), day values stay as they are.
---@param s string
---@return string|nil effort  nil when it is no valid effort
local function normalize_effort(s)
  local t = fsio.trim(s)
  if t:match("^%a+$") then
    t = t:upper()
  end
  return model.is_effort(t) and t or nil
end

---Turn the textual filter options of a front end (`--status=a,b`, `--prio=<=2`,
---`--effort=S,M` / `<=M`, `--kind`, `--tag`, `--category`, `--severity`,
---`--stale=<days>`, `--blocked`) into a `Tasks.Filter`.
---Shared by the headless CLI and the editor commands so both read the same
---words the same way. Unknown words are an error, never silently ignored.
---`stale` may be a number, a digit string or `refs` (same as `stale_refs`: a
---file named in `refs` changed since `updated`); `today` is passed through.
---@param opt { plan?: string, phase?: string, status?: string, prio?: string|integer, effort?: string, kind?: string, tag?: string, category?: string, severity?: string, value?: string|integer, actor?: string, stale?: string|integer, stale_refs?: boolean, blocked?: boolean, unestimated?: boolean, today?: string }
---@return Tasks.Filter|nil filter
---@return string|nil err
function M.parse(opt)
  ---@type Tasks.Filter
  local f = { today = opt.today }
  -- "No value" and "an invalid value" are different answers: `--status=` (a variable that expanded to
  -- nothing) is an error, not a filter that matches nothing and exits 0 (ERR-10).
  if opt.today ~= nil and not model.is_date(opt.today) then
    return nil, "--today must be YYYY-MM-DD, got '" .. tostring(opt.today) .. "'"
  end
  ---@param raw string
  ---@param flag string
  ---@return string[]|nil list
  ---@return string|nil err
  local function listed(raw, flag)
    local list = M.split_commas(raw)
    if #list == 0 then
      return nil, ("--%s needs a value"):format(flag)
    end
    return list, nil
  end
  if opt.status then
    local list, lerr = listed(opt.status, "status")
    if not list then
      return nil, lerr
    end
    f.status = list
    for _, s in ipairs(list) do
      if not model.is_status(s) then
        return nil, "unknown status in --status: " .. s
      end
    end
  end
  if opt.prio ~= nil then
    local raw = tostring(opt.prio)
    local max = raw:match("^<=(%d)$")
    if raw:sub(1, 2) == "<=" and not (max and model.to_prio(max)) then
      -- `<=0` and `<=9` used to be accepted and matched nothing (or everything) with exit 0.
      return nil, "--prio must be 1, 2, 3 (comma list) or <=1, <=2, <=3, got " .. raw
    end
    if max then
      f.prio_max = tonumber(max)
    else
      f.prio = {}
      local plist, perr = listed(raw, "prio")
      if not plist then
        return nil, perr
      end
      for _, p in ipairs(plist) do
        local n = model.to_prio(p)
        if not n then
          return nil, "--prio must be 1, 2, 3 (comma list) or <=N, got " .. raw
        end
        f.prio[#f.prio + 1] = n
      end
    end
  end
  if opt.kind then
    local list, lerr = listed(opt.kind, "kind")
    if not list then
      return nil, lerr
    end
    f.kind = list
    for _, k in ipairs(list) do
      if not model.is_kind(k) then
        return nil, "unknown kind in --kind: " .. k
      end
    end
  end
  if opt.tag then
    local list, lerr = listed(opt.tag, "tag")
    if not list then
      return nil, lerr
    end
    f.tag = list
  end
  if opt.category then
    local list, lerr = listed(opt.category, "category")
    if not list then
      return nil, lerr
    end
    f.category = list
    for _, c in ipairs(list) do
      if not model.is_category(c) then
        return nil, "unknown category in --category: " .. c
      end
    end
  end
  if opt.effort ~= nil then
    local raw = tostring(opt.effort)
    local max = raw:match("^<=(.+)$")
    if max then
      f.effort_max = normalize_effort(max)
      if not f.effort_max then
        return nil, "--effort must be XS..XL or days like 0.5d after <=, got " .. raw
      end
    else
      f.effort = {}
      for _, e in ipairs(M.split_commas(raw)) do
        local norm = normalize_effort(e)
        if not norm then
          return nil, "unknown effort in --effort: " .. e
        end
        f.effort[#f.effort + 1] = norm
      end
      if #f.effort == 0 then
        return nil, "--effort needs a value (XS..XL, days like 0.5d, or <=M)"
      end
    end
  end
  if opt.severity then
    f.severity = M.split_commas(opt.severity)
    if #f.severity == 0 then
      return nil, "--severity needs a value (" .. table.concat(model.SEVERITIES, ", ") .. ")"
    end
    for _, v in
      ipairs(f.severity --[[@as string[] ]])
    do
      if not model.is_severity(v) then
        return nil, "unknown severity in --severity: " .. v
      end
    end
  end
  if opt.value ~= nil then
    local raw = tostring(opt.value)
    local min = raw:match("^>=(%d)$")
    if raw:sub(1, 2) == ">=" and not (min and model.to_value(min)) then
      return nil, "--value must be 1..5 (comma list) or >=1 .. >=5, got " .. raw
    end
    if min then
      f.value_min = tonumber(min)
    else
      local vlist, verr = listed(raw, "value")
      if not vlist then
        return nil, verr
      end
      f.value = {}
      for _, v in ipairs(vlist) do
        local n = model.to_value(v)
        if not n then
          return nil, "--value must be 1..5 (comma list) or >=N, got " .. raw
        end
        f.value[#f.value + 1] = n
      end
    end
  end
  if opt.actor then
    local list, lerr = listed(opt.actor, "actor")
    if not list then
      return nil, lerr
    end
    f.actor = list
    for _, a in ipairs(list) do
      if not (model.is_actor(a) or a == "none") then
        return nil, "unknown actor in --actor: " .. a .. " (expected cdx, me, pair or none)"
      end
    end
  end
  if opt.stale ~= nil then
    local raw = tostring(opt.stale)
    if raw == "refs" then
      f.stale_refs = true
    elseif not raw:match("^%d+$") then
      return nil, ("--stale must be a whole number, got '%s' (or the word refs)"):format(raw)
    else
      f.stale = tonumber(raw)
    end
  end
  if opt.stale_refs then
    f.stale_refs = true
  end
  for _, name in ipairs({ "plan", "phase" }) do
    if opt[name] ~= nil then
      local list, lerr = listed(opt[name], name)
      if not list then
        return nil, lerr
      end
      f[name] = list
    end
  end
  if opt.blocked then
    f.blocked = true
  end
  if opt.unestimated then
    f.unestimated = true
  end
  return f, nil
end

return M
