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
--- is `unknown`. An entry with a word that is not a state is left out. Markers and fences are found as testing.nvim
--- finds them (`parse`), so both sides agree on where the block is.
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
---@field state string                  # The worst state of the sheets, or `unknown` (see `reason`).
---@field total integer                 # Sheets with a known state in the states line.
---@field counts table<string, integer> # Sheets per state (every state of `STATES`, 0 when none).
---@field sheets Tasks.SheetState[]     # In the order of the line.
---@field reason? "no-states-line"|"no-known-state"|"broken-markers"  # Why the state is `unknown`.

---The lines of a body and, per line, whether it is inside (or opens/closes) a fenced code block. Fences as
---CommonMark reads them, the same rule testing.nvim's `testing.sheet.tasks` applies: up to 3 spaces, 3+ backticks
---(no backtick in the info string) or 3+ tildes; closed by the same character, at least as long, nothing after it.
---@param body string
---@return string[] lines, boolean[] fenced
local function lines_of(body)
  local lines, fenced, fence = {}, {}, nil
  for raw in (body .. "\n"):gmatch("(.-)\n") do
    local line = raw:gsub("\r$", "")
    lines[#lines + 1] = line
    if fence then
      fenced[#lines] = true
      local close = line:match("^ ? ? ?(" .. fence:sub(1, 1):rep(3) .. "+)%s*$")
      if close and #close >= #fence then
        fence = nil
      end
    else
      local ticks, info = line:match("^ ? ? ?(```+)(.*)$")
      fence = (ticks and not info:find("`", 1, true)) and ticks or line:match("^ ? ? ?(~~~+)")
      fenced[#lines] = fence ~= nil
    end
  end
  return lines, fenced
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---The sheet state of a body, nil when it has no block. Markers are found as testing.nvim finds them (trimmed, on a
---line of their own, outside a fence): one begin and one end after it is the block; any other mix (two blocks, an
---end in front of the begin, a begin without its end) is `unknown` with `reason = "broken-markers"`, the body
---testing.nvim refuses to write.
---@param body string
---@return Tasks.SheetsSummary|nil
function M.parse(body)
  if type(body) ~= "string" or not body:find("<!-- testing:sheets:", 1, true) then
    return nil
  end
  local lines, fenced = lines_of(body)
  local begins, ends = {}, {}
  for i, line in ipairs(lines) do
    if not fenced[i] then
      local t = trim(line)
      if t == M.BEGIN then
        begins[#begins + 1] = i
      elseif t == M.END then
        ends[#ends + 1] = i
      end
    end
  end
  if #begins == 0 and #ends == 0 then
    return nil
  end
  local counts = {}
  for _, s in ipairs(M.STATES) do
    counts[s] = 0
  end
  local out = { state = "unknown", total = 0, counts = counts, sheets = {} }
  if not (#begins == 1 and #ends == 1 and ends[1] > begins[1]) then
    out.reason = "broken-markers"
    return out
  end
  local states_line
  for i = begins[1] + 1, ends[1] - 1 do
    local t = trim(lines[i])
    if t:sub(1, #M.STATES_PREFIX) == M.STATES_PREFIX then
      states_line = t
    end
  end
  if not states_line then
    out.reason = "no-states-line"
    return out
  end
  local words = states_line:sub(#M.STATES_PREFIX + 1):gsub("%-%->$", "")
  local worst
  -- one blank-separated word at a time, each matched anchored: linear in the length of the line
  for word in words:gmatch("%S+") do
    local id, state = word:match("^([%w_.%-]+)=(%a+)$")
    if id and RANK[state] then
      out.sheets[#out.sheets + 1] = { id = id, state = state }
      counts[state] = counts[state] + 1
      if not worst or RANK[state] < RANK[worst] then
        worst = state
      end
    end
  end
  out.total = #out.sheets
  out.state = worst or "unknown"
  out.reason = not worst and "no-known-state" or nil
  return out
end

local REASONS = {
  ["no-states-line"] = "the block has no states line: run `testing sheets report --tasks` again",
  ["no-known-state"] = "no state this tasks.nvim knows in the states line: a newer testing.nvim?",
  ["broken-markers"] = "the block markers are broken (two blocks, or a begin without its end): fix them by hand",
}

---One line for people: `inbox (3 sheets: 1 inbox, 2 green)`.
---@param s Tasks.SheetsSummary
---@return string
function M.describe(s)
  if s.state == "unknown" then
    return "unknown (" .. (REASONS[s.reason] or "?") .. ")"
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
