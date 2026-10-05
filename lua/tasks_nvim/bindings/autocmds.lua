---@module 'tasks_nvim.bindings.autocmds'
---@brief Autocommands of tasks.nvim: none at load time.
---@description
--- Nothing is registered by `setup()` or `plugin/`. The dashboard refreshes through libuv `fs_event`
--- handles that live and die with its window (`tasks_nvim.ui.dash_watch`). The only autocommands are the
--- ones the browser preview makes while a temporary preview file exists (group `TasksPreviewTemp`,
--- `tasks_nvim.ui.preview`): they clean it up on buffer wipe and on `VimLeavePre`. One more is opt-in:
--- `setup({ steps = { ask_finish = true } })` registers the group `TasksStepsWatch` (`tasks_nvim.ui.steps_watch`),
--- which looks only at task files of the vault.

---@type table[]
return {}
