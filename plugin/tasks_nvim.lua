-- tasks.nvim: registers `:Tasks` and `:TasksVault`. Set `vim.g.tasks_nvim_no_command = true` to register your own verb
-- instead, `vim.g.tasks_nvim_no_vault_command = true` to leave out `:TasksVault`.
if vim.g.loaded_tasks_nvim or vim.g.tasks_nvim_no_command then
  return
end
vim.g.loaded_tasks_nvim = true
require("tasks_nvim.bindings.usrcmds").register()
