-- luacheck configuration for tasks.nvim.
--
-- Scope: lua/, TESTS/, scripts/ and plugin/ (CI runs `luacheck lua TESTS scripts`).
std = "luajit"

-- Readable prose in comments and @type annotations over a hard column cap, same call the other plugin repos make.
max_line_length = false

globals = { "vim" }

read_globals = {
  -- Neovim's bundled LuaJIT ships the 5.2-style table.unpack/pack shims;
  -- luacheck's stock luajit std predates them.
  table = { fields = { "unpack", "pack" } },
  math = { fields = { "type" } },
}

-- 212/213: unused argument / loop variable — pervasive in event callbacks and
--          callbacks that must keep a fixed signature.
-- 542: empty if/else branch — used deliberately as a documented no-op (each
--      instance carries an explanatory "continue upward" / "stop here" comment).
ignore = {
  "212",
  "213",
  "542",
}

exclude_files = {
  "**/@types/**",
  "docs/**",
}

-- TESTS/ uses a shared harness (no busted globals), nothing to add; scripts/ run through `nvim -l`.
