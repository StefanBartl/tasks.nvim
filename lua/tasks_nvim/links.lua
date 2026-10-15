---@module 'tasks_nvim.links'
---@brief Where areas hang together: the links between the open tasks of different areas.
---@description
--- A link is one of four kinds, always read from the tasks themselves (nothing is guessed):
---  - `blocked_by` / `after`: an open task waits for, or comes after, an open task of another area;
---  - `refs`: a task names another area in a ref, as a commit (`lib.nvim@803de65`) or as an anchor
---    (`lib.nvim:cheatsheet`); a ref that names a path says nothing about the repo and is not a link;
---  - `plan`: the open tasks of one plan lie in more than one area (the plan file's `areas` list says who MAY join,
---    the members say who did).
---
--- The result is the pairs of areas with their edges, and for every task the areas it touches (its own and those of
--- every link it is part of, in both directions) - only the tasks that touch two or more are listed. The pure
--- computation; `contract.links` wraps it into the document.
---
--- Not its job: reading files, the document head, the JSON.

local M = {}

---The most edges one result carries in its pairs (the counts and the touched areas still cover all of them).
M.MAX_EDGES = 2000

---@class Tasks.LinkEdge
---@field from string       # The task the link starts at.
---@field from_area string
---@field to_area string
---@field kind "blocked_by"|"after"|"refs"|"plan"
---@field to? string        # The other task (`blocked_by`, `after`) or the plan (`plan`).
---@field ref? string       # The ref as written (`refs`).

---@class Tasks.LinkPair
---@field a string          # The area that sorts first.
---@field b string
---@field count integer
---@field kinds table<string, integer>
---@field edges Tasks.LinkEdge[]

---@class Tasks.Links
---@field edge_count integer
---@field truncated boolean
---@field pairs Tasks.LinkPair[]
---@field tasks { id: string, areas: string[] }[]

---The area a ref names, or nil: `lib.nvim@803de65` and `lib.nvim:anchor` (not a drive letter, not a URL).
---@param ref string
---@return string|nil
local function area_of_ref(ref)
  local s = vim.trim(ref)
  local sha_area = s:match("^([%w_.-]+)@%x+$")
  if sha_area then
    return sha_area
  end
  -- a drive letter (`C:\x`, `C:/x`) and a URL (`https://`) are no area
  if s:match("^%a:[/\\]") or s:match("^%a[%w+.-]*://") then
    return nil
  end
  return s:match("^([%w_.-]+):[^/\\%s]")
end

---@param list string[]|nil
---@return string[]  # without repeats, in order
local function unique(list)
  local seen, out = {}, {}
  for _, v in ipairs(list or {}) do
    if type(v) == "string" and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out
end

---@param open Tasks.Task[]  # the open tasks
---@param area_names string[]  # the areas of the vault
---@return Tasks.Links
function M.compute(open, area_names)
  local known = {}
  for _, name in ipairs(area_names) do
    known[name] = true
  end
  local by_id = {}
  for _, t in ipairs(open) do
    by_id[t.id] = t
  end

  ---@type table<string, table<string, boolean>>
  local touched = {}
  for _, t in ipairs(open) do
    touched[t.id] = { [t.area] = true }
  end
  ---@type Tasks.LinkEdge[]
  local edges, seen = {}, {}
  ---@param edge Tasks.LinkEdge
  local function add(edge)
    local key =
      table.concat({ edge.from, edge.to_area, edge.kind, edge.to or edge.ref or "" }, "\0")
    if seen[key] then
      return
    end
    seen[key] = true
    edges[#edges + 1] = edge
  end

  for _, t in ipairs(open) do
    for _, kind in ipairs({ "blocked_by", "after" }) do
      for _, id in ipairs(unique(t[kind])) do
        local other = by_id[id]
        if other and other.area ~= t.area then
          add({ from = t.id, from_area = t.area, to_area = other.area, kind = kind, to = other.id })
          touched[t.id][other.area] = true
          touched[other.id][t.area] = true
        end
      end
    end
    for _, ref in ipairs(unique(t.refs)) do
      local name = area_of_ref(ref)
      if name and name ~= t.area and known[name] then
        add({ from = t.id, from_area = t.area, to_area = name, kind = "refs", ref = ref })
        touched[t.id][name] = true
      end
    end
  end

  -- a plan whose open tasks lie in several areas links them
  local members = {}
  for _, t in ipairs(open) do
    if type(t.plan) == "string" and t.plan ~= "" then
      members[t.plan] = members[t.plan] or {}
      table.insert(members[t.plan], t)
    end
  end
  for plan_id, list in pairs(members) do
    local areas = {}
    for _, t in ipairs(list) do
      areas[t.area] = true
    end
    for _, t in ipairs(list) do
      for area in pairs(areas) do
        if area ~= t.area then
          add({ from = t.id, from_area = t.area, to_area = area, kind = "plan", to = plan_id })
          touched[t.id][area] = true
        end
      end
    end
  end

  table.sort(edges, function(x, y)
    if x.from ~= y.from then
      return x.from < y.from
    end
    if x.kind ~= y.kind then
      return x.kind < y.kind
    end
    if x.to_area ~= y.to_area then
      return x.to_area < y.to_area
    end
    return (x.to or x.ref or "") < (y.to or y.ref or "")
  end)

  ---@type table<string, Tasks.LinkPair>
  local pairs_by_key, order = {}, {}
  local kept = 0
  for _, e in ipairs(edges) do
    local a, b = e.from_area, e.to_area
    if b < a then
      a, b = b, a
    end
    local key = a .. "\0" .. b
    local pair = pairs_by_key[key]
    if not pair then
      pair = { a = a, b = b, count = 0, kinds = {}, edges = {} }
      pairs_by_key[key] = pair
      order[#order + 1] = pair
    end
    pair.count = pair.count + 1
    pair.kinds[e.kind] = (pair.kinds[e.kind] or 0) + 1
    if kept < M.MAX_EDGES then
      pair.edges[#pair.edges + 1] = e
      kept = kept + 1
    end
  end
  table.sort(order, function(x, y)
    if x.count ~= y.count then
      return x.count > y.count
    end
    if x.a ~= y.a then
      return x.a < y.a
    end
    return x.b < y.b
  end)

  local tasks = {}
  for _, t in ipairs(open) do
    local areas = {}
    for area in pairs(touched[t.id]) do
      areas[#areas + 1] = area
    end
    if #areas >= 2 then
      table.sort(areas)
      tasks[#tasks + 1] = { id = t.id, areas = areas }
    end
  end
  table.sort(tasks, function(x, y)
    return x.id < y.id
  end)

  return { edge_count = #edges, truncated = #edges > kept, pairs = order, tasks = tasks }
end

return M
