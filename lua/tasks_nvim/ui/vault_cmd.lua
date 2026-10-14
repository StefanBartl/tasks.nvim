---@module 'tasks_nvim.ui.vault_cmd'
---@brief The handlers behind `:TasksVault` -- open, copy, paste and search the Backlog (or another part) of an area.
---@description
--- `:TasksVault <verb> [<area>] [<part>]`. The verb says what happens, the area (a folder of the vault; the
--- area of the current buffer when left out; a picker when that finds none) and the part (`backlog`,
--- `features`, `tasks`, `roadmap`, `all`; default `backlog`) say where.
---
---   open       the index of the part in a buffer (`Backlog/README.md`), else its folder in the explorer
---   clipboard  the path of the folder to the + register   (--rel: relative to the current file, --file: the index file)
---   paste      the same path at the cursor
---   link       a Markdown link to the part at the cursor, relative to the current file
---   find|grep  a pickers.nvim picker rooted at the folder (files by name, content)
---   tree       the folder in the file explorer
---   cdx        a ready prompt for Claude Code naming the folder to the + register
---   new        a dated note in Backlog/FEATURES|TASKS (`new feature|task <title...> [--area=]`)
---   create     a vault folder (and areas): says first what happens and what is left to you; used for this session
---   status     the vault in use
---
--- With no vault every verb but `create` and `status` says the same thing once and does nothing else.
---
--- Not its job: the paths and the writes (`tasks_nvim.vault_ops`), the grammar (`ui/vault_routes`).

local notify = require("lib.nvim.notify").create("[tasks vault]")

local fsio = require("tasks_nvim.fsio")
local ops = require("tasks_nvim.vault_ops")
local vault = require("tasks_nvim.vault")

local M = {}

---The one message every verb gives when no vault is set up.
M.NO_VAULT =
  "No task vault yet: create one with :TasksVault create <dir> (or set `vault` in tasks.nvim's setup(), or $TASKS_VAULT)"

---Seam for the clipboard (`nil`: lib.nvim's `cross.copy_to_clipboard`); specs replace it.
---@type (fun(text: string): boolean)|nil
M.copy = nil

---Seam for the area picker (`nil`: `vim.ui.select`); specs replace it.
---@type (fun(items: string[], opts: table, cb: fun(choice: string|nil)))|nil
M.select = nil

---@param text string
---@return boolean
local function copy(text)
  if M.copy then
    return M.copy(text)
  end
  return require("lib.nvim.cross.copy_to_clipboard")(text) and true or false
end

---The vault root, or the one "no vault" notice.
---@return string|nil root
local function vault_root()
  local root, err = vault.root()
  if root then
    return root
  end
  err = tostring(err or "")
  if err:find("vault not found", 1, true) then
    notify.warn(M.NO_VAULT)
  else
    -- a vault is named but the folder is gone
    notify.warn(err .. " -- :TasksVault create <dir> makes it")
  end
  return nil
end

---Report words after the arguments a verb does not take (the command line splits at spaces).
---@param ctx table
---@return boolean ok
local function no_stray_words(ctx)
  if ctx.rest and #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return false
  end
  return true
end

---Which area and part the typed words mean. `:TasksVault open features` is the part of the area of the
---buffer, `:TasksVault open lib features` area and part.
---@param root string
---@param first string|nil
---@param second string|nil
---@return string|nil area   nil: not given (ask the buffer, then the user)
---@return string|nil part
---@return string|nil err
local function split_words(root, first, second)
  local names = vault.area_names(root)
  if first and ops.is_part(first) and second == nil and not vim.tbl_contains(names, first) then
    return nil, first, nil
  end
  local area
  if first then
    local match, many = ops.match_area(names, first)
    if not match then
      if many then
        return nil, nil, ("'%s' fits several areas: %s"):format(first, table.concat(many, ", "))
      end
      return nil, nil, vault.not_an_area_message(first, names)
    end
    area = match
  end
  if second and not ops.is_part(second) then
    return nil,
      nil,
      ("unknown part '%s' (expected %s)"):format(second, table.concat(ops.PART_NAMES, "|"))
  end
  return area, second, nil
end

---Settle area and part, asking the buffer and then a picker when the area was not typed.
---@param ctx table
---@param root string
---@param cb fun(area: string, part: string, dir: string)
local function with_target(ctx, root, cb)
  local area, part, err = split_words(root, ctx.args.target, ctx.args.part)
  if err then
    notify.error(err)
    return
  end
  part = part or ops.DEFAULT_PART
  local function go(chosen)
    local dir, derr = ops.part_dir(root, chosen, part)
    if not dir then
      notify.error(derr or "no such part")
      return
    end
    cb(chosen, part, dir)
  end
  if area then
    return go(area)
  end
  area = ops.area_of_buffer(root)
  if area then
    return go(area)
  end
  local names = vault.area_names(root)
  if #names == 0 then
    notify.warn(
      "The vault has no area yet: :TasksVault create <dir> <area> or :Tasks new <area> <title>"
    )
    return
  end
  local select = M.select or vim.ui.select
  select(names, { prompt = "Area> " }, function(choice)
    if choice then
      go(choice)
    end
  end)
end

---The file or folder a path verb works on: the folder, or with `--file` the index file of the part.
---@param root string
---@param area string
---@param part string
---@param dir string
---@param ctx table
---@return string|nil path
local function subject(root, area, part, dir, ctx)
  if ctx.flags and ctx.flags.file then
    local entry = ops.part_entry(root, area, part)
    if not entry then
      notify.warn(("%s has no index file for %s"):format(area, part))
      return nil
    end
    return entry
  end
  if not fsio.is_dir(dir) then
    notify.warn(("%s has no %s folder yet (%s)"):format(area, part, dir))
    return nil
  end
  return dir
end

---The path as the verb writes it: absolute, or with `--rel` relative to the current file.
---@param path string
---@param ctx table
---@return string
local function shown(path, ctx)
  if ctx.flags and ctx.flags.rel then
    return ops.relative_to(vim.api.nvim_buf_get_name(0), path)
  end
  return fsio.norm(path)
end

---@param path string
local function open_file(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    notify.error(("cannot open %s: %s"):format(path, tostring(err)))
  end
end

---Put `text` into the current buffer at the cursor. A buffer that cannot take it gets the clipboard instead.
---@param text string
---@param what string
local function insert_at_cursor(text, what)
  local buf = vim.api.nvim_get_current_buf()
  local ok = vim.bo[buf].modifiable
    and vim.bo[buf].buftype ~= "terminal"
    and pcall(vim.api.nvim_put, { text }, "c", true, true)
  if ok then
    return
  end
  if copy(text) then
    notify.warn(("This buffer cannot take text; %s is in the + register instead"):format(what))
  else
    notify.error("This buffer cannot take text and the clipboard is not available")
  end
end

-- ── verbs ────────────────────────────────────────────────────────────────────

---`:TasksVault open [<area>] [<part>]`
---@param ctx table
function M.open(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    local entry = ops.part_entry(root, area, part)
    if entry then
      return open_file(entry)
    end
    if not fsio.is_dir(dir) then
      notify.warn(("%s has no %s folder yet (%s)"):format(area, part, dir))
      return
    end
    require("tasks_nvim.ui.cmd").open_explorer(dir)
  end)
end

---`:TasksVault clipboard [<area>] [<part>] [--rel] [--file]`
---@param ctx table
function M.clipboard(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    local path = subject(root, area, part, dir, ctx)
    if not path then
      return
    end
    local text = shown(path, ctx)
    if copy(text) then
      notify.info("Copied " .. text)
    else
      notify.error("Could not write to the clipboard")
    end
  end)
end

---`:TasksVault paste [<area>] [<part>] [--rel] [--file]`
---@param ctx table
function M.paste(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    local path = subject(root, area, part, dir, ctx)
    if not path then
      return
    end
    insert_at_cursor(shown(path, ctx), "the path")
  end)
end

---`:TasksVault link [<area>] [<part>]` -- `[lib.nvim backlog](../tasks-vault/lib.nvim/Backlog/README.md)`.
---@param ctx table
function M.link(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    local path = ops.part_entry(root, area, part) or (fsio.is_dir(dir) and dir or nil)
    if not path then
      notify.warn(("%s has no %s folder yet (%s)"):format(area, part, dir))
      return
    end
    local target = ops.relative_to(vim.api.nvim_buf_get_name(0), path)
    insert_at_cursor(ops.markdown_link(("%s %s"):format(area, part), target), "the link")
  end)
end

---The shared body of `find` and `grep`.
---@param ctx table
---@param action "files"|"grep"
local function pick(ctx, action)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    if not fsio.is_dir(dir) then
      notify.warn(("%s has no %s folder yet (%s)"):format(area, part, dir))
      return
    end
    local command, engine = require("tasks_nvim.ui.cmd").pickers_backend()
    if not command then
      notify.warn("pickers.nvim is not available: opening the folder in the explorer instead")
      require("tasks_nvim.ui.cmd").open_explorer(dir)
      return
    end
    command.dispatch(action, {
      roots = { dir },
      prompt = ("%s/%s> "):format(area, part),
    }, engine)
  end)
end

---`:TasksVault find [<area>] [<part>]`
---@param ctx table
function M.find(ctx)
  pick(ctx, "files")
end

---`:TasksVault grep [<area>] [<part>]`
---@param ctx table
function M.grep(ctx)
  pick(ctx, "grep")
end

---`:TasksVault tree [<area>] [<part>]`
---@param ctx table
function M.tree(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    if not fsio.is_dir(dir) then
      notify.warn(("%s has no %s folder yet (%s)"):format(area, part, dir))
      return
    end
    require("tasks_nvim.ui.cmd").open_explorer(dir)
  end)
end

---The prompt `cdx` copies.
---@param area string
---@param part string
---@param path string
---@return string
function M.cdx_prompt(area, part, path)
  return ("Read %s (the %s of %s) and continue the work listed there; summarise what is open before you change anything."):format(
    path,
    part,
    area
  )
end

---`:TasksVault cdx [<area>] [<part>] [--rel]`
---@param ctx table
function M.cdx(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  with_target(ctx, root, function(area, part, dir)
    local path = subject(root, area, part, dir, ctx)
    if not path then
      return
    end
    local text = M.cdx_prompt(area, part, shown(path, ctx))
    if copy(text) then
      notify.info("Copied a prompt for " .. area .. " " .. part)
    else
      notify.error("Could not write to the clipboard")
    end
  end)
end

---`:TasksVault new feature|task <title...> [--area=<area>]`
---@param ctx table
function M.new(ctx)
  local root = vault_root()
  if not root then
    return
  end
  local title = vim.trim(table.concat(ctx.rest or {}, " "))
  title = title:match('^"(.*)"$') or title
  if title == "" then
    notify.error(
      "a note needs a title: :TasksVault new " .. tostring(ctx.args.kind) .. " <title...>"
    )
    return
  end
  local given = ctx.flags and ctx.flags.area
  local function make(area)
    local res, err = ops.new_note(root, area, ctx.args.kind, title)
    if not res then
      notify.error(tostring(err))
      return
    end
    notify.info(("Created %s/Backlog/%s/%s"):format(area, res.bucket, res.file))
    open_file(res.path)
  end
  if given then
    local match, many = ops.match_area(vault.area_names(root), given)
    if not match then
      notify.error(
        many and ("'%s' fits several areas: %s"):format(given, table.concat(many, ", "))
          or vault.not_an_area_message(given, vault.area_names(root))
      )
      return
    end
    return make(match)
  end
  local area = ops.area_of_buffer(root)
  if area then
    return make(area)
  end
  local names = vault.area_names(root)
  if #names == 0 then
    notify.warn("The vault has no area yet: :TasksVault create <dir> <area>")
    return
  end
  local select = M.select or vim.ui.select
  select(names, { prompt = "Area> " }, function(choice)
    if choice then
      make(choice)
    end
  end)
end

---The setup line that keeps a vault.
---@param root string
---@return string
function M.setup_line(root)
  return ("vault = %q,"):format(root)
end

---What `create` is about to do and what is left to the user, in the order it happens. The last step is the one
---that is easy to forget and has no effect until it is done, so it is the one that is marked.
---@param root string
---@param areas string[]
---@return string
function M.create_plan(root, areas)
  return table.concat({
    "Create a task vault",
    "",
    "  1. Folder (name and location):",
    "       " .. root,
    "  2. Areas to make:  "
      .. (
        #areas > 0 and table.concat(areas, ", ") or "none yet (:Tasks new <area> <title> makes one)"
      ),
    "  3. In use for this session at once.",
    "",
    "  >>> 4. REQUIRED, and done by you afterwards <<<",
    "       Write the path into the setup of tasks.nvim:",
    "           " .. M.setup_line(root),
    "       (or set $TASKS_VAULT). Without this step nvim will NOT find",
    "       the vault again after a restart.",
  }, "\n")
end

---The message after the vault was made: the same required step, once more and impossible to miss.
---@param res { root: string, existed: boolean, created: string[] }
---@return string
function M.created_message(res)
  return table.concat({
    (res.existed and "Using the existing folder " or "Created the vault ") .. res.root,
    #res.created > 0 and ("made: " .. table.concat(res.created, ", ")) or "nothing new to make",
    "",
    "!! ONE STEP IS LEFT, AND IT IS YOURS !!",
    "Without it nvim does not find this vault after a restart:",
    "  add   " .. M.setup_line(res.root),
    "  to the setup (opts) of tasks.nvim, or set $TASKS_VAULT.",
    "The line is in the + register. Until then the vault is in use for this session only.",
  }, "\n")
end

---`:TasksVault create [<dir>] [<area>...] [--force] [--yes]`
---
---Says first what will happen and what is left to the user (confirmation; `--yes` skips it), makes the vault
---folder and the areas, and uses it for this session. What survives the session is the `vault` option of
---`setup()` (or `$TASKS_VAULT`): the plan names that step before and the result names it again.
---@param ctx table
function M.create(ctx)
  local current = vault.root()
  local force = ctx.flags and ctx.flags.force
  if current and not force then
    notify.warn(
      ("A vault is in use already (%s). :TasksVault create --force <dir> makes and uses another one"):format(
        current
      )
    )
    return
  end
  local areas = {}
  for _, name in ipairs(ctx.rest or {}) do
    areas[#areas + 1] = name
  end
  local function make(root)
    local res, err = ops.create_vault(root, areas)
    if not res then
      notify.error(tostring(err))
      return
    end
    vault.configure({ vault = res.root })
    copy(M.setup_line(res.root))
    notify.warn(M.created_message(res))
  end
  local function plan_and_make(dir)
    -- Checked before the question, so a refused folder is not first offered.
    local root = fsio.norm(vim.fn.fnamemodify(dir, ":p"))
    local confirm = require("tasks_nvim.ui.confirm")
    if ctx.flags and ctx.flags.yes then
      return make(dir)
    end
    confirm.yesno(M.create_plan(root, areas), "create it", function(accepted)
      if accepted then
        make(dir)
      end
    end)
  end
  local dir = ctx.args.dir
  if dir and dir ~= "" then
    return plan_and_make(dir)
  end
  vim.ui.input({
    prompt = "Vault folder (name and location): ",
    default = vim.fs.joinpath(vim.fn.expand("~"), "tasks-vault"),
    completion = "dir",
  }, function(input)
    if input and vim.trim(input) ~= "" then
      plan_and_make(vim.trim(input))
    end
  end)
end

---`:TasksVault` and `:TasksVault status`
---@param ctx table
function M.status(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local names = vault.area_names(root)
  notify.info(
    ("Vault: %s\n%d area%s%s\n:TasksVault open|clipboard|paste|link|find|grep|tree|cdx|new <area> [backlog|features|tasks|roadmap|all]"):format(
      root,
      #names,
      #names == 1 and "" or "s",
      ops.area_of_buffer(root) and (", this buffer: " .. ops.area_of_buffer(root)) or ""
    )
  )
end

return M
