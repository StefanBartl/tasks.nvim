---@module 'tasks_nvim.steps'
---@brief The optional `## Plan` section of a task: numbered checkbox steps, read for their progress and ticked off.
---@description
--- A task may carry a section `## Plan` with checkbox steps (`- [ ] 1. Config table ... -- Acceptance 1`). It is
--- prose, not frontmatter: the engine reads only HOW MANY steps there are and how many are ticked ("2/4") and, for
--- `plan --with-steps`, their text. A task without the section is complete and valid; nothing here ever complains
--- about its absence.
---
--- A step that says `(dropped)` or `(entfaellt)` is struck from the count and is never ticked by `tick_all`: it was
--- decided not to do it, finishing the task does not make it done. A step is not a task (one task = one result);
--- a step that needs its own acceptance test or its own blocker should become a task.
---
--- Pure text in, text out. `tick_all` keeps every other byte (line endings, indentation, the rest of the file).
---
--- Not its job: finding the file (`scan`), writing it (`mutate.done` writes the ticked text with the finish).

local M = {}

---@param line string
---@return string
local function bare_of(line)
  return (line:gsub("\r$", ""))
end

---@class Tasks.Step
---@field n integer         # 1-based position among the steps of the section.
---@field text string       # The step as written, without the checkbox.
---@field done boolean
---@field dropped boolean   # Struck from the count: `(dropped)` / `(entfaellt)`.
---@field line integer      # 1-based line of the whole text.

---@class Tasks.StepsSummary
---@field total integer     # Steps that count (dropped ones excluded).
---@field ticked integer
---@field dropped integer
---@field items Tasks.Step[]

---Words that strike a step from the count (compared case-insensitively, in parentheses).
local DROPPED = { "dropped", "entfaellt", "entfällt", "n/a" }

---@param text string
---@return boolean
local function is_dropped(text)
  local lower = text:lower()
  for _, word in ipairs(DROPPED) do
    if lower:find("(" .. word .. ")", 1, true) then
      return true
    end
  end
  return false
end

---The lines of the `## Plan` section: from the line after the heading to the line before the next `## ` heading
---(a fenced code block is skipped, a `## ` inside it is not a heading).
---@param lines string[]
---@return integer|nil first
---@return integer|nil last
local function section(lines)
  local first
  local fenced = false
  for i, line in ipairs(lines) do
    local bare = bare_of(line)
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced then
      if first then
        if bare:match("^##%s") or bare:match("^#%s") then
          return first, i - 1
        end
      elseif bare:match("^##%s+Plan%s*$") then
        first = i + 1
      end
    end
  end
  if first then
    return first, #lines
  end
  return nil, nil
end

---@param bare string  A line without its trailing CR.
---@return string|nil mark   # " ", "x" or "X"
---@return string text         # "" when there is no checkbox
local function checkbox(bare)
  local mark, text = bare:match("^%s*[-*]%s+%[([ xX])%]%s*(.-)%s*$")
  return mark, text or ""
end

---Read the section. `nil` when the text has no `## Plan` section or the section holds no checkbox.
---@param text string
---@return Tasks.StepsSummary|nil
function M.parse(text)
  if not text:find("## Plan", 1, true) then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  local first, last = section(lines)
  if not first then
    return nil
  end
  ---@type Tasks.StepsSummary
  local out = { total = 0, ticked = 0, dropped = 0, items = {} }
  local fenced = false
  for i = first, last or first do
    local bare = bare_of(lines[i] or "")
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced then
      local mark, step = checkbox(bare)
      if mark then
        local dropped = is_dropped(step)
        local done = mark ~= " "
        out.items[#out.items + 1] =
          { n = #out.items + 1, text = step, done = done, dropped = dropped, line = i }
        if dropped then
          out.dropped = out.dropped + 1
        else
          out.total = out.total + 1
          if done then
            out.ticked = out.ticked + 1
          end
        end
      end
    end
  end
  if #out.items == 0 then
    return nil
  end
  return out
end

---Tick every open step of the section except the dropped ones.
---@param text string
---@return string new_text   # Identical to `text` when there is nothing to tick.
---@return integer ticked    # How many steps were ticked.
function M.tick_all(text)
  if not text:find("## Plan", 1, true) then
    return text, 0
  end
  local lines = vim.split(text, "\n", { plain = true })
  local first, last = section(lines)
  if not first then
    return text, 0
  end
  local ticked = 0
  local fenced = false
  for i = first, last or first do
    local line = lines[i] or ""
    local bare = bare_of(line)
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced then
      local mark, step = checkbox(bare)
      if mark == " " and not is_dropped(step) then
        lines[i] = line:gsub("%[ %]", "[x]", 1)
        ticked = ticked + 1
      end
    end
  end
  if ticked == 0 then
    return text, 0
  end
  return table.concat(lines, "\n"), ticked
end

---The checklist items of the acceptance section (`## Akzeptanz` / `## Acceptance`), in order.
---@param lines string[]
---@return integer count
local function acceptance_count(lines)
  local inside, count, fenced = false, 0, false
  for _, line in ipairs(lines) do
    local bare = bare_of(line)
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced then
      if bare:match("^##%s+Akzeptanz%s*$") or bare:match("^##%s+Acceptance%s*$") then
        inside = true
      elseif bare:match("^##?%s") then
        inside = false
      elseif inside and checkbox(bare) then
        count = count + 1
      end
    end
  end
  return count
end

---Acceptance points that no step refers to (`-- Akzeptanz 2, 3` / `-- Acceptance 2`): a hint, not a rule. Only
---meaningful for a task that has steps; without steps (or without an acceptance list) there is nothing to say.
---@param text string
---@return integer[] uncovered
function M.uncovered_acceptance(text)
  local summary = M.parse(text)
  if not summary then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  local count = acceptance_count(lines)
  if count == 0 then
    return {}
  end
  local covered = {}
  for _, item in ipairs(summary.items) do
    -- "Akzeptanz 2, 3", "Akzeptanz 2 und 3", "Acceptance 1 + 2": the words and / und read as a comma
    local phrase = (item.text:gsub("%f[%a]und%f[%A]", ","):gsub("%f[%a]and%f[%A]", ","))
    for _, word in ipairs({ "[Aa]kzeptanz", "[Aa]cceptance" }) do
      for list in phrase:gmatch(word .. "%s+(%d[%d,%s+]*)") do
        for n in list:gmatch("%d+") do
          covered[tonumber(n)] = true
        end
      end
    end
  end
  local out = {}
  for n = 1, count do
    if not covered[n] then
      out[#out + 1] = n
    end
  end
  return out
end

---The section as text for the template.
---@return string
function M.template_section()
  return table.concat({
    "## Plan",
    "",
    "- [ ] 1. first step -- Acceptance 1",
    "- [ ] 2. second step",
    "",
  }, "\n")
end

return M
