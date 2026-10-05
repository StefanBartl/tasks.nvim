---@brief `scripts/tasks-ci.lua` -- the vault gate for CI (check + index --check + md_lint), exit 0/1.
---@description
--- Same as `scripts/tasks.lua ci`: this file only puts `ci` in front of the
--- arguments, so a pipeline has one obvious entry point.
---
---     nvim --headless -u NONE -l scripts/tasks-ci.lua --vault=<vault>
---     nvim --headless -u NONE -l scripts/tasks-ci.lua --strict          # warnings fail too
---     nvim --headless -u NONE -l scripts/tasks-ci.lua --no-lint         # skip md_lint
---
--- Exit code: 0 all steps passed, 1 a step failed, 2 a usage error. The vault
--- is `--vault=`, else `$TASKS_VAULT`; lib.nvim
--- is found as in `scripts/tasks.lua` (`$LIB_NVIM_DIR`, ...). For `$VAR/...`
--- links in md_lint, put lsp.nvim on `$REPOS_DIR` (or lazy's data folder).

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local dir = vim.fs.dirname(vim.fs.normalize(script))

local argv = { "ci" }
for i = 1, #(arg or {}) do
  argv[#argv + 1] = arg[i]
end
_G.arg = argv

dofile(dir .. "/tasks.lua")
