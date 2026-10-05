---@module 'tasks_nvim.soft'
---@brief The one place that asks "is this optional plugin there, and does it have what we call?".
---@description
--- tasks.nvim works without snacks.nvim, ui.nvim, pickers.nvim, cascade.nvim, mdview.nvim and the newer
--- lib.nvim submodules; each of them is probed here, with the fields the caller is about to use, so a missing
--- plugin and an older plugin that lacks the function look the same (not available) and the caller falls back.
--- `health.lua` deliberately does NOT use this: it reports what `require` really says.

local M = {}

---@param name string                module name
---@param fields? string[]           fields that must exist (the calls the caller is about to make)
---@return table|nil mod             nil when the module is missing, no table, or lacks a field
function M.require(name, fields)
  local ok, mod = pcall(require, name)
  if not ok or type(mod) ~= "table" then
    return nil
  end
  for _, field in ipairs(fields or {}) do
    if mod[field] == nil then
      return nil
    end
  end
  return mod
end

---@param name string
---@param fields? string[]
---@return boolean
function M.available(name, fields)
  return M.require(name, fields) ~= nil
end

return M
