---@module 'tasks_nvim.form'
---@brief The Markdown form behind `:Tasks new` -- text in, validated values out; no UI.
---@description
--- The form is a Markdown buffer: text lines for the free fields and a
--- `- [ ]` / `- [x]` bullet list per choice field. This module builds the
--- template, parses what the user left in the buffer, checks it, and flips one
--- bullet while keeping a single-choice list at one tick. It touches no buffer,
--- window or file, so `TESTS/tasks/tasks_form_spec.lua` drives it with plain
--- strings; `bindings.usrcmds.plugin_repos.tasks_form` is the thin UI on top.
---
--- Layout (the value sets come from `tasks.model`, nothing is repeated here):
---
---     # New task
---     Area: my-area
---     Title: Fix the thing
---
---     ## kind (one)
---     - [ ] feature
---     - [x] task
---     ...
---     ## category (several)
---     ...
---     Tags: ui, perf
---     Refs: lua/foo.lua
---
--- Lines starting with `!` (error report of an earlier submit) and `<!--`
--- (hints) are ignored when parsing.
---
--- Key responsibilities:
---  - `FIELDS`: the choice fields, in form order, with their value sets
---  - `template`, `parse`, `validate`, `toggle`, `error_lines`
---
--- Not its job: windows and keymaps (the UI module), creating the task
--- (`tasks.mutate.new`, which re-checks every value).

local model = require("tasks_nvim.model")

local M = {}

---@class Tasks.FormField
---@field name string        # Heading word and `Tasks.NewOpts` key.
---@field multi boolean      # Several ticks allowed.
---@field values string[]    # Choices, in display order.
---@field default? string    # Ticked in a fresh form.

---@param list any[]
---@return string[]
local function strings(list)
  local out = {}
  for i, v in ipairs(list) do
    out[i] = tostring(v)
  end
  return out
end

---The choice fields in form order. Built on first use so the model's lists are
---read, not copied at load time.
---@return Tasks.FormField[]
function M.fields()
  return {
    { name = "kind", multi = false, values = strings(model.KINDS), default = "task" },
    { name = "prio", multi = false, values = strings(model.PRIOS) },
    { name = "effort", multi = false, values = strings(model.EFFORTS) },
    { name = "value", multi = false, values = strings(model.VALUES) },
    { name = "actor", multi = false, values = strings(model.ACTORS) },
    { name = "category", multi = true, values = strings(model.CATEGORIES) },
    { name = "severity", multi = false, values = strings(model.SEVERITIES) },
    { name = "status", multi = false, values = strings(model.OPEN_STATUSES), default = "open" },
  }
end

---@param name string
---@return Tasks.FormField|nil
local function field_by_name(name)
  for _, f in ipairs(M.fields()) do
    if f.name == name then
      return f
    end
  end
  return nil
end

---`vim.trim` is linear; `s:gsub("%s+$", "")` rescans a long inner whitespace run once per space.
---@param s string
---@return string
local function trim(s)
  return vim.trim(s)
end

---Drop trailing whitespace only (leading indentation marks a bullet).
---@param s string
---@return string
local function rtrim(s)
  return s:match("^(.*%S)") or ""
end

---The free-text sections at the end of the form (the body of the task), in form order. `names` are the headings
---the parser takes for the section (German and English); the template writes the first one.
---@type { key: "context"|"acceptance"|"notes", names: string[] }[]
M.SECTIONS = {
  { key = "context", names = { "kontext", "context" } },
  { key = "acceptance", names = { "akzeptanz", "acceptance" } },
  { key = "notes", names = { "notizen", "notes" } },
}

---Heading words of the sections per language, for the template.
---@type table<string, string[]>
local SECTION_HEADINGS = {
  de = { "Kontext", "Akzeptanz", "Notizen" },
  en = { "Context", "Acceptance", "Notes" },
}

---@param name string  heading word, any case
---@return string|nil key
local function section_key(name)
  name = name:lower()
  for _, s in ipairs(M.SECTIONS) do
    if vim.tbl_contains(s.names, name) then
      return s.key
    end
  end
  return nil
end

---Heading line of a choice field, e.g. `## kind (one)`.
---@param f Tasks.FormField
---@return string
local function heading(f)
  return ("## %s (%s)"):format(f.name, f.multi and "several" or "one")
end

---Fresh form text.
---@param opts? { area?: string, title?: string, summary?: string, areas?: string[], tags?: string, refs?: string, links?: string, ticks?: table<string, string|string[]>, hint?: string, lang?: "de"|"en" }
---  `ticks` overrides the ticked values per field name; `hint` is the second line (the keys of the user's setup);
---  `lang` picks the headings of the body sections (default `de`).
---@return string[] lines
function M.template(opts)
  opts = opts or {}
  local lines = {
    "# New task",
    opts.hint or "<!-- <Space>/<CR> tick, <C-s> submit, q cancel, g? help -->",
  }
  if opts.areas and #opts.areas > 0 then
    lines[#lines + 1] = "<!-- areas: " .. table.concat(opts.areas, ", ") .. " -->"
  end
  lines[#lines + 1] = "<!-- several areas (a, b): one task is created in each -->"
  lines[#lines + 1] = "Area: " .. (opts.area or "")
  lines[#lines + 1] = "Title: " .. (opts.title or "")
  lines[#lines + 1] = "Summary: " .. (opts.summary or "")
  for _, f in ipairs(M.fields()) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = heading(f)
    local ticked = {}
    local want = opts.ticks and opts.ticks[f.name]
    if want == nil then
      want = f.default
    end
    if type(want) == "string" then
      ticked[want] = true
    elseif type(want) == "table" then
      for _, v in ipairs(want) do
        ticked[tostring(v)] = true
      end
    end
    for _, v in ipairs(f.values) do
      lines[#lines + 1] = ("- [%s] %s"):format(ticked[v] and "x" or " ", v)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Tags: " .. (opts.tags or "")
  lines[#lines + 1] = "Refs: " .. (opts.refs or "")
  lines[#lines + 1] = "Links: " .. (opts.links or "")
  local headings = SECTION_HEADINGS[opts.lang or "de"] or SECTION_HEADINGS.de
  for _, h in ipairs(headings) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. h
    lines[#lines + 1] = ""
  end
  return lines
end

---@class Tasks.FormParsed
---@field area string
---@field title string
---@field summary string
---@field tags string
---@field refs string
---@field links string
---@field sections table<string, string>  # Free text per body section (`context`, `acceptance`, `notes`).
---@field ticks table<string, string[]>  # Ticked values per choice field, in form order.
---@field unknown string[]               # Ticked choices that are not in the value set.

---Read the form text.
---@param lines string[]
---@return Tasks.FormParsed
function M.parse(lines)
  ---@type Tasks.FormParsed
  local out = {
    area = "",
    title = "",
    summary = "",
    tags = "",
    refs = "",
    links = "",
    sections = {},
    ticks = {},
    unknown = {},
  }
  local current ---@type Tasks.FormField|nil
  local in_report = true -- the leading lines that start with `!` are the report of an earlier submit
  local section ---@type string|nil  -- body section being read: its lines are text, never fields
  local texts = {} ---@type table<string, string[]>
  for _, raw in ipairs(lines) do
    local line = rtrim(raw)
    if in_report and line:sub(1, 1) == "!" then
    -- the error report at the top: not form content
    elseif line:sub(1, 4) == "<!--" then
      in_report = false
    -- a hint: not form content
    else
      in_report = false
      local name = line:match("^##%s+([%w_]+)")
      -- a section heading is the whole line (`## Notizen`): `## Notes about x` inside a text is text
      local skey = name and line:match("^##%s+[%w_]+%s*$") and section_key(name)
      if skey then
        section, current = skey, nil
        texts[skey] = texts[skey] or {}
      elseif section then
        -- raw, not trimmed: indentation inside a text is the user's (a code block, a nested list); the choice
        -- lists come before the sections, a heading inside a text is part of it
        table.insert(texts[section], (raw:gsub("%s+$", "")))
      elseif name then
        section = nil
        current = field_by_name(name)
        if current then
          out.ticks[current.name] = out.ticks[current.name] or {}
        end
      else
        local key, value = line:match("^(%a+):%s*(.*)$")
        key = key and key:lower()
        if
          key == "area"
          or key == "title"
          or key == "summary"
          or key == "tags"
          or key == "refs"
          or key == "links"
        then
          out[key] = value
          current = nil
        else
          local mark, text = line:match("^%s*[-*]%s+%[(.)%]%s+(.*)$")
          if current and mark and (mark == "x" or mark == "X") then
            if vim.tbl_contains(current.values, text) then
              table.insert(out.ticks[current.name], text)
            else
              out.unknown[#out.unknown + 1] = current.name .. ": " .. text
            end
          end
        end
      end
    end
  end
  for key, list in pairs(texts) do
    out.sections[key] = vim.trim(table.concat(list, "\n"))
  end
  return out
end

---The values a valid form stands for, as `tasks.mutate.new` options.
---@class Tasks.FormValues
---@field area string        # The first area named.
---@field areas string[]     # Every area named, once each, in the order typed: one task is created in each.
---@field opts Tasks.NewOpts

---The area names of the `Area:` line: a comma list, blanks around a name dropped, a name once.
---@param text string
---@return string[]
function M.split_areas(text)
  local names = {}
  for part in vim.gsplit(text, ",", { plain = true }) do
    local name = trim(part)
    if name ~= "" and not vim.tbl_contains(names, name) then
      names[#names + 1] = name
    end
  end
  return names
end

---The message for a vault that has no areas: the cause is the vault (a wrong folder, or one that moved while
---Neovim still holds the old path), not the name typed. One text for the report in the form and the warning on open.
---@param root? string  the vault folder it looked in
---@return string
function M.no_areas_message(root)
  local where = (type(root) == "string" and root ~= "") and (": " .. root) or ""
  return "The vault has no areas"
    .. where
    .. " (wrong folder? The vault comes from setup({ vault }) or $TASKS_VAULT and is read at startup:"
    .. " restart Neovim after moving it)"
end

---Check a parsed form. `areas` (when given) is the set of areas the vault has; `root` (when given) names the vault
---in the message that says it has none.
---@param parsed Tasks.FormParsed
---@param areas? string[]
---@param root? string
---@param lang? "de"|"en"  # Headings of the body sections written into the task (default `de`).
---@return Tasks.FormValues|nil values
---@return string[] errors
function M.validate(parsed, areas, root, lang)
  local errors = {}
  local names = M.split_areas(parsed.area)
  if areas and #areas == 0 then
    -- No name can pass an empty list, so the name typed is not the problem: the vault is. Say that, and where it
    -- looked.
    errors[#errors + 1] = M.no_areas_message(root)
  elseif #names == 0 then
    errors[#errors + 1] = "Area is required"
  elseif areas then
    for _, name in ipairs(names) do
      if not vim.tbl_contains(areas, name) then
        errors[#errors + 1] = "Area "
          .. require("tasks_nvim.vault").not_an_area_message(name, areas)
      end
    end
  end
  local title = trim(parsed.title)
  if title == "" then
    errors[#errors + 1] = "Title is required"
  end
  for _, u in ipairs(parsed.unknown) do
    errors[#errors + 1] = "unknown choice: " .. u
  end

  ---@type table<string, any>
  local opts = { title = title }
  for _, f in ipairs(M.fields()) do
    local ticked = parsed.ticks[f.name] or {}
    if not f.multi and #ticked > 1 then
      errors[#errors + 1] = ("%s: pick one, %d are ticked (%s)"):format(
        f.name,
        #ticked,
        table.concat(ticked, ", ")
      )
    elseif #ticked > 0 then
      opts[f.name] = f.multi and table.concat(ticked, ",") or ticked[1]
    end
  end
  local tags, refs = trim(parsed.tags), trim(parsed.refs)
  if tags ~= "" then
    opts.tags = tags
  end
  if refs ~= "" then
    opts.refs = refs
  end
  local links = trim(parsed.links)
  if links ~= "" then
    for _, link in ipairs(vim.split(links, ",", { plain = true, trimempty = true })) do
      if not model.is_web_link(trim(link)) then
        errors[#errors + 1] = ("Links: '%s' is not an http:// or https:// address"):format(
          trim(link)
        )
      end
    end
    opts.web_links = links
  end
  local summary = trim(parsed.summary)
  if summary ~= "" then
    opts.summary = summary
  end
  local texts, any = {}, false
  for _, s in ipairs(M.SECTIONS) do
    texts[s.key] = parsed.sections[s.key] or ""
    any = any or texts[s.key] ~= ""
  end
  if any then
    -- All three sections are written (an empty one keeps the template's placeholder); with nothing typed the
    -- engine writes the same sections itself.
    opts.body = require("tasks_nvim.mutate").body_sections(texts, lang)
    opts.lang = lang
  end
  if #errors > 0 then
    return nil, errors
  end
  return { area = names[1], areas = names, opts = opts }, errors
end

---Flip the choice bullet on line `lnum`. A single-choice field ends with at
---most one tick: ticking a bullet clears its siblings, ticking the ticked one
---clears it. A multi-choice field just flips the bullet.
---@param lines string[]
---@param lnum integer  1-based
---@return string[]|nil new_lines  `nil` when the line is not a bullet of a choice field.
function M.toggle(lines, lnum)
  local line = lines[lnum]
  if not line then
    return nil
  end
  local indent, mark, text = line:match("^(%s*[-*]%s+)%[(.)%](.*)$")
  if not indent then
    return nil
  end
  -- The field is the nearest heading above the bullet.
  local f ---@type Tasks.FormField|nil
  local first = lnum
  for i = lnum - 1, 1, -1 do
    local name = lines[i]:match("^##%s+([%w_]+)")
    if name then
      f = field_by_name(name)
      first = i + 1
      break
    elseif not lines[i]:match("^%s*[-*]%s+%[.%]") then
      return nil
    end
  end
  if not f then
    return nil
  end
  local out = vim.deepcopy(lines)
  local was_ticked = mark == "x" or mark == "X"
  if not f.multi and not was_ticked then
    local i = first
    while out[i] and out[i]:match("^%s*[-*]%s+%[.%]") do
      out[i] = out[i]:gsub("^(%s*[-*]%s+)%[.%]", "%1[ ]")
      i = i + 1
    end
  end
  out[lnum] = indent .. "[" .. (was_ticked and " " or "x") .. "]" .. text
  return out
end

---Fix a single-choice list that ended up with several ticks (a toggle done by
---another plugin, say) by keeping the tick on line `keep`.
---@param lines string[]
---@param keep integer  1-based line that was just ticked
---@return string[] new_lines
function M.normalize(lines, keep)
  local out = vim.deepcopy(lines)
  local f ---@type Tasks.FormField|nil
  local first
  for i = keep - 1, 1, -1 do
    local name = out[i]:match("^##%s+([%w_]+)")
    if name then
      f = field_by_name(name)
      first = i + 1
      break
    end
  end
  if not f or f.multi then
    return out
  end
  local i = first
  while out[i] and out[i]:match("^%s*[-*]%s+%[.%]") do
    if i ~= keep and out[i]:match("^%s*[-*]%s+%[[xX]%]") then
      out[i] = out[i]:gsub("^(%s*[-*]%s+)%[.%]", "%1[ ]")
    end
    i = i + 1
  end
  return out
end

---Lines for the error report put at the top of the form.
---@param errors string[]
---@return string[]
function M.error_lines(errors)
  local out = { "! The form was not submitted:" }
  for _, e in ipairs(errors) do
    out[#out + 1] = "! - " .. e
  end
  return out
end

---Drop an earlier error report from the form text.
---@param lines string[]
---@return string[]
function M.strip_errors(lines)
  -- Only the report at the top (`error_lines` puts it there): a `![shot](x.png)` or `!important` line of a text
  -- further down is the person's, not ours.
  local out = {}
  local in_report = true
  for _, l in ipairs(lines) do
    if in_report and l:sub(1, 1) == "!" then
      -- part of the report
    else
      in_report = false
      out[#out + 1] = l
    end
  end
  return out
end

return M
