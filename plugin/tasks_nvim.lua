-- tasks.nvim: registers `:Tasks` and `:TasksVault`. Set `vim.g.tasks_nvim_no_command = true` to register your own
-- verb instead of `:Tasks`, `vim.g.tasks_nvim_no_vault_command = true` to leave out `:TasksVault` (the two are
-- independent).
if vim.g.loaded_tasks_nvim then
  return
end
vim.g.loaded_tasks_nvim = true
if not vim.g.tasks_nvim_no_command then
  require("tasks_nvim.bindings.usrcmds").register()
end
if not vim.g.tasks_nvim_no_vault_command then
  require("tasks_nvim.bindings.usrcmds.vault").register()
end
