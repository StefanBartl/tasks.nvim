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

---@class Tasks.FsioScope
---@field owner thread|nil  # The coroutine that opened it (nil: the main one); anyone else gets the disk.
---@field stat table<string, table|false>
---@field lstat table<string, table|false>
---@field real table<string, string>
---@field memo table<string, any>

---The answers of the disk while a read scope is open (see `M.read_scope`); nil outside one.
---@type Tasks.FsioScope|nil
local scope = nil

---The open scope, when the code that asks is the code that opened it. A scope left open over a yield never serves
---another coroutine: it would answer from a state of the disk that is long gone.
---@return Tasks.FsioScope|nil
local function active()
  if scope and scope.owner == coroutine.running() then
    return scope
  end
  return nil
end

---Forget what the open scope knows: a write changes the disk under it.
local function drop_cache()
  local s = active()
  if s then
    s.stat, s.lstat, s.real, s.memo = {}, {}, {}, {}
  end
end

---Run `fn` with the answers of `stat`, `lstat` and `realpath` remembered: one build of the read view asks the same
---folder (an area, `ROADMAP`, the base of a ref) many times, and the vault does not change while it is read. The scope
---ends with `fn` (also when it raises), so the next request sees the disk again. A scope inside a scope shares the
---outer one. Meant for reads; a write of this module empties what the scope remembers, so a question after it is
---answered from the disk again.
---@param fn fun(): any, any?
---@return any
---@return any?
function M.read_scope(fn)
  if scope then
    -- inside (shared) or in a foreign coroutine (the disk answers there, see `active`)
    return fn()
  end
  scope = { owner = coroutine.running(), stat = {}, lstat = {}, real = {}, memo = {} }
  local ok, a, b = pcall(fn)
  scope = nil
  if not ok then
    error(a, 0)
  end
  return a, b
end

---A named value that lives as long as the open read scope (`compute` runs once per scope); without a scope it just
---runs `compute`.
---@generic T
---@param key string
---@param compute fun(): T
---@return T
function M.scope_memo(key, compute)
  local s = active()
  if not s then
    return compute()
  end
  local hit = s.memo[key]
  if hit == nil then
    hit = compute()
    s.memo[key] = hit
  end
  return hit
end

---Whether the error code of a failed `stat` is a final answer ("it is not there"), and not a hiccup (a busy file, no
---handles left, a denied folder) that the next question may not have.
---@param code string|nil
---@return boolean
local function is_absent(code)
  return code == "ENOENT" or code == "ENOTDIR"
end

---`uv.fs_stat`, answered once per read scope (a failure other than "not there" is not remembered).
---@param path string
---@return table|nil
function M.stat(path)
  local s = active()
  if not s then
    return uv.fs_stat(path)
  end
  local hit = s.stat[path]
  if hit == nil then
    local st, _, code = uv.fs_stat(path)
    if st then
      hit = st
    elseif is_absent(code) then
      hit = false
    else
      return nil
    end
    s.stat[path] = hit
  end
  return hit or nil
end

---`uv.fs_lstat`, answered once per read scope. Only what is there is remembered: a link guard that asked "is this a
---link?" must see a link that appears a moment later.
---@param path string
---@return table|nil
function M.lstat(path)
  local s = active()
  if not s then
    return uv.fs_lstat(path)
  end
  local hit = s.lstat[path]
  if hit == nil then
    hit = uv.fs_lstat(path)
    if hit then
      s.lstat[path] = hit
    end
  end
  return hit
end

---`uv.fs_realpath`, answered once per read scope. Only an answer is remembered, not a miss (the same reason as
---`lstat`; what repeats is the real path of the vault root).
---@param path string
---@return string|nil
function M.realpath(path)
  local s = active()
  if not s then
    return uv.fs_realpath(path)
  end
  local hit = s.real[path]
  if hit == nil then
    hit = uv.fs_realpath(path)
    if hit then
      s.real[path] = hit
    end
  end
  return hit
end

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
  local st = M.stat(path)
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
  local st = M.lstat(path)
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
  local st = M.stat(path)
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
  drop_cache()
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
---`is_exists`, not against the word: it is `lib.nvim.fs.create_exclusive`'s.
M.EXISTS = require("lib.nvim.fs.create_exclusive").EXISTS

---@type fun(err: any): boolean
M.is_exists = require("lib.nvim.fs.create_exclusive").is_exists

---Create `path` with `content`, failing with `"exists"` when the file is
---already there. The existence test and the creation are one syscall.
---@param path string
---@param content string
---@return boolean ok
---@return string|nil err  `"exists"` when the file was already present
function M.create_exclusive(path, content)
  drop_cache()
  return require("lib.nvim.fs.create_exclusive")(path, content)
end

---Run `fn` while holding an advisory lock on `path` (`lib.nvim.fs.with_lock`): a hidden `.<name>.lock` file next to
---it. Every tasks.nvim process that read-modify-writes the same file (the Backlog README, a task's frontmatter) goes
---through it, so two of them (an agent's CLI and the dashboard) never start from the same text and drop each other's
---change. What the open read scope knows is dropped once the lock is held: another writer may have changed the disk
---while this one waited.
---
---`info.code` says why a lock failed: `locked` (another process holds it right now; `retryable`), `lock_stuck` (a
---lock nobody will release; remove it by hand) or `io`. What `fn` answers (up to three values) is handed back.
---@generic R
---@param path string
---@param fn fun(): R, string|nil, table|nil
---@param opts? { wait_ms?: integer, stale_s?: integer }
---@return R|nil result
---@return string|nil err
---@return table|nil info
function M.with_lock(path, fn, opts)
  return require("lib.nvim.fs.with_lock")(path, function()
    drop_cache()
    return fn()
  end, opts)
end

---The SHA-256 of some bytes, 64 hex digits (`lib.nvim.fs.etag`: a text with a NUL byte is hashed with the NUL
---replaced, still a function of the bytes).
---@type fun(text: string): string
M.sha256 = require("lib.nvim.fs.etag").sha256

---The version tag of some bytes: `sha256:` and the first 16 hex digits of their SHA-256.
---@type fun(text: string): string
M.etag = require("lib.nvim.fs.etag").of

---Rename a file or folder (one filesystem, so atomic). The target must not exist.
---Goes through `lib.nvim.cross.fs.mutate`, which retries a Windows sharing violation (an
---indexer or virus scanner holding a handle on a freshly written asset for a moment) instead
---of failing a whole `done` over it.
---@param from string
---@param to string
---@return boolean ok
---@return string|nil err
function M.rename(from, to)
  drop_cache()
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
  drop_cache()
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
  drop_cache()
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
  drop_cache()
  local ok, err = mutate.delete_file(path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

return M
