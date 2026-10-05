-- TESTS/run.lua -- headless spec runner for tasks.nvim (plain Lua, no UI, no plugin except lib.nvim).
--
-- Run from anywhere:
--   nvim -n -i NONE --headless -u NONE -l TESTS/run.lua
-- One spec only (a substring of its file name):
--   nvim -n -i NONE --headless -u NONE -l TESTS/run.lua tasks_model
--
-- lib.nvim is looked up in $LIB_NVIM_DIR, $LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, ./.deps/lib.nvim, a sibling
-- checkout and lazy's data folder. Exit 0: all specs pass, 1: one failed, 2: lib.nvim not found / no spec matched.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local tests_dir = vim.fs.normalize(vim.fs.dirname(script))
local root = vim.fs.dirname(tests_dir)

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

---@return string|nil
local function find_lib()
  local repos = vim.env.REPOS_DIR
  local candidates = {
    vim.env.LIB_NVIM_DIR,
    vim.env.LIB_NVIM_PATH,
    (repos and repos ~= "") and (repos .. "/lib.nvim") or "",
    root .. "/.deps/lib.nvim",
    vim.fs.dirname(root) .. "/lib.nvim",
    vim.fn.stdpath("data") .. "/lazy/lib.nvim",
  }
  for i = 1, 6 do
    if has_lib(candidates[i]) then
      return candidates[i]
    end
  end
  return nil
end

local lib = find_lib()
if not lib then
  io.stderr:write(
    "error: lib.nvim not found (set LIB_NVIM_DIR, or LIB_NVIM_PATH, or REPOS_DIR with a lib.nvim checkout; also looked in .deps/lib.nvim, next to this repo and in lazy.nvim data)\n"
  )
  os.exit(2)
end

vim.opt.rtp:prepend(root)
vim.opt.rtp:append(lib)
-- Specs that start a child Neovim (the CLI end-to-end spec) find lib.nvim the same way.
vim.env.LIB_NVIM_DIR = lib
-- No spec (nor a child Neovim it starts) may touch the real frecency file in stdpath("state").
vim.env.TASKS_FRECENCY_FILE = vim.fn.tempname() .. "-tasks-frecency.json"
-- Isolated cache home, so lib.nvim.store never writes below the real stdpath("cache").
local cache_home = vim.fn.tempname() .. "-cache"
vim.env.XDG_CACHE_HOME = cache_home

local H = dofile(tests_dir .. "/harness.lua")

local specs = {}
for name, kind in vim.fs.dir(tests_dir) do
  if kind == "file" and name:match("_spec%.lua$") then
    specs[#specs + 1] = name
  end
end
table.sort(specs)

local wanted = {}
for i = 1, #(arg or {}) do
  wanted[#wanted + 1] = arg[i]
end

---Straight to stdout: `print` in a headless Neovim goes through the message area.
---@param s string
local function say(s)
  io.stdout:write(s, "\n")
end

local ran, failed = 0, 0
for _, name in ipairs(specs) do
  local selected = #wanted == 0
  for _, w in ipairs(wanted) do
    if name:find(w, 1, true) then
      selected = true
    end
  end
  if selected then
    ran = ran + 1
    local run = dofile(tests_dir .. "/" .. name)
    local ok, err = pcall(run, H)
    H.cleanup()
    vim.fn.delete(cache_home, "rf")
    if ok then
      say(("ok    %s"):format(name))
    else
      failed = failed + 1
      say(("FAIL  %s\n      %s"):format(name, tostring(err)))
    end
  end
end

if ran == 0 then
  say("no spec matched the given name(s)")
  os.exit(2)
end
if failed > 0 then
  say(("\n%d of %d spec(s) failed"):format(failed, ran))
  os.exit(1)
end
say(("\nTASKS_TESTS_OK (%d spec(s))"):format(ran))
