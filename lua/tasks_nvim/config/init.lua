---@module 'tasks_nvim.config'
---@brief Merge `setup()` options over DEFAULTS, with a notification for what had to be ignored.
---@description
--- The option tree is described once, in `SCHEMA`: the known keys, the type of each, and for numbers the
--- lower bound. A bad key or value is reported and ignored, the default stays (ERR-22, ERR-50); a section
--- (`dashboard`, `staleness`, `ci`) merges key by key, so `setup({ dashboard = { watch = false } })` keeps
--- the debounce.

local DEFAULTS = require("tasks_nvim.config.DEFAULTS")

local M = {}

---@type Tasks.Opts
local state = vim.deepcopy(DEFAULTS)

---The top-level keys a `setup()` set (and that passed the check), so a caller can tell a chosen value from the
---default (`wikilinks.mode`: an explicit `links = "plain"` wins over `$TASKS_LINKS`).
---@type table<string, boolean>
local given = {}

---@alias Tasks.ConfigType "string"|"boolean"|"string_list"|"posint"|"keymap"|"backend"|"value"|"effort"|"lists"|"finished_window"|"links"

---@type table<string, Tasks.ConfigType|table<string, Tasks.ConfigType>>
local SCHEMA = {
  vault = "string",
  extra_areas = "string_list",
  links = "links",
  dashboard = { watch = "boolean", debounce_ms = "posint", backend = "backend" },
  staleness = { git_timeout_ms = "posint", budget_ms = "posint", repo_bases = "string_list" },
  ci = { lint_timeout_ms = "posint", trust_vault_lint = "boolean" },
  next = { popup = "boolean", cdx_hint = "boolean" },
  chain = { marker_docs = "string_list" },
  quick_wins = { min_value = "value", max_effort = "effort" },
  lists = "lists",
  steps = { ask_finish = "boolean" },
  reminders = { on_start = "boolean" },
  completion = { finished = "finished_window" },
  keys = { dashboard = "keymap", dashboard_input = "keymap", form = "keymap" },
}

---What `validate` threw away (each message once), for `:checkhealth`: a one-time notification is easy to miss.
---@type string[]
local ignored = {}

---Messages nobody has been told about yet. The config layer only collects them (it is read by the engine
---modules and must not call a front end); `tasks_nvim.setup` hands them to the notification channel.
---@type string[]
local unannounced = {}

---@param msg string
local function warn(msg)
  if not vim.tbl_contains(ignored, msg) then
    ignored[#ignored + 1] = msg
    unannounced[#unannounced + 1] = msg
  end
end

---@param list any
---@return boolean
local function is_string_list(list)
  if type(list) ~= "table" or not vim.islist(list) then
    return false
  end
  for _, v in ipairs(list) do
    if type(v) ~= "string" then
      return false
    end
  end
  return true
end

---Check one value; the second result is the value to keep (normalised) or `nil` with the reason in the third.
---@param kind Tasks.ConfigType
---@param value any
---@return boolean ok
---@return any|nil kept
---@return string|nil why
local function check(kind, value)
  if kind == "string" then
    if type(value) == "string" then
      return true, vim.fs.normalize(value), nil
    end
    return false, nil, "a string"
  elseif kind == "boolean" then
    if type(value) == "boolean" then
      return true, value, nil
    end
    return false, nil, "true or false"
  elseif kind == "string_list" then
    if is_string_list(value) then
      return true, vim.deepcopy(value), nil
    end
    return false, nil, "a list of strings"
  elseif kind == "keymap" then
    if type(value) ~= "table" then
      return false, nil, "a table of action = key"
    end
    for action, key in pairs(value) do
      if type(action) ~= "string" or (type(key) ~= "string" and key ~= false) then
        return false, nil, "a table of action = key (a string) or false"
      end
    end
    return true, vim.deepcopy(value), nil
  elseif kind == "backend" then
    if value == "auto" or value == "snacks" or value == "kit" or value == "select" then
      return true, value, nil
    end
    return false, nil, 'one of "auto", "snacks", "kit", "select"'
  elseif kind == "links" then
    if value == "plain" or value == "wikilink" then
      return true, value, nil
    end
    return false, nil, 'one of "plain", "wikilink"'
  elseif kind == "lists" then
    -- Only the shape here; every list is checked, and named in its complaint, by `tasks_nvim.lists`.
    if type(value) == "table" and (next(value) == nil or not vim.islist(value)) then
      return true, vim.deepcopy(value), nil
    end
    return false, nil, "a table of name = list definition"
  elseif kind == "value" then
    if type(value) == "number" and value >= 1 and value <= 5 and value == math.floor(value) then
      return true, value, nil
    end
    return false, nil, "a whole number from 1 to 5"
  elseif kind == "effort" then
    -- Lazily: `model` must not be a load-time dependency of the config layer.
    if type(value) == "string" then
      local norm = value:match("^%a+$") and value:upper() or value:lower()
      if require("tasks_nvim.model").effort_days(norm) ~= nil then
        return true, norm, nil
      end
    end
    return false, nil, "an effort (XS, S, M, L, XL or days like 0.5d)"
  elseif kind == "finished_window" then
    if type(value) == "boolean" then
      return true, value, nil
    end
    if type(value) == "number" and value > 0 and value == math.floor(value) then
      return true, value, nil
    end
    return false, nil, "true, false or the number of days to go back"
  elseif kind == "posint" then
    if type(value) == "number" and value > 0 and value == math.floor(value) then
      return true, value, nil
    end
    return false, nil, "a positive whole number"
  end
  return false, nil, "a known type"
end

---A bad key or value never reaches the engine: it is reported and the default stays.
---@param opts any
---@return Tasks.Opts validated  only the keys that passed
function M.validate(opts)
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" then
    warn(("setup() expects a table, got %s -- using the defaults"):format(type(opts)))
    return {}
  end
  local out = {}
  local unknown = {}
  for key, value in pairs(opts) do
    local spec = SCHEMA[key]
    if spec == nil then
      unknown[#unknown + 1] = tostring(key)
    elseif type(spec) == "string" then
      local good, kept, why = check(spec, value)
      if good then
        out[key] = kept
      else
        warn(("setup(): `%s` must be %s, got %s -- ignored"):format(key, why, type(value)))
      end
    elseif type(value) ~= "table" then
      warn(("setup(): `%s` must be a table, got %s -- ignored"):format(key, type(value)))
    else
      local section = {}
      for subkey, subvalue in pairs(value) do
        local sub = spec[subkey]
        if sub == nil then
          unknown[#unknown + 1] = key .. "." .. tostring(subkey)
        else
          local good, kept, why = check(sub, subvalue)
          if good and sub == "keymap" then
            -- Only the actions the plugin has: a typo must not silently bind nothing.
            local known = DEFAULTS.keys[subkey] or {}
            local bad = {}
            for action in pairs(kept) do
              if known[action] == nil then
                bad[#bad + 1] = action
                kept[action] = nil
              end
            end
            if #bad > 0 then
              table.sort(bad)
              unknown[#unknown + 1] = key .. "." .. subkey .. "." .. table.concat(bad, ",")
            end
          end
          if good then
            section[subkey] = kept
          else
            warn(
              ("setup(): `%s.%s` must be %s, got %s -- ignored"):format(
                key,
                subkey,
                why,
                type(subvalue)
              )
            )
          end
        end
      end
      out[key] = section
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    warn("setup(): unknown option(s) ignored: " .. table.concat(unknown, ", "))
  end
  return out
end

---Set the options and return a copy of the state. Every call starts from the defaults, so an option an
---earlier call set and this one leaves out is back at its default; `ignored()` lists what THIS call threw
---away (the earlier call's problems belong to options that are no longer in force).
---@param opts? table
---@return Tasks.Opts
function M.merge(opts)
  state = vim.deepcopy(DEFAULTS)
  given = {}
  ignored = {}
  local checked = M.validate(opts)
  for key in pairs(checked) do
    given[key] = true
  end
  state = vim.tbl_deep_extend("force", state, checked)
  if checked.lists then
    -- The named lists are replaced as a whole, not merged: a later `setup({ lists })` is the complete set.
    state.lists = checked.lists
  end
  return vim.deepcopy(state)
end

---A copy: the state changes only through `merge`.
---@return Tasks.Opts
function M.get()
  return vim.deepcopy(state)
end

---Whether a `setup()` set the top-level option `key` (a value that was ignored does not count): the value `get`
---returns is then the user's choice, not the default.
---@param key string
---@return boolean
function M.given(key)
  return given[key] == true
end

---The messages collected since the last call, each returned once.
---@return string[]
function M.take_unannounced()
  local out = unannounced
  unannounced = {}
  return out
end

---What `setup()` ignored (unknown keys, wrong types), one message each.
---@return string[]
function M.ignored()
  return vim.deepcopy(ignored)
end

return M
