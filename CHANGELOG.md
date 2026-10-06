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
- Undertakings: plan files under `ROADMAP/plans/` (`:Tasks planfile`, `plan-new`), the task fields `plan:` / `phase:`,
  stage order with `gate: hard`, `--plan=<id>` scope, generated blocks in documents (`plan --write` / `--check`,
  `chain.marker_docs`), a plan finishes with its last member. Soft edges `after`, the sort hint `order`, `same-file`
  marks. The optional `## Plan` section of a task (progress, `--with-steps`, `template --with-plan`, an acceptance
  hint), ticked by `done`; opt-in `steps.ask_finish`. `check`: `after-self`, `after-dangling`, `bad-after`,
  `bad-order`, `bad-plan`, `bad-phase`, `plan-unknown`, `plan-area`, `plan-phase`, `plan-target-unknown`, plan file
  codes.
- `:Tasks plan`, `:Tasks next`, `:Tasks estimate [--walk]` and the headless `plan`, `next`, `estimate`: one definition of
  "ready" (`tasks_nvim.plan`), `list --ready|--waiting|--unestimated`, stages / leverage / critical path / effective
  prio / cycles from `blocked_by` alone, sums that name what is missing, the best next task with the reason and honest
  empty answers.
- After `done`: the tasks it freed and the next task, as a small dialog (`next.popup`), as `freed:` / `next:` lines in
  the CLI (`--no-next`), once for a whole stack in the dashboard; a task that waited only on the finished one and still
  says `blocked` is offered to be set to open (`done --unblock` in the CLI).
- `check`: `blocked-by-cycle` (error), `doing-while-blocked`, `blocked-without-blocker`, `blocker-freed`,
  `blocked-by-parked` (warnings).
- Dashboard: counts by the open blockers, the number of ready tasks, the sum of the shown tasks, a hint that names
  open blockers only, an `unestimated` filter.
- Fields `value` (1-5, expected benefit) and `actor` (`cdx` / `me` / `pair`): `new`/`set`, `--value=` and `--actor=`
  filters (`--actor=me` also finds decisions and `needs-user` tasks without migrating), `--sort=roi`, dashboard row,
  chips and filter menu, CSV columns `Value`, `ROI`, `Actor` (appended), `check` codes `bad-value`, `bad-actor`,
  `actor-cdx-waits-on-me`, the CLI guard rail on `status=doing` for a task that is for the human, and
  `migrate-actor [--write]`.
- `tasks_nvim.done_flow`: one entry for finishing a task (`:Tasks done`, the dashboard and the CLI call only it); the
  follow-up chain lands behind it.
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

- Dashboard stage view (`v`), assigning tasks to a plan and stage (`P`), moving them with `order` (`J` / `K`).

- The first member of a plan that goes to `doing` (`set`, dashboard `s`) moves the plan file from `planning` to `doing`; the dashboard filters by `plan` and `phase`.

- Review round over the plan / chain / marker-block code (ultracode review, every finding probed before it was fixed):
  - `plans.close` no longer deletes a finished copy another run created, puts the README row of another run back over
    nothing, names a failed put-back, resumes a killed close and refuses a plan whose id an open task or a finished item
    already has; `plans.new` / `new` skip a slug of the other kind (one id namespace); `plans.find` checks the spelling
    of the area. The done chain counts every task of the plan that is not `done` (a mistyped status keeps it open), does
    not close on a partial scan and checks each plan once per batch.
  - Generated blocks: the start marker records the target, view and filters, repeated and fenced blocks, per-line line
    endings, a quoted plan summary, ambiguous names are skipped, one vault scan and a re-read before the write per
    document, `plan --write` refuses a scope with unreadable folders, a document that is a symlink is written through,
    `--write=<path>` and `chain.marker_docs` are literal paths, `$TASKS_MARKER_DOCS` for the headless CLI.
  - Concurrency: README rows and task frontmatter are written under a lock (no lost update); `done`'s rollback leaves
    the README and index of another run alone.
  - Quadratic patterns (SEC-32 class) in the `## Plan` checkbox line and the folder-task asset scan; a huge title can
    no longer push a generated file past the read limit; an unreadable task no longer deletes an index.
  - CLI: a typed count is one cycle, `migrate-actor` checks its area, `done --unblock` advises after the unblock,
    unknown statuses are not "everything is done", ids are cleaned in `next` / `list` output.
  - Dashboard: `list --ready|--waiting` is kept (a `readiness` filter dimension), one scan per load (the live refresh
    and `s` / `p` no longer scan twice), the done chain's notes are reported, a dismissed `estimate --walk` dialog ends
    the walk, `:Tasks new` carries `after=` / `order=` / `plan=` / `phase=` through the form, the watcher also watches
    `plans/` and mutes the echo of its own writes after a slow rescan, the help float is as tall as its wrapped text.
  - Staleness: positions after a Windows drive letter, invalid dates, one probe instead of a spawn per path when git
    cannot be used; same-file marks follow the file a ref resolves to.
- Table cells are escaped in one linear pass (a long run of backslashes in front of `|` no longer freezes the editor
  or splits the cell); no pattern of the parser backtracks on whitespace (SEC-32).
- `done` never deletes a finished copy it did not create, and re-reads the task right before it removes the
  original.
- A foreign `TASKS.md` is never overwritten; an unreadable index is an error, not "missing".
- `slugify` no longer raises on a NUL byte.
