# Changelog

All notable changes to tasks.nvim. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the version is not tagged yet (the repository is not published).

## [Unreleased]

### Added

- The machine contract `tasks-export/1` ([docs/CONTRACT.md](docs/CONTRACT.md)), read only: the documents `hello`,
  `snapshot`, `list`, `task`, `next`, `areas` and `error`, each with `rev` / `digest` and a version tag (`etag`) per
  task; one door `tasks_nvim.api.call` that never throws; `tasks call <method> --params=<json>`, `--capabilities`,
  `list --format=json|--limit|--offset|--done`, `next --format=json`, `areas --format=names|tsv|json`, `show`, `plans`;
  a canonical JSON encoder (`tasks_nvim.json`: sorted keys, `{}` stays `{}`, deterministic numbers, escaped `<` and
  control bytes); JSON Schemas (draft 2020-12), generated TypeScript types, golden files of a synthetic fixture vault
  and the CI job `contract` (Ajv, strict).
- `check`: `symlink-task`.
- `mutate.set`: `if_match` / `expect` are checked under the lock (compare-and-set), a conflict is structured
  (`code`, `id`, `key`, `expected`, `actual`), the answer has `etag_before`, `etag_after` and the old values for an
  undo; `fsio.with_lock` tells `locked` from `lock_stuck`; a task file that is a link is not written through.
- Named lists: `setup({ lists = {...} })`, saved lists (a state file, written from the dashboard menu `gl` or by
  `tasks lists save`), three built-in lists, `:Tasks lists`, `--list=<name>` / `tasks list @<name>` (also for `plan`,
  `estimate`, `quickwins`), `:checkhealth` reports skipped lists.
- Quick wins: `setup({ quick_wins = { min_value, max_effort } })` (default value 4, effort S), the filter `--quick-win` for
  `list`, `plan` and `estimate`, and `:Tasks quickwins` / `tasks quickwins` (best return first, the small tasks that miss a
  value named apart, `--by-actor`, `--paths`, `--report=<file>`).
- `scripts/tasks-html.lua`: a one-file HTML overview of the vault (Today card, filter chips with counts, search,
  grouping by status, stage or area), built from `list`, `plan --format=tsv` and `next`; `--exclude=` leaves areas out,
  the file holds no path of your machine and carries a Content-Security-Policy.
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
- Every flag and `key=` of `:Tasks` (and of the nested routes a host mounts, e.g. `:MyPlugins tasks ...`) has a one-line
  `desc` for lib.nvim's option float, and `enum_desc` for the values that need a word (`--sort=`, `--format=`,
  `--action=`, `actor=`, `status=`); `TESTS/tasks_usrcmds_help_spec.lua` fails for an option without one. The same
  goes for the positional arguments (`<area>`, `<id>`, `<file>`, `<folder>`): each route words its own `desc`, and
  the types `TASK_AREA` and `TASK_ID` carry a text of their own for any argument that has none.
- Specs: 26 files, including a seeded fuzz/property spec; `scripts/gen_map.lua` (module map with the engine/UI layer
  rule); docs: README, `doc/tasks_nvim.txt`, `docs/{ENGINE,COMMANDS,BINDINGS,WORKFLOWS}.md`.

### Changed

- The specs run on testing.nvim (`.testing.lua`, `scripts/test.sh`, CI); `TESTS/run.lua` is gone, the specs and `TESTS/harness.lua` are unchanged. All testing.nvim guards (fs, state, scheduled errors, prompts, deprecations, processes) fail the run; only `nvim`, `git` and (for the `scripts/test.sh` spec) `bash` may be started.
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

- `scripts/test.sh` finds snacks.nvim (`$SNACKS_DIR`, `.deps/`, beside the repository, the plugin manager's data folder)
  and hands it to the specs: the runner gives every spec a sandboxed data folder, so the picker part of the dashboard
  specs no longer stops running on a local machine. Without snacks.nvim the script says so first and
  `tasks_dash_picker_spec` / `tasks_dash_refresh_spec` report a `skip` (the skip line comes before their first
  assertion, otherwise testing.nvim would keep a green PASS); the dashboard's plain `vim.ui.select` fallback moved into
  its own spec, `tasks_dash_fallback_spec`, which always runs. `tasks_test_script_spec` skips the same way when no POSIX
  bash is usable (WSL's `bash.exe` is not). The paths of a "not found" message are computed only when it is shown (a
  run starts fewer processes).
- `tasks_usrcmds_help_spec` (the option-float texts) no longer ends in a silent green PASS on a lib.nvim without
  `composer.help.undocumented`: the guard comes before the first assertion, so the runner reports a SKIP, and it also
  covers a lib.nvim that has no `composer.help` at all (that used to raise "attempt to index nil"). The shape checks
  (one line, no closing full stop, 12 to 80 characters, `enum_desc` keys, the text of `TASK_AREA` / `TASK_ID`) moved into
  `tasks_usrcmds_help_style_spec`, which needs no `undocumented` and always runs.
- Second review round (the fix and feature commits of the first one, ultracode, 27 confirmed findings): `with_lock` keeps
  its deadline for a stale lock that cannot be deleted and waits out EPERM; the dashboard watcher counts `.<name>.lock`
  events; an overlapping `plans.close` no longer deletes the only copy of a plan; a `done` rollback leaves a README that
  merged another run's row; plans with an unreadable member and unreadable folders are never "closed" / "all done";
  `set plan=<new> status=doing` starts the new plan; recorded `plan=` / `for=` / `area=` marker targets that are gone
  are history or a skip, never an empty rewrite; a closed plan's text never overwrites an area block; same-file marks
  look a file up only for names two tasks write; `migrate-actor --no-index`; the stage view moves tasks that have no
  `order` yet (the group is numbered first), keeps `after` targets out of "Unsorted", knows stage changes in its refresh
  signature and builds its plan only while it is shown; headings are no rows to open in either picker; the kit picker
  flushes its debounced filter before it is read, marks in place and reports a failing preview.

- `dashboard.backend = "kit"`: the dashboard on lib.nvim's own picker (marks, highlights, preview, stage view, assign and move), no snacks.nvim needed; `auto` (default) uses snacks when installed and the kit picker otherwise.

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

### Security

- The read side stays inside the vault: a task file that is a symbolic link or a junction is not read (`symlink-task`);
  a `ROADMAP`, `tasks`, `Backlog` or `plans` folder whose real path leaves the vault is not scanned and is reported; a
  folder of the vault root that is a link is no area.
- `--stale=refs`: a `refs:` entry that is a network or device path (`\\server\share`, `//server/share`, `\\?\C:`) is skipped instead of being
  stat'ed (on Windows that connects to a host the task's author chose), and an absolute ref is looked up only inside the
  places the engine was told to look in.
