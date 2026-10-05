-- tasks.nvim: registers `:Tasks`. Set `vim.g.tasks_nvim_no_command = true` to register your own verb instead.
if vim.g.loaded_tasks_nvim or vim.g.tasks_nvim_no_command then
  return
end
vim.g.loaded_tasks_nvim = true
require("tasks_nvim.ui.command").register()
