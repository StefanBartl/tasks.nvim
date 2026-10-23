-- TESTS/tasks_resolve_spec.lua -- tasks.resolve: a task id in any text, resolved to where the task is.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local resolve = require("tasks_nvim.resolve")

  local root = F.vault(H)
  local alpha = F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha title", "open"))
  local finished = root .. "/lib.nvim/Backlog/TASKS/2026-10-01_old-one.md"
  H.write(finished, F.text(F.meta("Old one", "done")))
  -- reopened: the same slug open and finished
  F.task(H, root, "cascade.nvim", "twice", F.meta("Twice open", "open"))
  H.write(
    root .. "/cascade.nvim/Backlog/FEATURES/2026-09-01_twice.md",
    F.text(F.meta("Twice done", "done"))
  )

  local function token(line, col)
    local t, s, e = resolve.token_at(line, col)
    return { t, s, e }
  end

  -- ── token_at: what in a line is an id ──────────────────────────────────
  eq(token("see lib.nvim/alpha here", 6), { "lib.nvim/alpha", 5, 18 }, "an id anywhere in it")
  eq(token("see lib.nvim/alpha here", 18), { "lib.nvim/alpha", 5, 18 }, "on its last character")
  eq(token("see lib.nvim/alpha here", 3), {}, "not on the word before it")
  eq(
    token("blocked by lib.nvim/alpha.", 15),
    { "lib.nvim/alpha", 12, 25 },
    "the full stop of a sentence is no part"
  )
  eq(token("- [ ] `lib.nvim/alpha` next", 10), { "lib.nvim/alpha", 8, 21 }, "inside backticks")
  eq(
    token("[[lib.nvim/alpha|Alpha]]", 5),
    { "lib.nvim/alpha", 3, 16 },
    "inside a wikilink with an alias"
  )
  eq(token("open lua/gopath/init.lua", 8), {}, "a path with a second slash is a path")
  eq(token("open /lib.nvim/alpha", 8), {}, "a leading slash is an absolute path")
  eq(token("see Lib/Not_A_Slug", 6), {}, "a slug that is not kebab-case")
  eq(token("plain words only", 3), {}, "no slash at all")
  eq(token("", 1), {}, "an empty line")

  -- ── resolve: where the task is ─────────────────────────────────────────
  local t = resolve.resolve("lib.nvim/alpha", { roots = { root } })
  eq(#t, 1, "one open task")
  eq(t[1].kind, "task")
  eq(t[1].id, "lib.nvim/alpha")
  eq(t[1].path, alpha)
  eq(t[1].line, 1)
  eq(t[1].title, "Alpha title")
  eq(t[1].root, root)

  local d = resolve.resolve("lib.nvim/old-one", { roots = { root } })
  eq(#d, 1, "a finished task")
  eq(d[1].kind, "done")
  eq(d[1].title, "Old one")
  eq(d[1].path, finished)

  local both = resolve.resolve("cascade.nvim/twice", { roots = { root } })
  eq(#both, 2, "open and finished are both targets")
  eq({ both[1].kind, both[2].kind }, { "task", "done" }, "the open one first")

  eq(
    resolve.resolve("[[lib.nvim/alpha|Alpha]]", { roots = { root } })[1].id,
    "lib.nvim/alpha",
    "a wikilink"
  )
  eq(
    resolve.resolve("lib.nvim/nothing-here", { roots = { root } }),
    {},
    "an unknown slug: empty, no error"
  )
  eq(resolve.resolve("lua/gopath", { roots = { root } }), {}, "an area the vault does not have")
  eq(
    resolve.resolve("LIB.NVIM/alpha", { roots = { root } }),
    {},
    "an area in another case is not that area"
  )
  eq(resolve.resolve("not an id", { roots = { root } }), {}, "not an id at all")
  eq(resolve.resolve(nil), {}, "nil")

  -- several vaults: every target, vault by vault
  local other = H.tmpdir() .. "/other"
  F.task(H, other, "lib.nvim", "alpha", F.meta("Alpha elsewhere", "open"))
  local two = resolve.resolve("lib.nvim/alpha", { roots = { root, other } })
  eq(#two, 2, "the same id in two vaults")
  eq(
    { two[1].title, two[2].title },
    { "Alpha title", "Alpha elsewhere" },
    "in the order the vaults were given"
  )

  -- without roots: the configured vault
  local vault = require("tasks_nvim.vault")
  vault.set_root(root)
  eq(#resolve.resolve("lib.nvim/alpha"), 1, "the configured vault")
  vault.set_root(nil)

  -- ── resolve_at: from a buffer position ─────────────────────────────────
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "todo: lib.nvim/alpha, then more" })
  local at, tok = resolve.resolve_at(buf, 2, 8, { roots = { root } })
  eq(tok, "lib.nvim/alpha", "the token under a 0-based column")
  eq(#at, 1)
  eq(at[1].path, alpha)
  local none, no_tok = resolve.resolve_at(buf, 1, 2, { roots = { root } })
  eq(none, {}, "a line without an id")
  eq(no_tok, nil)
  vim.api.nvim_buf_delete(buf, { force = true })

  ok(require("tasks_nvim").resolve == resolve, "reachable as require('tasks_nvim').resolve")

  -- ── found in review ────────────────────────────────────────────────────
  eq(
    token("in _lib.nvim/alpha_ emphasis", 6),
    { "lib.nvim/alpha", 5, 18 },
    "Markdown `_` emphasis is no part"
  )
  eq(token("in _lib.nvim/alpha_ emphasis", 4), {}, "and the `_` itself is no id")

  eq(
    #resolve.resolve("lib.nvim/alpha", { roots = { root, root } }),
    1,
    "one vault named twice answers once"
  )
  eq(
    #resolve.resolve("lib.nvim/alpha", { roots = { root, (root:gsub("/", "\\")) } }),
    1,
    "and so does the same vault in another spelling"
  )

  -- a folder that is no area (`TOOLS` never is) with a Backlog-shaped file in it
  H.write(root .. "/TOOLS/Backlog/TASKS/2026-01-01_tool-x.md", F.text(F.meta("Tool", "done")))
  eq(
    resolve.resolve("TOOLS/tool-x", { roots = { root } }),
    {},
    "a non-area folder is no area for finished tasks"
  )

  -- a task linking another by a bare `[[slug]]`: answering where it is must not index the vault for that link
  F.task(H, root, "lib.nvim", "linker", F.meta("Linker", "open", { { "after", '["[[alpha]]"]' } }))
  local wikilinks = require("tasks_nvim.wikilinks")
  local real_build, built = wikilinks.build_index, 0
  wikilinks.build_index = function(...)
    built = built + 1
    return real_build(...)
  end
  local linker = resolve.resolve("lib.nvim/linker", { roots = { root } })
  wikilinks.build_index = real_build
  eq(#linker, 1, "the linking task resolves")
  eq(built, 0, "no vault index was built for its links")

  -- ── second review: never an error, whatever a caller hands in ──────────
  eq(resolve.resolve("lib.nvim/alpha", 5), {}, "opts that are no table")
  local guard = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(guard, 0, -1, false, { "nothing", "last: lib.nvim/alpha" })
  local below, below_tok = resolve.resolve_at(guard, -1, 8, { roots = { root } })
  eq({ below, below_tok }, { {} }, "row -1 is no row, not the last line")
  eq({ resolve.resolve_at(guard, 0, 8, { roots = { root } }) }, { {} }, "row 0")
  vim.api.nvim_buf_delete(guard, { force = true })
  eq({ resolve.resolve_at("x", 1, 0) }, { {} }, "a buffer that is no number")
  eq({ resolve.resolve_at(nil, "1", 0) }, { {} }, "a row that is no number")
  eq(
    resolve.resolve("lib.nvim/alpha", { roots = { "", root .. "/no-such-dir" } }),
    {},
    "only unusable roots: nothing, and no fallback to the configured vault"
  )

  -- ── third review ───────────────────────────────────────────────────────
  local tb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tb, 0, -1, false, { "see lib.nvim/alpha", "two" })
  eq({ resolve.resolve_at(tb, 1.5, 6, { roots = { root } }) }, { {} }, "a fractional row")
  eq({ resolve.resolve_at(tb, math.huge, 6, { roots = { root } }) }, { {} }, "an infinite row")
  eq(
    { resolve.resolve_at(tb, 1e300, 6, { roots = { root } }) },
    { {} },
    "a row too large for an integer"
  )
  eq({ resolve.resolve_at(tb, 3, 0, { roots = { root } }) }, { {} }, "a row past the last line")
  eq({ resolve.resolve_at(tb, 1, -1, { roots = { root } }) }, { {} }, "a negative column")
  vim.api.nvim_buf_delete(tb, { force = true })
  eq(token("see lib.nvim/alpha", 6.5), {}, "a fractional column is no column")
  eq(
    resolve.resolve("lib.nvim/alpha", { roots = { root .. "\0x" } }),
    {},
    "a root with a NUL byte is refused (it walked the vault for ever before)"
  )
  eq(
    select(1, require("tasks_nvim.vault").root({ root = root .. "\0x" })),
    nil,
    "and vault.root refuses it"
  )
  eq(token(("a"):rep(300) .. "/x", 5), {}, "a run longer than any id is no id")
  eq(token("see lib.nvim/alpha", 6)[1], "lib.nvim/alpha", "an ordinary id still is one")

  -- ── every finished file, and both of a duplicate ───────────────────────
  -- finished three times (twice as a task, once as a feature, the newest a folder task): every file, the newest first
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-09-01_redo.md",
    F.text(F.meta("Redo first", "done"))
  )
  H.write(
    root .. "/lib.nvim/Backlog/FEATURES/2026-10-05_redo.md",
    F.text(F.meta("Redo second", "done"))
  )
  local newest = root .. "/lib.nvim/Backlog/TASKS/2026-10-10_redo/2026-10-10_redo.md"
  H.write(newest, F.text(F.meta("Redo third", "done")))
  local redo = resolve.resolve("lib.nvim/redo", { roots = { root } })
  eq(
    vim.tbl_map(function(x)
      return x.kind .. " " .. x.title
    end, redo),
    { "done Redo third", "done Redo second", "done Redo first" },
    "every finished file of a slug, the newest first"
  )
  eq(redo[1].path, newest, "a finished folder task is its task file")
  eq(
    vim.tbl_map(function(x)
      return x.date
    end, redo),
    { "2026-10-10", "2026-10-05", "2026-09-01" },
    "each says the day it was finished"
  )
  -- one made by hand without a date, and a folder task whose file was not renamed: undated last, the folder's day counts
  H.write(root .. "/lib.nvim/Backlog/TASKS/redo.md", F.text(F.meta("Redo undated", "done")))
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-10-07_redo/redo.md",
    F.text(F.meta("Redo by folder", "done"))
  )
  eq(
    vim.tbl_map(function(x)
      return x.title
    end, resolve.resolve("lib.nvim/redo", { roots = { root } })),
    { "Redo third", "Redo by folder", "Redo second", "Redo first", "Redo undated" },
    "by the day, an undated one last"
  )
  eq(
    #require("tasks_nvim.scan").find_done_all("lib.nvim/nothing-here", { root = root }),
    0,
    "find_done_all of a slug never finished is empty"
  )

  -- an open task as a file and as a folder: both are targets, the file first (it was no target at all before)
  local dupe_file = F.task(H, root, "lib.nvim", "dupe", F.meta("Dupe as file", "open"))
  local dupe_folder = root .. "/lib.nvim/ROADMAP/tasks/dupe/dupe.md"
  H.write(dupe_folder, F.text(F.meta("Dupe as folder", "open")))
  local dupe = resolve.resolve("lib.nvim/dupe", { roots = { root } })
  eq(
    vim.tbl_map(function(x)
      return { x.kind, x.path, x.title }
    end, dupe),
    { { "task", dupe_file, "Dupe as file" }, { "task", dupe_folder, "Dupe as folder" } },
    "a duplicate gives both of its files"
  )
end
