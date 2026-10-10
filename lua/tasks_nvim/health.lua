---@module 'tasks_nvim.health'
---@brief `:checkhealth tasks_nvim` diagnostics.
---@description
--- Read-only: reports what the engine needs (Neovim, lib.nvim submodules, a vault), what the optional front-end
--- pieces need (snacks.nvim for the dashboard, git for `--stale=refs`) and which soft dependencies are present.
--- Nothing is created or changed.

local M = {}

---@return nil
function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error_ = health.error or health.report_error
  local info = health.info or health.report_info

  start("tasks.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    error_("tasks.nvim needs Neovim 0.10+", { "Upgrade Neovim to 0.10+" })
  end

  -- lib.nvim is a hard dependency; these are the submodules the engine and the front ends call.
  local required = {
    { "lib.nvim.markdown.frontmatter", "task files are read and written through it" },
    { "lib.nvim.fs.collect_recursive", "the vault scan" },
    { "lib.nvim.checkpoint", "`done` rolls back from it" },
    { "lib.nvim.bindings.usercmd.composer", "the :Tasks command" },
    { "lib.nvim.harvest", "delivery of lists (--to=)" },
    { "lib.nvim.notify", "messages" },
    { "lib.nvim.fs.read", "file reads" },
    { "lib.nvim.fs.mkdirp", "creating folders" },
    { "lib.nvim.fs.scan_cached", "the cached vault scan (completion)" },
    { "lib.nvim.cross.fs.mutate", "moving and removing files" },
    { "lib.nvim.ui.list", "quickfix delivery (--to=qf)" },
    { "lib.nvim.harvest.render", "Markdown and CSV tables" },
    { "lib.nvim.cross.fs.expand_path", "`--to=file:` paths" },
    { "lib.nvim.cross.fs.separators.unify_slashes", "path normalisation" },
    { "lib.nvim.cross.platform.is_windows", "platform checks" },
    { "lib.nvim.system.env", "the repos folder for `--stale=refs`" },
  }
  local lib_ok = true
  for _, req in ipairs(required) do
    if pcall(require, req[1]) then
      ok(("%s -- %s"):format(req[1], req[2]))
    else
      lib_ok = false
      error_(
        ("%s missing -- %s"):format(req[1], req[2]),
        { 'Install or update "StefanBartl/lib.nvim"' }
      )
    end
  end
  if not lib_ok then
    return
  end

  start("tasks.nvim: vault")
  local vault = require("tasks_nvim.vault")
  local root, err = vault.root()
  if not root then
    warn(tostring(err), { "setup({ vault = <dir> }) or set $TASKS_VAULT" })
  else
    local areas = vault.areas(root)
    ok(("vault %s: %d area(s)"):format(root, #areas))
    local extras = vault.extra_areas()
    if #extras > 0 then
      info("extra areas: " .. table.concat(extras, ", "))
    end
  end

  local ignored = require("tasks_nvim.config").ignored()
  for _, msg in ipairs(ignored) do
    warn("setup() ignored an option: " .. msg)
  end
  if #ignored == 0 then
    ok("setup() options are valid")
  end

  -- Named lists: what each source contributes, and every list that had to be skipped (named, with the reason).
  local lists = require("tasks_nvim.lists")
  local entries, list_notes = lists.all()
  local by_source = { builtin = 0, saved = 0, config = 0 }
  for _, e in ipairs(entries) do
    by_source[e.source] = by_source[e.source] + 1
  end
  info(
    ("named lists: %d (built in as shown: %d, saved: %d, setup(): %d); saved lists file: %s"):format(
      #entries,
      by_source.builtin,
      by_source.saved,
      by_source.config,
      lists.path()
    )
  )
  for _, msg in ipairs(list_notes) do
    warn(msg)
  end

  start("tasks.nvim: command")
  if vim.fn.exists(":Tasks") == 2 then
    ok(":Tasks is registered")
  elseif vim.g.tasks_nvim_no_command then
    info(":Tasks is not registered (vim.g.tasks_nvim_no_command is set)")
  else
    warn(
      ":Tasks is not registered",
      { "call require('tasks_nvim').setup({ ... }) or load the plugin on `cmd = 'Tasks'`" }
    )
  end

  start("tasks.nvim: optional pieces")
  if pcall(require, "snacks") then
    ok("snacks.nvim -- the interactive dashboard")
  else
    info("snacks.nvim not found -- the dashboard falls back to a plain vim.ui.select list")
  end
  if vim.fn.executable("git") == 1 then
    ok("git -- `--stale=refs` dates files by their last commit")
  else
    info("git not found -- `--stale=refs` uses file modification times")
  end
  if pcall(require, "mdview") then
    ok("mdview.nvim -- browser preview (`:Tasks preview`, `--to=mdview`)")
  else
    info("mdview.nvim not found -- no browser preview")
  end
  if pcall(require, "ui.kit") then
    ok("ui.nvim -- themed confirmations")
  else
    info("ui.nvim not found -- confirmations use vim.ui.select")
  end
  if pcall(require, "cascade") then
    ok("cascade.nvim -- cycling values in the task form")
  else
    info("cascade.nvim not found -- the form has no value cycling")
  end
  if pcall(require, "pickers.command") then
    ok("pickers.nvim -- `:Tasks folder`")
  else
    info("pickers.nvim not found -- `:Tasks folder` uses a plain vim.ui.select list")
  end
  local soft = {
    { "lib.nvim.progress", "a progress entry while the dashboard writes" },
    { "lib.nvim.store.project", "remembering the dashboard filter and sort" },
    { "lib.nvim.fs.watch", "live refresh of the dashboard" },
  }
  for _, req in ipairs(soft) do
    if pcall(require, req[1]) then
      ok(("%s -- %s"):format(req[1], req[2]))
    else
      info(("%s not found (older lib.nvim?) -- no %s"):format(req[1], req[2]))
    end
  end
end

return M
