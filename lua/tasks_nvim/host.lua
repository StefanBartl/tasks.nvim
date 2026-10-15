---@module 'tasks_nvim.host'
---@brief The persistent engine process: the machine contract over a line protocol on stdin and stdout.
---@description
--- `nvim --headless -u NONE -l scripts/tasks-host.lua` does what `tasks call <method>` does, many times in one
--- process: the modules are loaded once and a scan of a vault that did not change is answered from the parse cache
--- (`model`, keyed by size and modification time, with the racy-file rule), so a question costs milliseconds and not
--- a process start. Nothing else changes: the answers are the documents of `tasks_nvim.api`, byte for byte.
---
--- The protocol (`ready\t1`, then `<id>\t<method>\t<params>` in and `<id>\t<document>` out, one line each) and its
--- framing are `lib.nvim.contract.host`'s; the vault and lib.nvim are found by `scripts/tasks-host.lua`.
---
--- Not its job: finding the vault or lib.nvim (`scripts/tasks-host.lua`), the document (`api`, `contract`).

return require("lib.nvim.contract.host").make({
  api = require("tasks_nvim.api"),
})
