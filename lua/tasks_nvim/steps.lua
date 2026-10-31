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

local fsio = require("tasks_nvim.fsio")

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
  -- `(.*)$` and a linear trim: a lazy `(.-)%s*$` backtracks over a long whitespace run (SEC-32).
  local mark, rest = bare:match("^%s*[-*]%s+%[([ xX])%](.*)$")
  return mark, fsio.trim(rest or "")
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

---Tick or untick ONE step of the section. A step that is already in the wanted state is no change (`new_text` is
---`text`); a dropped step is refused (it is struck from the count: nobody ticks it, finishing does not either).
---@param text string
---@param n integer
---@param done boolean
---@return string|nil new_text
---@return Tasks.Step|nil step   # The step as it was.
---@return string|nil err
function M.set_step(text, n, done)
  local summary = M.parse(text)
  if not summary then
    return nil, nil, "the task has no steps (no `## Plan` section with checkboxes)"
  end
  local step = summary.items[n]
  if not step then
    return nil,
      nil,
      ("the task has %d steps, there is no step %s"):format(#summary.items, tostring(n))
  end
  if step.dropped then
    return nil, step, ("step %d is dropped: it does not count and is not ticked"):format(n)
  end
  if step.done == done then
    return text, step, nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  local line = lines[step.line]
  -- the first box of the line is the checkbox (a step starts with `- [ ]`)
  lines[step.line] = done and line:gsub("%[ %]", "[x]", 1) or line:gsub("%[[xX]%]", "[ ]", 1)
  return table.concat(lines, "\n"), step, nil
end

---Longest note `add_note` takes.
M.MAX_NOTE = 1000

---Append a dated line to the notes of the task (`## Notizen`, or `## Notes` in a task written in English): below the
---last line of the section, so the notes stay in the order they were written. A task without the section gets one at
---the end. Everything else of the text stays as it was (line endings included).
---@param text string
---@param note string   # One line of text.
---@param today string  # `YYYY-MM-DD`.
---@return string|nil new_text
---@return string|nil err
function M.add_note(text, note, today)
  local trimmed = fsio.trim(note)
  if trimmed == "" then
    return nil, "the note is empty"
  end
  if trimmed:find("[%c\127]") then
    return nil, "the note must be one line without control characters"
  end
  if vim.fn.strchars(trimmed) > M.MAX_NOTE then
    return nil, ("the note is longer than %d characters"):format(M.MAX_NOTE)
  end
  local cr = text:find("\r\n", 1, true) and "\r" or ""
  local entry = "- " .. today .. ": " .. trimmed .. cr
  local lines = vim.split(text, "\n", { plain = true })
  local heading
  local fenced = false
  for i, line in ipairs(lines) do
    local bare = bare_of(line)
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced then
      if heading then
        if bare:match("^##?%s") then
          -- the section ends before this heading; the entry goes below its last line of text
          local at = i - 1
          while at > heading and bare_of(lines[at]) == "" do
            at = at - 1
          end
          if at == heading then
            table.insert(lines, at + 1, cr)
            at = at + 1
          end
          table.insert(lines, at + 1, entry)
          return table.concat(lines, "\n"), nil
        end
      elseif bare:match("^##%s+Notizen%s*$") or bare:match("^##%s+Notes%s*$") then
        heading = i
      end
    end
  end
  if heading then
    -- the section runs to the end of the text
    local at = #lines
    while at > heading and bare_of(lines[at]) == "" do
      at = at - 1
    end
    if at == heading then
      table.insert(lines, at + 1, cr)
      at = at + 1
    end
    table.insert(lines, at + 1, entry)
    return table.concat(lines, "\n"), nil
  end
  local english = text:find("\n## Context", 1, true) or text:find("\n## Acceptance", 1, true)
  local eol = cr == "\r" and "\r\n" or "\n"
  local body = text:gsub("[\r\n]+$", "")
  return body .. eol .. eol .. (english and "## Notes" or "## Notizen") .. eol .. eol .. fsio.trim(
    entry
  ) .. eol,
    nil
end

---Longest step `add_steps` takes, in characters.
M.MAX_STEP = 1000

---Append open steps to the `## Plan` section: below its last step, numbered on from it when the plan numbers its steps
---(`- [ ] 3. ...`) or has none yet, with the bullet and indentation of the last step. A task without the section gets
---one before its notes (`## Notizen` / `## Notes`), or at the end. Existing steps and every other byte stay as they
---were (line endings included). A step is the text of one line: no checkbox, no list marker, and no number of its own
---when the engine numbers it.
---@param text string
---@param items string[]
---@return string|nil new_text
---@return string|nil err
function M.add_steps(text, items)
  if #items == 0 then
    return nil, "there are no steps to add"
  end
  local summary = M.parse(text)
  local last_item = summary and summary.items[#summary.items]
  -- the plan is numbered when it has no step yet or its last step carries a number
  local last_number = last_item and tonumber(last_item.text:match("^(%d+)%.%s"))
  local numbered = last_item == nil or last_number ~= nil
  local next_number = last_number or 0
  local cr = text:find("\r\n", 1, true) and "\r" or ""
  local lines = vim.split(text, "\n", { plain = true })
  local prefix = "- "
  if last_item then
    prefix = bare_of(lines[last_item.line]):match("^(%s*[-*]%s+)") or prefix
  end
  local new_lines = {}
  for i, item in ipairs(items) do
    local step = fsio.trim(item)
    if step == "" then
      return nil, ("step %d is empty"):format(i)
    end
    if step:find("[%c\127]") then
      return nil, ("step %d must be one line without control characters"):format(i)
    end
    if vim.fn.strchars(step) > M.MAX_STEP then
      return nil, ("step %d is longer than %d characters"):format(i, M.MAX_STEP)
    end
    if step:match("^[-*+]%s") or step:match("^%[[ xX]%]") then
      return nil,
        ("step %d is a list line: give the text of the step, the checkbox is written here"):format(
          i
        )
    end
    if numbered and step:match("^%d+[.)]%s") then
      return nil, ("step %d carries a number: the steps are numbered here"):format(i)
    end
    if numbered then
      next_number = next_number + 1
      step = next_number .. ". " .. step
    end
    new_lines[#new_lines + 1] = prefix .. "[ ] " .. step .. cr
  end

  ---Put `block` below line `at` (0: at the top). Below the last line of a text without a final line break, that line
  ---gets the break and the block's last line goes without one.
  ---@param at integer
  ---@param block string[]
  local function insert(at, block)
    if at == #lines and lines[at] ~= "" then
      lines[at] = lines[at] .. cr
      block[#block] = (block[#block]:gsub("\r$", ""))
    end
    for k, line in ipairs(block) do
      table.insert(lines, at + k, line)
    end
  end

  if last_item then
    insert(last_item.line, new_lines)
    return table.concat(lines, "\n"), nil
  end

  local first, last = section(lines)
  if first then
    -- a section without steps: below its last line of text, a blank line between that text and the list
    local at = last or first
    while at >= first and bare_of(lines[at]) == "" do
      at = at - 1
    end
    local block = { cr }
    vim.list_extend(block, new_lines)
    if at < #lines and bare_of(lines[at + 1]) == "" then
      -- the blank line that followed the text now follows the list
      insert(at, block)
    else
      block[#block + 1] = cr
      insert(at, block)
    end
    return table.concat(lines, "\n"), nil
  end

  -- no section: a new one before the notes, or at the end
  local fenced = false
  for i, line in ipairs(lines) do
    local bare = bare_of(line)
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
    elseif not fenced and (bare:match("^##%s+Notizen%s*$") or bare:match("^##%s+Notes%s*$")) then
      local block = {}
      if i > 1 and bare_of(lines[i - 1]) ~= "" then
        block[#block + 1] = cr
      end
      block[#block + 1] = "## Plan" .. cr
      block[#block + 1] = cr
      vim.list_extend(block, new_lines)
      block[#block + 1] = cr
      insert(i - 1, block)
      return table.concat(lines, "\n"), nil
    end
  end
  local eol = cr .. "\n"
  local body = text:gsub("[\r\n]+$", "")
  local list = {}
  for _, line in ipairs(new_lines) do
    list[#list + 1] = (line:gsub("\r$", ""))
  end
  local head = body == "" and "" or (body .. eol .. eol)
  return head .. "## Plan" .. eol .. eol .. table.concat(list, eol) .. eol, nil
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
---meaningful for a task that has steps, and only for a plan that uses the reference convention at all (one step with a
---reference): without steps, without an acceptance list or without any reference there is nothing to say.
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
  local uses_references = false
  for _, item in ipairs(summary.items) do
    -- "Akzeptanz 2, 3", "Akzeptanz 2 und 3", "Acceptance 1 + 2": the words and / und read as a comma
    local phrase = (item.text:gsub("%f[%a]und%f[%A]", ","):gsub("%f[%a]and%f[%A]", ","))
    for _, word in ipairs({ "[Aa]kzeptanz", "[Aa]cceptance" }) do
      for list in phrase:gmatch(word .. "%s+(%d[%d,%s+]*)") do
        for n in list:gmatch("%d+") do
          covered[tonumber(n)] = true
          uses_references = true
        end
      end
    end
  end
  -- The `-- Acceptance n` reference is a convention: a plan that does not use it at all is not asked to.
  if not uses_references then
    return {}
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
