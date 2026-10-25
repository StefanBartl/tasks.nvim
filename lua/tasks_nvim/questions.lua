---@module 'tasks_nvim.questions'
---@brief The optional `## Offene Fragen` / `## Open questions` section of a task: questions with checkbox options, one of them recommended.
---@description
--- A task that waits for a decision may carry a section with its questions, so that a front end can offer the options
--- and write the answer:
---
---   ## Offene Fragen
---
---   ### Which format? [q1]
---   Optional text under the question.
---   - [ ] Section in the body (empfohlen)
---   - [ ] List in the frontmatter
---
--- A question is a `### ` heading that ends in a key `[qN]`; its options are the checkbox lines below it, up to the next
--- question. The option that ends in `(empfohlen)` / `(recommended)` is the recommendation (the marker is not part of
--- the option's text). A question is answered when exactly one option is ticked. The key is the engine's: a question
--- written without one gets the next free number the first time an answer is written (`answer`).
---
--- It is prose: a task without the section is complete and valid, and nothing here complains about its absence. Pure
--- text in, text out; every other byte (line endings, indentation, the rest of the file) stays as it was.
---
--- Not its job: finding the file (`scan`), writing it (`mutate.edit_text`), the wording of the answer (the person's).

local fsio = require("tasks_nvim.fsio")

local M = {}

---@param line string
---@return string
local function bare_of(line)
  return (line:gsub("\r$", ""))
end

---@class Tasks.QuestionOption
---@field n integer          # 1-based position among the options of the question.
---@field text string        # The option as written, without the checkbox and without the marker of the recommendation.
---@field chosen boolean
---@field recommended boolean
---@field line integer       # 1-based line of the whole text.

---@class Tasks.Question
---@field n integer          # 1-based position among the questions of the section.
---@field key string|nil     # `q1`; nil for a question that was written without one.
---@field title string
---@field text string        # The lines between the heading and the first option, trimmed.
---@field options Tasks.QuestionOption[]
---@field answered boolean   # Exactly one option is ticked.
---@field line integer       # 1-based line of the heading.

---@class Tasks.QuestionsSummary
---@field items Tasks.Question[]
---@field total integer
---@field open integer       # Questions that are not answered.
---@field problems string[]  # What is wrong with the section (two ticked options, a key twice ...), for `check`.

---The words that mark the recommendation (in parentheses at the end of an option, compared case-insensitively).
local RECOMMENDED = { "empfohlen", "recommended" }

---@param text string
---@return string stripped
---@return boolean recommended
local function split_recommended(text)
  -- `text` is trimmed (see `checkbox`). The marker is compared at the end by length: a pattern with a leading `%s*`
  -- would go quadratic on a line that holds a long run of blanks (SEC-32).
  local lower = text:lower()
  for _, word in ipairs(RECOMMENDED) do
    local marker = "(" .. word .. ")"
    if #lower >= #marker and lower:sub(-#marker) == marker then
      return fsio.trim(text:sub(1, #text - #marker)), true
    end
  end
  return text, false
end

---@param bare string  A line without its trailing CR.
---@return string|nil mark
---@return string text
local function checkbox(bare)
  local mark, rest = bare:match("^%s*[-*]%s+%[([ xX])%](.*)$")
  return mark, fsio.trim(rest or "")
end

---The question heading: the text, and its key when it ends in `[qN]`.
---@param bare string
---@return string|nil title
---@return string|nil key
local function heading(bare)
  -- Linear: a lazy `(.-)%s*$` backtracks over a long run of blanks (SEC-32), so the line is cut and trimmed instead.
  local raw = bare:match("^###%s+(.*)$")
  local rest = raw and fsio.trim(raw) or ""
  if rest == "" then
    return nil, nil
  end
  local at, _, key = rest:find("%[(q%d+)%]$")
  if at then
    return fsio.trim(rest:sub(1, at - 1)), key
  end
  return rest, nil
end

---The lines of the section: from the line after the heading to the line before the next `## ` heading (a fenced code
---block is skipped, a `## ` inside it is not a heading).
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
      elseif bare:match("^##%s+Offene Fragen%s*$") or bare:match("^##%s+Open questions%s*$") then
        first = i + 1
      end
    end
  end
  if first then
    return first, #lines
  end
  return nil, nil
end

---@param lines string[]
---@param first integer
---@param last integer
---@return Tasks.Question[]
local function read(lines, first, last)
  ---@type Tasks.Question[]
  local items = {}
  ---@type Tasks.Question|nil
  local current
  local prose = {}
  local fenced = false
  local function close_prose()
    if current then
      current.text = fsio.trim(table.concat(prose, "\n"))
    end
    prose = {}
  end
  for i = first, last do
    local bare = bare_of(lines[i] or "")
    if bare:match("^```") or bare:match("^~~~") then
      fenced = not fenced
      if current and #current.options == 0 then
        prose[#prose + 1] = bare
      end
    elseif not fenced then
      local title, key = heading(bare)
      if title then
        close_prose()
        current = {
          n = #items + 1,
          key = key,
          title = title,
          text = "",
          options = {},
          answered = false,
          line = i,
        }
        items[#items + 1] = current
      elseif current then
        local mark, text = checkbox(bare)
        if mark then
          local stripped, recommended = split_recommended(text)
          current.options[#current.options + 1] = {
            n = #current.options + 1,
            text = stripped,
            chosen = mark ~= " ",
            recommended = recommended,
            line = i,
          }
        elseif #current.options == 0 then
          prose[#prose + 1] = bare
        end
      end
    elseif current and #current.options == 0 then
      prose[#prose + 1] = bare
    end
  end
  close_prose()
  for _, q in ipairs(items) do
    local chosen = 0
    for _, o in ipairs(q.options) do
      if o.chosen then
        chosen = chosen + 1
      end
    end
    q.answered = chosen == 1
  end
  return items
end

---What is wrong with the questions: said once each, for `check`.
---@param items Tasks.Question[]
---@return string[]
local function problems_of(items)
  local out = {}
  local seen = {}
  for _, q in ipairs(items) do
    local name = q.key or ("#" .. q.n)
    if q.key then
      if seen[q.key] then
        out[#out + 1] = ("question key [%s] is used twice"):format(q.key)
      end
      seen[q.key] = true
    end
    local chosen, recommended = 0, 0
    for _, o in ipairs(q.options) do
      chosen = chosen + (o.chosen and 1 or 0)
      recommended = recommended + (o.recommended and 1 or 0)
    end
    if #q.options == 0 then
      out[#out + 1] = ("question %s has no options (checkbox lines)"):format(name)
    end
    if chosen > 1 then
      out[#out + 1] = ("question %s has %d ticked options, an answer is one"):format(name, chosen)
    end
    if recommended > 1 then
      out[#out + 1] = ("question %s recommends %d options, at most one"):format(name, recommended)
    end
  end
  return out
end

---Read the section. `nil` when the text has no such section or the section holds no question.
---@param text string
---@return Tasks.QuestionsSummary|nil
function M.parse(text)
  if not (text:find("## Offene Fragen", 1, true) or text:find("## Open questions", 1, true)) then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  local first, last = section(lines)
  if not first then
    return nil
  end
  local items = read(lines, first, last or first)
  if #items == 0 then
    return nil
  end
  local open = 0
  for _, q in ipairs(items) do
    if not q.answered then
      open = open + 1
    end
  end
  return { items = items, total = #items, open = open, problems = problems_of(items) }
end

---The next free key: one more than the highest `qN` in the section.
---@param items Tasks.Question[]
---@return string
local function next_key(items)
  local top = 0
  for _, q in ipairs(items) do
    local n = q.key and tonumber(q.key:match("^q(%d+)$")) or nil
    if n and n > top then
      top = n
    end
  end
  return "q" .. (top + 1)
end

---Find the question a caller names: a key (`q2`) or a 1-based position.
---@param summary Tasks.QuestionsSummary
---@param ref string|integer
---@return Tasks.Question|nil
local function find(summary, ref)
  if type(ref) == "number" then
    return summary.items[ref]
  end
  for _, q in ipairs(summary.items) do
    if q.key == ref then
      return q
    end
  end
  local n = tostring(ref):match("^#(%d+)$")
  return n and summary.items[tonumber(n)] or nil
end

---Answer one question: tick the option `option` (1-based) and untick the others; `option` 0 takes the answer back
---(every option open). The question that is in the wanted state already is no change (`new_text` is `text`). A
---question without a key gets one (the next free number) when the text changes.
---@param text string
---@param question string|integer  # A key (`q2`), `#2` or the position.
---@param option integer
---@return string|nil new_text
---@return { key: string, was: integer }|nil info  # `was`: the option that was ticked before (0 for none).
---@return string|nil err
function M.answer(text, question, option)
  local summary = M.parse(text)
  if not summary then
    return nil,
      nil,
      "the task has no questions (no `## Offene Fragen` section with `###` questions)"
  end
  local q = find(summary, question)
  if not q then
    return nil,
      nil,
      ("the task has %d questions, there is no question %s"):format(
        summary.total,
        tostring(question)
      )
  end
  if type(option) ~= "number" or option % 1 ~= 0 or option < 0 or option > #q.options then
    return nil,
      nil,
      ("question %s has %d options, there is no option %s"):format(
        q.key or ("#" .. q.n),
        #q.options,
        tostring(option)
      )
  end
  local was = 0
  local ticked = 0
  for _, o in ipairs(q.options) do
    if o.chosen then
      ticked = ticked + 1
      was = o.n
    end
  end
  if ticked > 1 then
    return nil,
      nil,
      ("question %s has more than one ticked option: fix the file first"):format(
        q.key or ("#" .. q.n)
      )
  end
  local key = q.key
  local needs_key = key == nil
  if was == option and not needs_key then
    return text, { key = key or "", was = was }, nil
  end
  if needs_key then
    key = next_key(summary.items)
  end
  local lines = vim.split(text, "\n", { plain = true })
  for _, o in ipairs(q.options) do
    local line = lines[o.line]
    if o.n == option then
      lines[o.line] = line:gsub("%[ %]", "[x]", 1)
    elseif o.chosen then
      lines[o.line] = line:gsub("%[[xX]%]", "[ ]", 1)
    end
  end
  if needs_key then
    local head = lines[q.line]
    local cr = head:match("\r$") or ""
    lines[q.line] = fsio.trim(bare_of(head)) .. " [" .. key .. "]" .. cr
  end
  local new_text = table.concat(lines, "\n")
  if new_text == text then
    return text, { key = key or "", was = was }, nil
  end
  return new_text, { key = key or "", was = was }, nil
end

return M
