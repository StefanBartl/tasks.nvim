---@module 'tasks_nvim.attach_source'
---@brief Where `attach` gets its file from when none is named: the clipboard image or the newest screenshot.
---@description
--- `attach <id> --clipboard` stores the image on the clipboard, `attach <id> --latest[=<folder>]` the newest
--- image of a screenshot folder that is at most `attach.max_age_s` seconds old (older: the caller is told
--- and asks, nothing is guessed). Both end in `mutate.attach`, so folder-task conversion, the asset name
--- rules and the index stay in one place. The platform access is `lib.nvim` (`clipboard_image`,
--- `fs.latest_file`); the tools are detected, not assumed.
---
--- Without `--name` the asset is called `<slug>-YYYY-MM-DD-HHMM.<ext>`; a name that is taken gets `-2`, `-3`,
--- ... -- an existing asset is never replaced. A name given by the caller is used as it is (taken: an error,
--- as in `mutate.attach`).

local mutate = require("tasks_nvim.mutate")

local M = {}

---@alias Tasks.AttachMode "clipboard"|"latest"

---@class Tasks.AttachSourceOpts
---@field root? string
---@field today? string
---@field name? string                       # Asset name; default `<slug>-<date>-<HHMM>.<ext>`.
---@field dir? string                        # `latest`: the folder to look into instead of the configured ones.
---@field dirs? string[]                     # `latest`: the folders (default: `attach.screenshot_dirs`, else the system's).
---@field max_age_s? number                  # `latest`: default `attach.max_age_s`.
---@field index? boolean
---@field now? number                        # Epoch seconds (specs).
---@field clipboard? Lib.ClipboardImage.Opts # Passed to `clipboard_image.save` (specs).

---The folders screenshots usually land in, per system.
---@param os_name? "windows"|"macos"|"linux"
---@param home? string
---@return string[]
function M.suggested_dirs(os_name, home)
  home = home or vim.uv.os_homedir() or "~"
  os_name = os_name
    or (
      require("lib.nvim.cross.platform.is_windows")() and "windows"
      or require("lib.nvim.cross.platform.is_macos")() and "macos"
      or "linux"
    )
  if os_name == "windows" then
    return {
      home .. "/Pictures/Screenshots",
      home .. "/OneDrive/Pictures/Screenshots",
      home .. "/Pictures",
    }
  elseif os_name == "macos" then
    return { home .. "/Desktop", home .. "/Pictures/Screenshots" }
  end
  return { home .. "/Pictures/Screenshots", home .. "/Pictures" }
end

---The folders `latest` looks into.
---@param opts? Tasks.AttachSourceOpts
---@return string[]
function M.screenshot_dirs(opts)
  if opts and opts.dir and opts.dir ~= "" then
    return { opts.dir }
  end
  if opts and opts.dirs and #opts.dirs > 0 then
    return opts.dirs
  end
  local configured = require("tasks_nvim.config").get().attach
  if configured and #configured.screenshot_dirs > 0 then
    return configured.screenshot_dirs
  end
  return M.suggested_dirs()
end

---`<slug>-YYYY-MM-DD-HHMM.<ext>`
---@param id string
---@param ext string
---@param now? number
---@return string
function M.default_name(id, ext, now)
  local slug = id:match("([^/]+)$") or id
  return ("%s-%s.%s"):format(slug, os.date("%Y-%m-%d-%H%M", now), ext)
end

---`name` with a counter before the extension: `a.png` -> `a-2.png`.
---@param name string
---@param n integer
---@return string
local function with_counter(name, n)
  local stem, ext = name:match("^(.*)(%.[%w]+)$")
  return ("%s-%d%s"):format(stem or name, n, ext or "")
end

---Attach the clipboard image or the newest screenshot to a task.
---@param id string                    # `<area>/<slug>`
---@param mode Tasks.AttachMode
---@param opts? Tasks.AttachSourceOpts
---@return table|nil result            # The result of `mutate.attach`, plus `source` (a description of where the file came from).
---@return string|nil err
---@return table|nil too_old           # `latest`: the newest file when it exists but is older than the limit (to ask about).
function M.attach(id, mode, opts)
  opts = opts or {}
  local ext = "png"
  local src, cleanup, source
  if mode == "clipboard" then
    local tmp = vim.fn.tempname() .. ".png"
    local saved, err = require("lib.nvim.clipboard_image").save(tmp, opts.clipboard)
    if not saved then
      return nil, err
    end
    src, source = tmp, "clipboard"
    cleanup = function()
      pcall(vim.uv.fs_unlink, tmp)
    end
  elseif mode == "latest" then
    local max_age = opts.max_age_s or require("tasks_nvim.config").get().attach.max_age_s
    local found, err, too_old = require("lib.nvim.fs.latest_file").find(
      M.screenshot_dirs(opts),
      { max_age_s = max_age, now = opts.now }
    )
    if not found then
      return nil, err, too_old
    end
    src, source = found.path, found.path
    ext = (found.path:match("%.([%w]+)$") or "png"):lower()
  else
    return nil, "attach source must be 'clipboard' or 'latest'"
  end

  local base = {
    root = opts.root,
    today = opts.today,
    index = opts.index,
  }
  local res, aerr
  if opts.name then
    res, aerr = mutate.attach(id, src, vim.tbl_extend("force", base, { name = opts.name }))
  else
    local name = M.default_name(id, ext, opts.now)
    for n = 1, 50 do
      local try = n == 1 and name or with_counter(name, n)
      res, aerr = mutate.attach(id, src, vim.tbl_extend("force", base, { name = try }))
      if res or not tostring(aerr):find("^asset exists:") then
        break
      end
    end
  end
  if cleanup then
    cleanup()
  end
  if res then
    res.source = source
  end
  return res, aerr
end

return M
