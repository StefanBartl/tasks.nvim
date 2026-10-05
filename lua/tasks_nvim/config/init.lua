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

---@alias Tasks.ConfigType "string"|"boolean"|"string_list"|"posint"

---@type table<string, Tasks.ConfigType|table<string, Tasks.ConfigType>>
local SCHEMA = {
  vault = "string",
  extra_areas = "string_list",
  dashboard = { watch = "boolean", debounce_ms = "posint" },
  staleness = { git_timeout_ms = "posint", budget_ms = "posint", repo_bases = "string_list" },
  ci = { lint_timeout_ms = "posint" },
}

---What `validate` threw away (each message once), for `:checkhealth`: a one-time notification is easy to miss.
---@type string[]
local ignored = {}

---@param msg string
local function warn(msg)
  if not vim.tbl_contains(ignored, msg) then
    ignored[#ignored + 1] = msg
  end
  vim.schedule(function()
    require("lib.nvim.notify").create("[tasks]").warn(msg)
  end)
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

---Merge the options over the current state and return a copy of it.
---@param opts? table
---@return Tasks.Opts
function M.merge(opts)
  -- What any `setup()` threw away stays listed for `:checkhealth`: a second call that ignores nothing
  -- must not erase the first call's messages.
  state = vim.tbl_deep_extend("force", state, M.validate(opts))
  return vim.deepcopy(state)
end

---A copy: the state changes only through `merge`.
---@return Tasks.Opts
function M.get()
  return vim.deepcopy(state)
end

---What `setup()` ignored (unknown keys, wrong types), one message each.
---@return string[]
function M.ignored()
  return vim.deepcopy(ignored)
end

return M
