---@module 'tasks_nvim.fsio'
---@brief Small byte-exact file primitives the task engine builds on.
---@description
--- Thin layer over `lib.nvim.fs.*` / `lib.nvim.cross.fs.mutate` for the few
--- things the engine needs that no single lib.nvim function does:
---
---  - `write_atomic`: temp sibling + rename, no newline appended (the lib's
---    `fs.write.to_file` appends one, which would change a file that was
---    deliberately written without it);
---  - `create_exclusive`: `O_CREAT|O_EXCL`, so two writers can never both
---    believe they created the same task file (ERR-31);
---  - line-ending helpers, because a vault checked out with CRLF must keep
---    reading and comparing as if it were LF.
---
--- Key responsibilities:
---  - forward-slash paths everywhere the engine hands one out
---  - never raise: every function answers `value|nil, err` or `ok, err`
---
--- Not its job: deciding what to write or where (that is `mutate`/`index`).

local read_file = require("lib.nvim.fs.read")
local mkdirp = require("lib.nvim.fs.mkdirp")
local mutate = require("lib.nvim.cross.fs.mutate")
local unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes")

local uv = vim.uv or vim.loop

local M = {}

---Forward slashes, no trailing slash (a bare drive root `C:/` or `/` is kept).
---@param path string
---@return string
function M.norm(path)
  local p = unify_slashes(path)
  if #p > 1 and p:sub(-1) == "/" and not p:match("^%a:/$") then
    p = p:sub(1, -2)
  end
  return p
end

---@param path string
---@return string
function M.dirname(path)
  return (M.norm(path):match("^(.*)/[^/]*$")) or "."
end

---@param path string
---@return boolean
function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param path string
---@return boolean
function M.is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

---@param path string
---@return string|nil content
---@return string|nil err
function M.read(path)
  return read_file(path)
end

---`\r\n` -> `\n`, so a CRLF checkout compares equal to the generated LF text.
---@param s string
---@return string
function M.lf(s)
  return (s:gsub("\r\n", "\n"))
end

---The line ending a text uses: CRLF when it contains one, else LF.
---@param s string
---@return string
function M.eol_of(s)
  return s:find("\r\n", 1, true) and "\r\n" or "\n"
end

---Text that is safe to print: every control character (C0, DEL, and the C1
---range in its UTF-8 form, which xterm-like terminals also act on) becomes a
---space. A title, a ref or a file name is data from a file; an ESC in it would
---otherwise reach the terminal (`list`, `check`) or the generated index as an
---escape sequence (window title, OSC 52 clipboard write, cursor games).
---@param s string
---@return string
function M.clean(s)
  return (s:gsub("%c", " "):gsub("\194[\128-\159]", " "))
end

---`s` without leading and trailing whitespace, in linear time. The usual
---`s:match("^%s*(.-)%s*$")` retries the rest of a whitespace run from every
---byte inside it, so one line with 40 000 spaces costs seconds (SEC-32); this
---one walks the trailing run once.
---@param s string
---@return string
function M.trim(s)
  local first = s:find("%S")
  if not first then
    return ""
  end
  local last = #s
  while last > first and s:find("^%s", last) do
    last = last - 1
  end
  return s:sub(first, last)
end

---@param path string
---@param err? string
---@return boolean ok
---@return string|nil err
local function ensure_parent(path, err)
  local ok, merr = mkdirp(M.dirname(path))
  if not ok then
    return false, err or merr
  end
  return true, nil
end

---Write `content` to `path` through a temp sibling and a rename, creating the
---parent directory. Bytes are written as given (no newline is appended).
---
---The temp file is flushed to disk before the rename (a crash then leaves the old
---or the new content, never an empty file under the new name) and takes over the
---mode of the file it replaces (a private `0600` file does not become `0644`).
---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
function M.write_atomic(path, content)
  local ok, perr = ensure_parent(path)
  if not ok then
    return false, perr
  end
  -- Unique per process and call, so concurrent writers never share a temp file.
  local tmp = ("%s.tasks-tmp.%d.%d"):format(path, uv.os_getpid(), uv.hrtime())
  local fd, open_err = uv.fs_open(tmp, "wx", 420) -- 0644, less the umask
  if not fd then
    return false, "open failed: " .. tostring(open_err or tmp)
  end
  local wrote, write_err = uv.fs_write(fd, content, 0)
  if wrote then
    local old = uv.fs_stat(path)
    if old then
      pcall(uv.fs_fchmod, fd, old.mode % 4096)
    end
    -- Best effort: a file system that cannot sync (some network shares) still gets its bytes.
    pcall(uv.fs_fsync, fd)
  end
  local closed, close_err = uv.fs_close(fd)
  if not wrote or wrote ~= #content or not closed then
    pcall(os.remove, tmp)
    return false, "write failed: " .. tostring(write_err or close_err or tmp)
  end
  local renamed, rename_err = mutate.rename_file(tmp, path)
  if not renamed then
    pcall(os.remove, tmp)
    return false, "rename failed: " .. tostring(rename_err)
  end
  return true, nil
end

---Create `path` with `content`, failing with `"exists"` when the file is
---already there. The existence test and the creation are one syscall.
---@param path string
---@param content string
---@return boolean ok
---@return string|nil err  `"exists"` when the file was already present
function M.create_exclusive(path, content)
  local ok, perr = ensure_parent(path)
  if not ok then
    return false, perr
  end
  local fd, open_err = uv.fs_open(path, "wx", 420) -- 0644
  if not fd then
    if tostring(open_err):match("^EEXIST") then
      return false, "exists"
    end
    return false, "open failed: " .. tostring(open_err)
  end
  local written, write_err = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  if not written or written ~= #content then
    pcall(os.remove, path)
    return false, "write failed: " .. tostring(write_err or path)
  end
  return true, nil
end

---Rename a file or folder (one filesystem, so atomic). The target must not exist.
---Goes through `lib.nvim.cross.fs.mutate`, which retries a Windows sharing violation (an
---indexer or virus scanner holding a handle on a freshly written asset for a moment) instead
---of failing a whole `done` over it.
---@param from string
---@param to string
---@return boolean ok
---@return string|nil err
function M.rename(from, to)
  if uv.fs_stat(to) then
    return false, "target exists: " .. to
  end
  local ok, err = mutate.rename_file(from, to)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---Copy a file, failing when the target exists. Creates the parent folder.
---@param from string
---@param to string
---@return boolean ok
---@return string|nil err  `"exists"` when the target was already there
function M.copy(from, to)
  local ok, perr = ensure_parent(to)
  if not ok then
    return false, perr
  end
  local copied, err = uv.fs_copyfile(from, to, { excl = true })
  if not copied then
    if tostring(err):match("^EEXIST") then
      return false, "exists"
    end
    return false, tostring(err)
  end
  return true, nil
end

---Create a folder and its parents.
---@param path string
---@return boolean ok
---@return string|nil err
function M.mkdirp(path)
  local ok, err = mkdirp(path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.remove(path)
  local ok, err = mutate.delete_file(path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

return M
