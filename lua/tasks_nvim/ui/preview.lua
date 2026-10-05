---@module 'tasks_nvim.ui.preview'
---@brief Show a task file, or a task-list export, in the browser through mdview.nvim.
---@description
--- The thin wire between the task system and `mdview.nvim`: a task file is
--- opened as it is (live preview, edits show up), an export is first written
--- to a temporary Markdown file (the relay previews files, not strings) and
--- opened the same way. mdview.nvim is a soft dependency -- nothing here
--- `require`s it at load time, and a missing plugin ends in one clear message
--- instead of a stack trace or a leftover temp file.
---
--- Key responsibilities:
---  - `open_file`: preview an existing file
---  - `open_text`: write text to a fresh temp file, preview it, delete the file
---    again when its buffer goes away (or Neovim exits)
---  - the seams `M.probe` (is mdview there?), `M.opener` (open + start the
---    preview) and `M.temp_root` (where temp files go), so the specs run
---    without a browser
---
--- The vault is never written: a temp file is refused inside it. Deleting a
--- temp file retries a few times (Windows keeps a file busy for a moment after
--- its buffer is gone); what still lingers sits in Neovim's own per-session temp
--- directory, which Neovim removes on exit.
---
--- Not its job: rendering the task list (`tasks_view`), parsing `--to=`
--- (`tasks_view`), the `task preview` command (`tasks_cmd`).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

local uv = vim.uv or vim.loop

local is_windows = require("lib.nvim.cross.platform.is_windows")()

---Delete retries and their spacing (ms), for a file Windows still holds.
local REMOVE_RETRIES = 4
local REMOVE_DELAY_MS = 250

---How many `-2`, `-3`, ... suffixes a name collision may try.
local MAX_NAME_TRIES = 99

---@type table<string, true>  # Temp files this module made and has not deleted yet.
local temp_files = {}

---@type integer|nil
local group

-- ── seams ────────────────────────────────────────────────────────────────────

---Is mdview.nvim usable? `nil` (the default) checks for the `:MDView` command
---(a lazy-loaded plugin has a stub) and then for the module. Assign a function
---returning `ok, err` to replace it.
---@type (fun(): boolean, string|nil)|nil
M.probe = nil

---Open `path` and start the preview. `nil` (the default) is `:edit` plus
---`:MDView start`. Assign a function returning `ok, err` to replace it.
---@type (fun(path: string): boolean, string|nil)|nil
M.opener = nil

---Directory for temp files. `nil` (the default) is Neovim's per-session temp
---directory. Assign a function returning a path to replace it.
---@type (fun(): string)|nil
M.temp_root = nil

-- ── availability ─────────────────────────────────────────────────────────────

local MISSING = "mdview.nvim is not available (no :MDView command); install it or use --to=buffer"

---@return boolean ok
---@return string|nil err
local function default_probe()
  if vim.fn.exists(":MDView") == 2 then
    return true, nil
  end
  if pcall(require, "mdview") and vim.fn.exists(":MDView") == 2 then
    return true, nil
  end
  return false, MISSING
end

---Is the preview possible right now?
---@return boolean ok
---@return string|nil err
function M.available()
  local probe = M.probe or default_probe
  local ok, res, err = pcall(probe)
  if not ok then
    return false, tostring(res)
  end
  if not res then
    return false, err or MISSING
  end
  return true, nil
end

-- ── opening ──────────────────────────────────────────────────────────────────

---`:edit` the file, then start (or retarget) the mdview session on it.
---@param path string
---@return boolean ok
---@return string|nil err
local function default_opener(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    return false, tostring(err)
  end
  -- The path travels as ONE argument (table form). `fnameescape` is right for `:edit`, but a user
  -- command splits its tail with `<f-args>`, which keeps the backslash `fnameescape` put before a
  -- `#`, `%` or `'` -- `:MDView start` would then be handed `C:/Users/O\'Neil/...`.
  ok, err = pcall(vim.cmd, { cmd = "MDView", args = { "start", path } })
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

local same_path = fsio.same_path

---@param path string
---@return integer|nil buf
local function find_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if same_path(vim.api.nvim_buf_get_name(buf), path) then
      return buf
    end
  end
  return nil
end

---Preview an existing Markdown file: opened as a buffer (so edits are live)
---and handed to mdview.
---@param path string
---@return boolean ok
---@return string|nil err
function M.open_file(path)
  if type(path) ~= "string" or path == "" then
    return false, "no file to preview"
  end
  local p = fsio.norm(path)
  if not fsio.is_file(p) then
    return false, "no such file: " .. p
  end
  local avail, aerr = M.available()
  if not avail then
    return false, aerr
  end
  local ok, res, err = pcall(M.opener or default_opener, p)
  if not ok then
    return false, tostring(res)
  end
  if not res then
    return false, err or "mdview could not open the preview"
  end
  return true, nil
end

-- ── temp files ───────────────────────────────────────────────────────────────

---A file-name-safe word for a label: ASCII letters, digits, `.`, `_`, `-`.
---@param label string|nil
---@return string
function M.slug(label)
  local s = tostring(label or ""):gsub("[^%w%._%-]+", "-"):gsub("^[%-%.]+", ""):gsub("[%-%.]+$", "")
  s = s:sub(1, 40)
  if s == "" then
    return "export"
  end
  return s
end

---Is `path` the folder `root` or below it? Case-insensitive on Windows (`E:/Repos` is `e:/repos`).
---@param path string
---@param root string
---@return boolean
local function inside(path, root)
  if is_windows then
    path, root = path:lower(), root:lower()
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

---@return string dir
local function root_dir()
  if M.temp_root then
    return fsio.norm(M.temp_root())
  end
  -- `tempname()` lives in Neovim's per-session directory, which Neovim deletes on exit.
  return fsio.norm(vim.fs.dirname(vim.fn.tempname()))
end

---Delete a temp file, retrying while Windows holds it. Idempotent.
---@param path string
---@param tries? integer  # Attempts left (default `REMOVE_RETRIES`).
function M.forget(path, tries)
  if not temp_files[path] then
    return
  end
  tries = tries or REMOVE_RETRIES
  if not uv.fs_stat(path) then
    temp_files[path] = nil
    return
  end
  local ok = fsio.remove(path)
  if ok then
    temp_files[path] = nil
    return
  end
  if tries > 1 then
    vim.defer_fn(function()
      M.forget(path, tries - 1)
    end, REMOVE_DELAY_MS)
  end
end

---Delete every temp file still tracked (Neovim is quitting: one attempt each).
function M.cleanup_all()
  for path in pairs(vim.deepcopy(temp_files)) do
    pcall(fsio.remove, path)
    temp_files[path] = nil
  end
end

---Temp files made and not yet deleted (for the specs).
---@return string[]
function M.pending()
  local out = {}
  for path in pairs(temp_files) do
    out[#out + 1] = path
  end
  table.sort(out)
  return out
end

local function ensure_group()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("TasksPreviewTemp", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cleanup_all()
    end,
  })
end

---Create `<root>/tasks-<slug>[-n].md` holding `text`; never overwrites a file.
---@param text string
---@param label string|nil
---@return string|nil path
---@return string|nil err
function M.write_temp(text, label)
  local dir = root_dir()
  local vroot = vault.root()
  if vroot and inside(dir, fsio.norm(vroot)) then
    return nil, "refusing to write a preview file inside the vault: " .. dir
  end
  local mk_ok, mk_err = fsio.mkdirp(dir)
  if not mk_ok then
    return nil, "cannot create " .. dir .. ": " .. tostring(mk_err)
  end
  local base = "tasks-" .. M.slug(label)
  for n = 1, MAX_NAME_TRIES do
    local path = ("%s/%s%s.md"):format(dir, base, n == 1 and "" or ("-" .. n))
    local ok, err = fsio.create_exclusive(path, text)
    if ok then
      ensure_group()
      temp_files[path] = true
      return path, nil
    end
    if not fsio.is_exists(err) then
      return nil, "cannot write " .. path .. ": " .. tostring(err)
    end
  end
  return nil, "no free file name for " .. base
end

---Preview text: write it to a temp file, open it, and delete the file when its
---buffer is deleted. Checks that mdview is there first, so nothing is written
---when it is not.
---@param text string  Markdown
---@param label string|nil  Part of the file name (the area, for an export).
---@return boolean ok
---@return string|nil err
---@return string|nil path  The temp file.
function M.open_text(text, label)
  local avail, aerr = M.available()
  if not avail then
    return false, aerr, nil
  end
  local path, werr = M.write_temp(text, label)
  if not path then
    return false, werr, nil
  end
  local ok, err = M.open_file(path)
  if not ok then
    M.forget(path)
    return false, err, nil
  end
  local buf = find_buf(path)
  if buf then
    -- A name that comes back (the first file went away with its buffer, the next export took its
    -- name again) is the SAME buffer: what the earlier open left on it must go first, or its
    -- handlers would delete this new file -- the `buflisted` line below fires `BufDelete` itself.
    vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
    -- A scratch-like file: keep it out of the buffer list and clean up with it. `BufDelete` alone
    -- would not do: it never fires for an unlisted buffer, so a plain `:bdelete` (or closing the
    -- window of a buffer that is not hidden) left the file until Neovim quit.
    vim.bo[buf].buflisted = false
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        M.forget(path)
      end,
    })
    -- `BufUnload` is where every other way of dropping the buffer's text ends up -- but `:edit!`
    -- (a reload) fires it too, so look again once the command is over: gone, the file goes.
    vim.api.nvim_create_autocmd("BufUnload", {
      group = group,
      buffer = buf,
      callback = function()
        vim.schedule(function()
          if not vim.api.nvim_buf_is_loaded(buf) then
            M.forget(path)
          end
        end)
      end,
    })
  end
  return true, nil, path
end

return M
