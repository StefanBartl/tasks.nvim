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

  start("tasks.nvim: optional pieces")
  if pcall(require, "snacks") then
    ok("snacks.nvim -- the interactive dashboard")
  else
    info(
      "snacks.nvim not found -- `:Tasks list` falls back to a Markdown table in a scratch buffer"
    )
  end
  if vim.fn.executable("git") == 1 then
    ok("git -- `--stale=refs` dates files by their last commit")
  else
    warn("git not found -- `--stale=refs` falls back to file modification times")
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
end

return M
