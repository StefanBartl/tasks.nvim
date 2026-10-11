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
---  - I/O failures are answers (`value|nil, err` or `ok, err`), never raised; the path helpers expect strings
---    (`norm(nil)` raises: the callers validate their input first)
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

---Whether two paths name the same file: normalised, and case-insensitive where the file system is (Windows).
---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  a, b = M.norm(a), M.norm(b)
  if require("lib.nvim.cross.platform.is_windows")() then
    return a:lower() == b:lower()
  end
  return a == b
end

---Whether `path` is itself a symbolic link or a junction (not what it points to).
---@param path string
---@return boolean
function M.is_link(path)
  local st = uv.fs_lstat(path)
  return st ~= nil and st.type == "link"
end

---Whether `child` is `parent` or lies below it (a text test on normalised paths, case-insensitive on Windows): it does
---not look at the disk, so resolve links first (`uv.fs_realpath`) when the question is where a file really is.
---@param parent string
---@param child string
---@return boolean
function M.is_inside(parent, child)
  parent, child = M.norm(parent), M.norm(child)
  if require("lib.nvim.cross.platform.is_windows")() then
    parent, child = parent:lower(), child:lower()
  end
  if child == parent then
    return true
  end
  local prefix = parent:sub(-1) == "/" and parent or (parent .. "/")
  return child:sub(1, #prefix) == prefix
end

---@param path string
---@return boolean
function M.is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

---Largest file `read` will load. A task file, an index or a Backlog README is a few KB (the biggest real
---one in the author's vault is ~120 KB); anything past this is not what it claims to be, and reading it
---whole would stall the editor on every scan (a data dump saved as `x.md`) or never return (a FIFO or a
---`/dev/zero` symlink named `x.md` on POSIX).
M.MAX_READ_BYTES = 2 * 1024 * 1024

---Read a regular file of at most `MAX_READ_BYTES`; anything else is `nil, err`.
---@param path string
---@return string|nil content
---@return string|nil err
function M.read(path)
  local st = uv.fs_stat(path)
  if st and st.type ~= "file" then
    return nil, ("not a regular file (%s): %s"):format(st.type, path)
  end
  if st and st.size > M.MAX_READ_BYTES then
    return nil, ("file is larger than %d bytes (%d): %s"):format(M.MAX_READ_BYTES, st.size, path)
  end
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

---`s` without leading and trailing whitespace, in linear time (the lib.nvim implementation; the usual
---`s:match("^%s*(.-)%s*$")` backtracks over a whitespace run and cost seconds on a 40 000-space line, SEC-32).
---Non-string input trims to `""`.
---@type fun(s: any): string
M.trim = require("lib.lua.strings.core").trim

---Double every run of backslashes that sits directly in front of a character matching `set` (a Lua
---pattern anchored by the caller, e.g. `"^[|]"`), and, with `at_end`, a run at the very end of `s`.
---Used before escaping that character with one more backslash: the escape would otherwise merge with
---the run (`\|` is an escaped pipe, `\\|` an escaped backslash and a live pipe in GFM).
---
---Linear in the length of `s`. The one-liner `s:gsub("(\\*)|", ...)` retries a long backslash run from
---every start position, so a title of 20 000 backslashes cost seconds on every index render (SEC-32).
---@param s string
---@param set string
---@param at_end? boolean
---@return string
function M.double_runs(s, set, at_end)
  local out, i, len = {}, 1, #s
  while i <= len do
    local j = s:find("\\", i, true)
    if not j then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, j - 1)
    local k = j
    while s:byte(k + 1) == 92 do
      k = k + 1
    end
    local run = s:sub(j, k)
    local nxt = s:sub(k + 1, k + 1)
    if (nxt ~= "" and nxt:find(set)) or (at_end and k == len) then
      out[#out + 1] = run .. run
    else
      out[#out + 1] = run
    end
    i = k + 1
  end
  return table.concat(out)
end

---One Markdown table cell: line breaks become spaces, terminal control characters go, and every `|` is
---escaped so it cannot split the cell (a backslash run in front of it is doubled first).
---@param s string
---@return string
function M.md_cell(s)
  local flat = M.clean((s:gsub("[\r\n]+", " ")))
  return (M.double_runs(flat, "^|"):gsub("|", "\\|"))
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

---Write `content` to `path` through a temp sibling and a rename, creating the parent directory. Bytes are
---written as given (no newline is appended). The work is `lib.nvim.fs.write.atomic`: flushed before the rename
---(a crash leaves the old or the new content, never an empty file) and taking over the mode of the file it replaces.
---
---A symlink at `path` is REPLACED by the new regular file (the safe default for files the vault owns: a link planted in
---a vault must not redirect a write outside it). `opts.follow_symlinks` writes through the link instead: for a document
---the USER named (`--write=<file>`, `chain.marker_docs`), which may well be a symlink to the original.
---@param path string
---@param content string
---@param opts? { follow_symlinks?: boolean }
---@return boolean ok
---@return string|nil err
function M.write_atomic(path, content, opts)
  local target = path
  if opts and opts.follow_symlinks then
    target = (vim.uv or vim.loop).fs_realpath(path) or path
  end
  return require("lib.nvim.fs.write.atomic")(target, content, { mkdirp = true, tag = "tasks-tmp" })
end

---A path the user typed (`--write=`, an entry of `chain.marker_docs`) as an absolute, forward-slash path: `~`, `$VAR`
---and `%VAR%` are expanded (`lib.nvim.cross.fs.expand_path`), nothing else. `vim.fn.expand` would read `[1]` in
---`plan[1].md` as a wildcard and select another file, run a backtick span through the shell, and join several matches.
---@param path string
---@return string
function M.doc_path(path)
  local expanded = require("lib.nvim.cross.fs.expand_path")(path)
  return M.norm(vim.fn.fnamemodify(expanded, ":p"))
end

---The error `create_exclusive` and `copy` answer when the target was already there. Compare through
---`is_exists`, not against the word: the word is an implementation detail of this module.
M.EXISTS = "exists"

---@param err any
---@return boolean
function M.is_exists(err)
  return err == M.EXISTS
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
      return false, M.EXISTS
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

---Run `fn` while holding an advisory lock on `path`: a hidden `.<name>.lock` file next to it, created exclusively. Every
---tasks.nvim process that read-modify-writes the same file (the Backlog README, a task's frontmatter) goes through it,
---so two of them (an agent's CLI and the dashboard) never start from the same text and drop each other's change. It
---serialises the cooperating writers only; an editor with the file open is not one of them.
---
---A holder that died leaves its file behind: a lock older than `opts.stale_s` (10 s; a locked write takes
---milliseconds) is taken over. Waiting is bounded (`opts.wait_ms`, 2 s), then `nil, err, info`.
---
---`info.code` says why: `locked` (another process holds it right now; asking again can help, `retryable`),
---`lock_stuck` (a lock that nobody will release: older than the takeover age and not deletable, or a folder or link
---where the lock file should be; remove it by hand) or `io`. What `fn` answers (up to three values) is handed back.
---@generic R
---@param path string
---@param fn fun(): R, string|nil, table|nil
---@param opts? { wait_ms?: integer, stale_s?: integer }
---@return R|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "locked"|"lock_stuck"|"io", retryable = boolean, lock = string }` for a failed lock, else what `fn` gave
function M.with_lock(path, fn, opts)
  opts = opts or {}
  local lock = M.dirname(path) .. "/." .. path:match("([^/\\]+)$") .. ".lock"
  local deadline = uv.hrtime() + (opts.wait_ms or 2000) * 1000000
  local stale_s = opts.stale_s or 10
  while true do
    local ok, err = M.create_exclusive(lock, tostring(uv.os_getpid()))
    if ok then
      break
    end
    -- Contention is not only "exists": on Windows a lock that was unlinked a moment ago answers EPERM / EACCES /
    -- EBUSY to a create until the delete completes. Any other error is real.
    local exists = M.is_exists(err)
    local transient = exists
      or (
        type(err) == "string"
        and (
          err:find("EPERM", 1, true)
          or err:find("EACCES", 1, true)
          or err:find("EBUSY", 1, true)
        )
      )
    if not transient then
      return nil,
        ("cannot lock %s: %s"):format(path, tostring(err)),
        { code = "io", retryable = false, lock = lock }
    end
    local stuck = ("%s has a lock that cannot be taken over: remove it by hand (%s)"):format(
      path,
      lock
    )
    if exists then
      local st = uv.fs_lstat(lock)
      -- a folder or a link where the lock file should be (a checked-in `.<name>.lock/`): nobody will ever release it
      if st and st.type ~= "file" then
        return nil, stuck, { code = "lock_stuck", retryable = false, lock = lock }
      end
      if st and os.time() - st.mtime.sec > stale_s then
        pcall(uv.fs_unlink, lock)
      end
    end
    -- the deadline applies on EVERY turn: a stale lock that cannot be deleted must not spin the editor
    if uv.hrtime() > deadline then
      local st = uv.fs_lstat(lock)
      if st and os.time() - st.mtime.sec > stale_s then
        -- older than the takeover age and still there: deleting it failed, and waiting longer will not change that
        return nil, stuck, { code = "lock_stuck", retryable = false, lock = lock }
      end
      return nil,
        ("%s is being written by another process (%s: %s)"):format(path, lock, tostring(err)),
        { code = "locked", retryable = true, lock = lock }
    end
    vim.wait(10)
  end
  local ran, res, res2, res3 = pcall(fn)
  pcall(uv.fs_unlink, lock)
  if not ran then
    error(res, 0)
  end
  return res, res2, res3
end

---The SHA-256 of some bytes, 64 hex digits. `vim.fn.sha256` refuses a string with a NUL byte (a Blob), so such a text
---is hashed with each NUL replaced by two other bytes: still a function of the bytes, which is all a version tag and
---a content digest have to be.
---@param text string
---@return string
function M.sha256(text)
  if text:find("%z") then
    text = text:gsub("%z", "\255\254")
  end
  return vim.fn.sha256(text)
end

---The version tag of some bytes: `sha256:` and the first 16 hex digits of their SHA-256.
---@param text string
---@return string
function M.etag(text)
  return "sha256:" .. M.sha256(text):sub(1, 16)
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
      return false, M.EXISTS
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
