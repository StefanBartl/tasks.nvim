---@module 'tasks_nvim.config'
---@brief Merge `setup()` options over DEFAULTS, with a notification for what had to be ignored.

local DEFAULTS = require("tasks_nvim.config.DEFAULTS")

local M = {}

---@type Tasks.Opts
local state = vim.deepcopy(DEFAULTS)

---@type table<string, true>
local KNOWN_KEYS = { vault = true, extra_areas = true }

---What `validate` threw away, for `:checkhealth` (a one-time notification is easy to miss).
---@type string[]
local ignored = {}

---@param msg string
local function warn(msg)
  ignored[#ignored + 1] = msg
  vim.schedule(function()
    vim.notify("[tasks.nvim] " .. msg, vim.log.levels.WARN)
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

---A bad key or value never reaches the engine: it is reported and the default stays (ERR-22, ERR-50).
---@param opts any
---@return Tasks.Opts validated  only the keys that passed
function M.validate(opts)
  ignored = {}
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" then
    warn(("setup() expects a table, got %s -- using the defaults"):format(type(opts)))
    return {}
  end
  local out = {}
  local unknown = {}
  for key in pairs(opts) do
    if not KNOWN_KEYS[key] then
      unknown[#unknown + 1] = tostring(key)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    warn("setup(): unknown option(s) ignored: " .. table.concat(unknown, ", "))
  end
  if opts.vault ~= nil then
    if type(opts.vault) == "string" then
      out.vault = vim.fs.normalize(opts.vault)
    else
      warn(("setup(): `vault` must be a string, got %s -- ignored"):format(type(opts.vault)))
    end
  end
  if opts.extra_areas ~= nil then
    if is_string_list(opts.extra_areas) then
      out.extra_areas = vim.deepcopy(opts.extra_areas)
    else
      warn("setup(): `extra_areas` must be a list of strings -- ignored")
    end
  end
  return out
end

---Merge the options over the current state and return it.
---@param opts? table
---@return Tasks.Opts
function M.merge(opts)
  state = vim.tbl_extend("force", state, M.validate(opts))
  return state
end

---A copy: the state changes only through `merge`.
---@return Tasks.Opts
function M.get()
  return vim.deepcopy(state)
end

---What the last `setup()` ignored (unknown keys, wrong types), one message each.
---@return string[]
function M.ignored()
  return vim.deepcopy(ignored)
end

return M
