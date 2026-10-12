---@brief `scripts/tasks-host.lua` -- the persistent engine: answers the machine contract over stdin and stdout.
---@description
---     nvim --headless -u NONE -i NONE -n -l scripts/tasks-host.lua
---
--- The vault and the switches come from the environment, as for `scripts/tasks.lua` (`TASKS_VAULT`,
--- `TASKS_EXTRA_AREAS`, `LIB_NVIM_DIR`, ...). See `tasks_nvim.host` for the line protocol. The process ends when its
--- stdin ends, so a client that dies never leaves it behind.

-- Absolute: `nvim -l` from inside scripts/ gives a bare relative name (see scripts/tasks.lua).
local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
vim.opt.rtp:prepend(plugin_root)

local lib = require("tasks_nvim.boot").find_lib(plugin_root)
if not lib then
  io.stderr:write(
    "error: lib.nvim not found (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n"
  )
  os.exit(2)
end
vim.opt.rtp:append(lib)

require("tasks_nvim.host").serve(io.stdin, io.stdout)
io.stdout:flush()
os.exit(0)
