# Changelog

All notable changes to tasks.nvim. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the version is not tagged yet (the repository is not published).

## [Unreleased]

### Added

- The task engine (`lua/tasks_nvim/`), extracted from the author's Neovim config: one Markdown file per task, a
  generated overview per area, `done` that moves a task to `Backlog/` with snapshot and rollback.
- `:Tasks` (`list`, `new`, `set`, `done`, `attach`, `folderize`, `index`, `template`, `open`, `preview`, `folder`),
  a snacks.nvim dashboard with marks, filter chips, sorts and live refresh, a Markdown form for `new`, and a
  headless CLI (`scripts/tasks.lua`, `scripts/tasks-ci.lua`).
- `setup()` with a validated config (`vault`, `extra_areas`, `dashboard`, `staleness`, `ci`, `keys`); every key of
  the dashboard and the form is rebindable or can be switched off.
- `:'<,'>Tasks new`: a task about the selected lines (a `refs:` entry for them, the first line as the title).
- `tasks_nvim.batch` (`set_many`, `done_many`): several changes with one index write per area; the dashboard uses it.
- `tasks_nvim.filter_opts`: the option-to-filter parsing, shared by the CLI, the commands and the dashboard.
- Help texts of the dashboard and the form are generated from the keys in force.
- Specs: 26 files, including a seeded fuzz/property spec; `scripts/gen_map.lua` (module map with the engine/UI layer
  rule); docs: README, `doc/tasks_nvim.txt`, `docs/{ENGINE,COMMANDS,BINDINGS,WORKFLOWS}.md`.

### Changed

- `done` is split into plan, execute and rollback (same behaviour and messages); `staleness.compute` into resolve,
  date and compare.
- A task with neither `updated` nor `created` counts as stale for `--stale=refs` (as it already did for
  `--stale=<days>`); a failing refs check keeps the tasks that carry refs and marks them `unverified`.
- `fsio.read` refuses anything but a regular file of at most 2 MiB.
- The vault's `md_lint.lua` is run by `tasks ci` only when trusted (`--trust-vault-lint`, `$TASKS_TRUST_VAULT_LINT`,
  `ci.trust_vault_lint`), or when you name a script yourself (`--md-lint=<file>`).
- Exports never overwrite a file without `--force` (the dashboard asks).
- Parsed task files are cached by mtime and size (racy-young files never): a repeated scan of a 500-task vault takes
  ~45 ms instead of ~165 ms.

### Fixed

- Table cells are escaped in one linear pass (a long run of backslashes in front of `|` no longer freezes the editor
  or splits the cell); no pattern of the parser backtracks on whitespace (SEC-32).
- `done` never deletes a finished copy it did not create, and re-reads the task right before it removes the
  original.
- A foreign `TASKS.md` is never overwritten; an unreadable index is an error, not "missing".
- `slugify` no longer raises on a NUL byte.
