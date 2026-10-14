---@module 'tasks_nvim.match'
---@brief Resolve a part of a task name to task ids (the engine side of `:Tasks open <part>`).

local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.Match
---@field id string
---@field title? string  # only for open tasks: a finished task is matched by its slug, its file is not read
---@field done boolean
---@field rank integer  # 1 the slug, 2 starts with it, 3 contains it, 4 the title contains it

---Closest first: rank, then open before finished, then by id.
---@param a Tasks.Match
---@param b Tasks.Match
---@return boolean
local function before(a, b)
  if a.rank ~= b.rank then
    return a.rank < b.rank
  end
  if a.done ~= b.done then
    return not a.done
  end
  return a.id < b.id
end

---The area named by the part of `query` before a `/`, spelled as the vault spells it (any case), else nil.
---@param query string
---@param names string[]
---@return string|nil area
---@return string text  # what is left to look for
local function split_area(query, names)
  local head, tail = query:match("^([^/]*)/(.*)$")
  if head then
    -- the exact spelling first: on a disk that tells `Foo` from `foo` both can be areas
    for _, name in ipairs(names) do
      if name == head then
        return name, tail
      end
    end
    for _, name in ipairs(names) do
      if vim.fn.tolower(name) == vim.fn.tolower(head) then
        return name, tail
      end
    end
  end
  return nil, query
end

---@param slug string
---@param title string|nil
---@param text string  # lower case
---@return integer|nil rank
local function rank_of(slug, title, text)
  local low = slug:lower()
  if low == text then
    return 1
  elseif low:sub(1, #text) == text then
    return 2
  elseif low:find(text, 1, true) then
    return 3
  elseif title and vim.fn.tolower(title):find(text, 1, true) then
    return 4
  end
  return nil
end

---The tasks (open ones and finished ones) a part of a name points at, closest first. `area/part` looks in one
---area only; plain text matches the slug (equal, then start, then anywhere), then the title of an open task;
---case does not matter. A text that matches nothing returns `{}` and, as a second value, the slugs that share
---its first three letters (for "did you mean").
---@param query string
---@param opts? Tasks.ScanOpts
---@return Tasks.Match[] matches
---@return string[] near
function M.match(query, opts)
  opts = opts or {}
  local root = vault.root()
  if type(query) ~= "string" or vim.trim(query) == "" or not root then
    return {}, {}
  end
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    names[#names + 1] = a.name
  end
  local area, text = split_area(vim.trim(query), names)
  -- `area/` alone leaves no text: every task of the area
  -- vim.fn.tolower folds more than ASCII ("Über" -> "über"); a slug is ASCII, a title is not
  text = vim.fn.tolower(text)

  local seen, all = {}, {}
  local function add(id, title, done, rank)
    if rank and not seen[id] then
      seen[id] = true
      all[#all + 1] = { id = id, title = title, done = done, rank = rank }
    end
  end
  local candidates = {}
  local open = scan.open_tasks({ root = opts.root, area = area }) or {}
  for _, t in ipairs(open) do
    local slug = t.id:match("/(.+)$") or t.id
    candidates[#candidates + 1] = { slug = slug, id = t.id, title = t.title, done = false }
  end
  for _, name in ipairs(area and { area } or names) do
    local ok, slugs = pcall(scan.backlog_slugs, name, { root = opts.root })
    for slug in pairs(ok and slugs or {}) do
      if vault.valid_slug(slug) then
        candidates[#candidates + 1] = { slug = slug, id = name .. "/" .. slug, done = true }
      end
    end
  end
  for _, c in ipairs(candidates) do
    -- an open task shadows a finished one of the same id (`add` keeps the first)
    add(c.id, c.title, c.done, text == "" and 2 or rank_of(c.slug, c.title, text))
  end
  table.sort(all, before)
  if #all > 0 or #text < 3 then
    return all, {}
  end

  local near, head = {}, text:sub(1, 3)
  for _, c in ipairs(candidates) do
    if c.slug:lower():find(head, 1, true) then
      near[#near + 1] = c.id
    end
  end
  table.sort(near)
  return {}, vim.list_slice(near, 1, 3)
end

---The one task a part of a name means: the only match, or the only one whose slug is exactly the text.
---@param matches Tasks.Match[]
---@return Tasks.Match|nil
function M.unique(matches)
  if #matches == 1 then
    return matches[1]
  end
  local exact
  for _, m in ipairs(matches) do
    if m.rank == 1 then
      if exact then
        return nil
      end
      exact = m
    end
  end
  return exact
end

return M
