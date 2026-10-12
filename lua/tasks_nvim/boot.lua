---@module 'tasks_nvim.boot'
---@brief Finding lib.nvim for the headless entry points (`scripts/tasks.lua`, `scripts/tasks-host.lua`).
---@description
--- `-u NONE` loads no plugin manager, so the scripts put this plugin and lib.nvim on the runtimepath themselves.
--- This is the one place that knows where lib.nvim may be, so both scripts find the same one.

local M = {}

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

---The checkout of lib.nvim: `$LIB_NVIM_DIR`, `$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`, `.deps/lib.nvim`, a sibling
---checkout, then lazy.nvim's data folder.
---@param plugin_root string  # This plugin's folder.
---@return string|nil
function M.find_lib(plugin_root)
  local repos = vim.env.REPOS_DIR
  -- Not a list literal: `ipairs` would stop at the first unset variable.
  local candidates = {
    LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR,
    LIB_NVIM_PATH = vim.env.LIB_NVIM_PATH,
    REPOS_DIR = (repos and repos ~= "") and (repos .. "/lib.nvim") or nil,
    deps = plugin_root .. "/.deps/lib.nvim",
    sibling = vim.fs.dirname(plugin_root) .. "/lib.nvim",
    lazy = vim.fn.stdpath("data") .. "/lazy/lib.nvim",
  }
  for _, key in ipairs({ "LIB_NVIM_DIR", "LIB_NVIM_PATH", "REPOS_DIR", "deps", "sibling", "lazy" }) do
    if has_lib(candidates[key]) then
      return candidates[key]
    end
  end
  return nil
end

return M
