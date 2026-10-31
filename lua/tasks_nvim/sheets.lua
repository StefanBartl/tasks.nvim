---@module 'tasks_nvim.sheets'
---@brief The test-sheet state of a task: the block `testing sheets report --tasks` (testing.nvim) writes into its body.
---@description
--- testing.nvim writes the state of the test sheets that name a task as a generated block:
---
---   <!-- testing:sheets:begin -->
---   ## Test sheets
---   ... (text for people)
---   <!-- testing:sheets:states ui.option-float=inbox slots-bar=green -->
---   <!-- testing:sheets:end -->
---
--- Only the `states` line is read (the contract between the two plugins; the text above it may change its wording):
--- `<id>=<state>` per sheet, the state one of `STATES`. A block without that line (written by an older testing.nvim)
--- is `unknown`. An entry with a word that is not a state is left out. Markers count only on a line of their own and
--- outside a fenced code block, as testing.nvim writes them; a begin without its end is no block.
---
--- It is prose: a task without the block is complete and valid, and nothing here complains about its absence. Nothing
--- runs testing.nvim; the state is what the last report wrote.
---
--- Not its job: writing the block (testing.nvim), filtering by it (`model.filter`), showing it (`contract`, `ui`).

local M = {}

M.BEGIN = "<!-- testing:sheets:begin -->"
M.END = "<!-- testing:sheets:end -->"
M.STATES_PREFIX = "<!-- testing:sheets:states"

---The states, worst first: the state of a task is that of its worst sheet.
M.STATES = { "red", "stale", "never", "inbox", "manual", "green" }

local RANK = {}
for i, s in ipairs(M.STATES) do
  RANK[s] = i
end

---@param s string
---@return boolean
function M.is_state(s)
  return RANK[s] ~= nil
end

---@class Tasks.SheetState
---@field id string
---@field state string

---@class Tasks.SheetsSummary
---@field state string                  # The worst state of the sheets, or `unknown` for a block without a states line.
---@field total integer                 # Sheets in the states line.
---@field counts table<string, integer> # Sheets per state (every state of `STATES`, 0 when none).
---@field sheets Tasks.SheetState[]     # In the order of the line.

---The sheet state of a body, nil when it has no block.
---@param body string
---@return Tasks.SheetsSummary|nil
function M.parse(body)
  if type(body) ~= "string" or not body:find(M.BEGIN, 1, true) then
    return nil
  end
  local fence, inside, states_line = nil, false, nil
  local found = false
  for raw in (body .. "\n"):gmatch("(.-)\n") do
    local line = raw:gsub("\r$", "")
    local mark = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
    if fence then
      if
        mark
        and mark:sub(1, 1) == fence:sub(1, 1)
        and #mark >= #fence
        and line:match("^%s*[`~]+%s*$")
      then
        fence = nil
      end
    elseif mark then
      fence = mark
    elseif line == M.BEGIN then
      inside, states_line = true, nil
    elseif inside and line == M.END then
      found = true
      break
    elseif inside and line:sub(1, #M.STATES_PREFIX) == M.STATES_PREFIX then
      states_line = line
    end
  end
  if not found then
    return nil
  end
  local counts = {}
  for _, s in ipairs(M.STATES) do
    counts[s] = 0
  end
  local out = { state = "unknown", total = 0, counts = counts, sheets = {} }
  if not states_line then
    return out
  end
  local words = states_line:sub(#M.STATES_PREFIX + 1):gsub("%-%->%s*$", "")
  local worst
  for id, state in words:gmatch("([%w_.%-]+)=(%a+)") do
    if RANK[state] then
      out.sheets[#out.sheets + 1] = { id = id, state = state }
      counts[state] = counts[state] + 1
      if not worst or RANK[state] < RANK[worst] then
        worst = state
      end
    end
  end
  out.total = #out.sheets
  out.state = worst or "unknown"
  return out
end

---One line for people: `inbox (3 sheets: 1 inbox, 2 green)`.
---@param s Tasks.SheetsSummary
---@return string
function M.describe(s)
  if s.total == 0 then
    return "unknown (the block has no states line: run `testing sheets report --tasks` again)"
  end
  local parts = {}
  for _, st in ipairs(M.STATES) do
    if s.counts[st] > 0 then
      parts[#parts + 1] = ("%d %s"):format(s.counts[st], st)
    end
  end
  return ("%s (%d sheet%s: %s)"):format(
    s.state,
    s.total,
    s.total == 1 and "" or "s",
    table.concat(parts, ", ")
  )
end

return M
