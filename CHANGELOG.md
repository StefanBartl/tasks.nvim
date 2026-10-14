# Changelog

All notable changes to tasks.nvim. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the version is not tagged yet (the repository is not published).

## [Unreleased]

### Fixed

- Review of `:Tasks open` by a part of a name and of `:TasksVault`: a title is matched in any case also when it is not ASCII (`über` finds `Über uns`), `area/part` prefers the exact spelling of the area, the completion lists an id once, a missing vault is told instead of "no task matches"; the hint for a vault without an area names the command with the vault's own folder, and naming the folder in use again adds an area to it without `--force`; a `create` that fails at a later area names the folders made before it.
- Review of `:TasksVault create`: an area folder that cannot be made (a file in the way) fails the create with the reason instead of reporting a vault with the area missing; a clipboard that cannot be written is told and not claimed to hold the setup line; the hints for an empty vault name `:TasksVault create <dir> <area>` and not `:Tasks new` (which refuses an unknown area); the lazy.nvim example and the health hint load the plugin on `:TasksVault` as well; the help file names `--yes` and the README the part `all`.
- The editor commands `:Tasks list`, `plan` and `estimate` take `--phase=` (and `list` also `--plan=`), as the CLI does; the code passed both to the filter already, only the flags were missing from the routes. The drift guard (`tasks_verbs_drift_spec.lua`) shows the smaller difference.
- An effort of more than 3650 days (`3651d`, a digit string beyond a double) is no effort: `model.is_effort` refuses it, so a task file that holds one is a `bad-effort` finding and the number is not exported, `ops set` and `new` refuse it, and `estimate` names it - before, one such file or write made `snapshot` and `estimate` fail as `internal` for the whole vault. The notes of `check` are matched at their start and told once.
- Review of `estimate`, `plan_for` and `check`: an assumed effort of more than 3650 days (or a longer digit string) is refused by name instead of failing as `internal`; an `assume` entry needs an effort or a value; `estimate` lists its tasks in the order of the snapshot; `plan_for` names a repeated `blocked_by` entry once, builds the dependents only for `unlocks`, and names a cycle only when it lies whole among the nodes; `check` counts the stale-refs warnings in `warnings`, tells no folder of this machine in its notes or messages, sorts errors first with a total order, and takes `ref_opts` for the specs.

### Added

- A task file whose lists are YAML block lists (`tags:` + `  - a`, as Obsidian's Properties editor writes them) is a valid task: `check` has no `frontmatter-invalid`, and `set` keeps the style of the list it changes (a one-id `blocked_by`/`after` stays a list there) and the bytes of the lists it does not touch (`lib.nvim/frontmatter-block-lists`; spec `tasks_block_lists_spec`).
- The dashboard watcher reacts to a handle that fails while running (`lib.nvim.fs.watch` `on_error`): the handle is released, everything is rescanned and the folder watched again (`lib.nvim/fs-watch-meldet-fehler`; counted in `stats.watch_errors`).

- `:Tasks open` finds a task by a part of its name: the slug (equal, start, inside), then the title of an open task, case does not matter, `area/part` narrows it to one area. One hit (or the one slug that is exactly the text) opens, several are offered in a list, none is told with the closest slugs; `<Tab>` completes a slug without its area where it is unique. The matching is `tasks_nvim.match` (engine), the full id works as before. Spec `tasks_open_match_spec` (taking the exact-slug rule, the list or the completion type out makes it red).

- `:TasksVault`: a second editor command for the vault itself. `open`, `clipboard`, `paste`, `link`, `find`, `grep`, `tree` and `cdx` act on the Backlog (or `features|tasks|roadmap|all`) of an area, the area taken from the argument (a unique prefix is enough), the current buffer or a picker; `new feature|task <title>` writes a dated note with its README row; `create [<dir>] [<area>...]` first lists what happens (folder, areas, in use for the session, and the step that is left to you: the `vault` option of `setup()` or `$TASKS_VAULT`, without which nvim does not find the vault again), then makes the folder, uses it for the session, puts the setup line in the `+` register and names the open step again (`--yes` skips the question). Without a vault every verb but `create` gives the same single notice (the vault is reported before a stray word). New `vault_ops` (paths, area of a path, relative links, notes, vault creation), `ui/vault_cmd`, `ui/vault_routes`, `bindings/usrcmds/vault`; `vim.g.tasks_nvim_no_vault_command` keeps it out and is independent of `vim.g.tasks_nvim_no_command` (which leaves `:TasksVault` there). `features` and `tasks` are folders (no index file); a word that is a part and an area name (`all` / `ALL`) means the area.
- `move_area` in `tasks-ops/1` is a write (capability `move_area`, `if_match`?): the open task moves to the other area under the same slug (a folder task as a whole), `updated` is set, and the `blocked_by`, `after` and `refs` of other tasks and the `target` of plans that named the old id name the new one - all or nothing, with the snapshot restored byte-exact when a step fails (`moves.move`). The entry has `outcome` `moved`, `new_id`, `rewritten` and an `inverse` (a `move_area` back); the `Inverse` of the schema may be a `move_area` (`to_area`). A document that names the id is not rewritten (told in `notes`). The dry run is unchanged.
- `set_body` in `tasks-ops/1` (capability `set_body`): replaces the text below the frontmatter of an open task (`id`, `body`, `if_match`?; at most 100000 characters, no control character but the line break and the tab, trimmed at both ends, the file keeps its line ending). Sets `updated`, a compare-and-set, a dry run writes nothing; the entry has an `inverse` that is a `set_body` with the old text (none when that is too long to be sent again). The `Inverse` of the schema may now be a `set_body` (`body`). Core: `mutate.edit_text`.
- `check` in `tasks-export/1` (capability `check`, document `tasks.check`): the rule check of the vault as a document - findings with a stable `code`, a severity, the area, the task id when there is one and the file relative to the vault; with `stale: refs` also the open tasks that name a file which changed after the task was updated. At most 1000 findings. New `contract.check`.
- `plan_for` in `tasks-export/1` (capability `plan_for`, document `tasks.planfor`): the tasks one task needs before it can start (`needs`, transitively, across areas, over `blocked_by` and the gate of a plan) or the tasks that wait for it (`unlocks`), with the hard edges between them, their distance from the task, the part of the critical path they lie on and the cycles they touch. The same tasks as `plan --for`; at most 500 nodes. New `contract.plan_for`.
- `estimate` in `tasks-export/1` (capability `estimate`, document `tasks.estimate`): the figures of an estimate (sum, range of the sizes, value, return, how many tasks have an effort and a value) for the tasks named, also as they would be with other efforts and values (`assume`; nothing is written). The same figures as the snapshot, so a client that shows the sum of a draft never reckons it itself. New `contract.estimate`.
- Capability `eff_prio`: `readiness.eff_prio` is the priority a task is grouped by (its own or the best of the tasks that depend on it; missing when there is none), always equal to the part after the bar of `group` (a spec over the fixture, cycles included). A client reads the number and never takes the key apart.
- `reopen` in `tasks-ops/1` (capability `reopen`): a finished task comes back to `ROADMAP/tasks` with status `open` (or the one given), `done_in` and `remind` dropped, and its row leaves the Backlog README (the count is recomputed, the placeholder comes back when it was the last). An open task is `unchanged`; a folder task, a bad status and a name that an open task or a plan has are refused; `if_match` is the version of the finished file; a README row that cannot be taken out is told in `notes`. New `mutate.reopen` and `mutate.readme_remove_row`.
- `new` in `tasks-ops/1` takes a `body` (text, at most 20000 characters, no control character but the line break and the tab): the file gets that text below the frontmatter instead of the sections of the template, the first paragraph is the summary of the index. Empty, too long or with a control character it is refused; a dry run writes nothing.
- `tick_step` and `append_note` in `tasks-ops/1` (capabilities of the same names): tick or untick one step of the `## Plan`
  section of an open task (`n` is the number the `steps` of the `task` document carry; a dropped step is refused; the entry
  has an `inverse`), and add one dated line below the notes (`## Notizen` / `## Notes`, made when missing; no `inverse`).
  Both are a compare-and-set on `if_match`, set `updated`, keep the line endings and every other byte, and answer a dry run
  without writing. The core is `mutate.edit_text` (the text of a task changed under the lock like `set` does for the keys)
  and `steps.set_step` / `steps.add_note`. The `Inverse` of the schema may now be a `tick_step` (`n`, `done`).
- `plan_new` in `tasks-ops/1` (capability `plan_new`): makes a plan file like `plan-new`. The entry carries `file`, `slug` and
  `renamed` (the slug was taken, `-2`, `-3` ... was chosen); a dry run names the id and writes nothing, not even the folder,
  so a form can show the name and the collision while the person types.
- Reminders in Neovim: one line at startup says how many are due (`reminders = { on_start = true }`, deferred, once per
  session, only with a UI; `false` turns it off, also after the timer was set; the scan runs in steps, one area per turn
  of the loop, so the editor is not held; it names up to three finished tasks that carry one and how to open them), the
  dashboard's `f` menu has the filter `reminders` ("reminder due"), `:Tasks list --reminders` and `:Tasks tasks --reminders`
  filter the same way, a named list can hold it (`reminders = true`, `lists save <name> --reminders`), and the headless
  `next` lists the due ones (`remind: <id> <title> <date>`, and a line with the number of finished tasks that carry one,
  which `list --done --reminders` lists).

- A reminder, `remind: YYYY-MM-DD`: when to look at a task again. `set <id> remind=+7d` (a date, `+<n>d` or `+<n>w`, at
  most a year; the file always holds the date), `remind=` takes it away, `done --remind=7d` and the `done` operation's
  `remind` set it on the finished task, `list --reminders` lists those that are due. The entry of the contract carries
  the date (`remind`), not whether it is due, so that a digest does not change with the day. Capability `reminders`.
  A reminder is most often set when a task is finished, and a finished task is not in `tasks`: the snapshot carries
  `reminders` (the finished tasks with a reminder, oldest date first, at most 100), and `set` / the `set` operation may
  set and take away `remind` on a finished task (nothing else of it).
- The persistent engine `scripts/tasks-host.lua` (`tasks_nvim.host`): `nvim -l scripts/tasks-host.lua` answers the
  machine contract over stdin and stdout, one line per question, until its input ends; the documents are those of
  `api.call`, byte for byte, and a question costs milliseconds instead of a process start. Line protocol in
  [docs/CONTRACT.md](docs/CONTRACT.md). `tasks_nvim.boot` finds lib.nvim for both scripts.
- `json`: strings with nothing to escape skip the four substitutions (a snapshot of 630 tasks encodes about 15 % faster).

- `bodies` (`tasks.bodies`), additive to `tasks-export/1`: the text of the open tasks, a page at a time or by `ids`, with
  the `etag` of each and the `rev` of the snapshot of the same state, for a reader that builds a full-text index.
  Capability `bodies`.
- The machine contract `tasks-export/1` ([docs/CONTRACT.md](docs/CONTRACT.md)), read only: the documents `hello`,
  `snapshot`, `list`, `task`, `next`, `areas` and `error`, each with `rev` / `digest` and a version tag (`etag`) per
  task; one door `tasks_nvim.api.call` that never throws; `tasks call <method> --params=<json>`, `--capabilities`,
  `list --format=json|--limit|--offset|--done`, `next --format=json`, `areas --format=names|tsv|json`, `show`, `plans`;
  a canonical JSON encoder (`tasks_nvim.json`: sorted keys, `{}` stays `{}`, deterministic numbers, escaped `<` and
  control bytes); JSON Schemas (draft 2020-12), generated TypeScript types, golden files of a synthetic fixture vault
  and the CI job `contract` (Ajv, strict).
- `check`: `symlink-task`.
- The write door of the machine contract, `tasks-ops/1` (`tasks_nvim.ops`, `tasks call ops`): `set`, `new`, `reorder`, `done`
  and `move_area` (as a dry run) answered with a `tasks.result` that has one entry per operation (`outcome`, `etag_before`,
  `etag_after`, `inverse`, `error`); the shape of a request is checked as a whole, then each operation runs on its own;
  `if_match` / `expect` conflicts name what was found; relations are judged first (`edges`); limits and a strict `refs`
  check for new entries; `done` needs the `confirm` token of the new read method `done_preview` (`tasks.donepreview`);
  `dry_run` for everything; `--params=-` reads a request from stdin; new error codes `conflict`, `exists`, `forbidden`,
  `lock_stuck`, `rollback_incomplete` (`tasks_nvim.errors`); hello capabilities `ops`, `if_match`, `done_preview`,
  `reorder`, `move_area_preview`; schema, golden files and checks for `tasks.result` and `tasks.donepreview`.
  A front end cannot write a control character (ESC, NUL, C1, U+2028) into a value; an internal error names the file in the
  plugin (`tasks_nvim/x.lua:12`), never where it is installed; `--today` reaches `call ops`.
- `moves.preview`: moving a task to another area, stage 1: whether it can be done (the slug must be free in the target area) and which `blocked_by`, `after`, `refs`, plan targets and documents would dangle; nothing is written.
- `done_flow.preview` / `mutate.done_preview`: what finishing a task would do (target, README row, steps, the plan it closes, the tasks it frees), nothing written, with a `confirm` token that binds the version of the file; `done` takes `if_match`.
- `batch.reorder`: move a task inside its group by giving it an `order` between its neighbours' (numbering the tasks before the spot only when they have none, renumbering when two values get too close), with the `inverse` for an undo; `plan.group_key`.
- `reorder` answers with `restore`: one `set` of `order` for every file the move wrote, so an undo gives each file its old value back (the `inverse` only restores the place); schema and types carry it.
- `tasks_nvim.edges`: `validate` judges a change of `blocked_by` / `after` / `plan` / `phase` before it is written, with
  the codes of `check` (self, dangling, cycle, unknown plan, a phase the plan does not list).
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

- Reminders: the finished tasks with a due reminder are named in the startup line, and `:Tasks set <id> remind=` works on a
  finished task (nothing else of it), so a reminder that is only on a finished task can be found and cleared in the
  editor; the headless `next` points at `list --done --reminders` (it pointed at a command that lists the open tasks
  only). `next` rejects a `--today` that is no date (it silently counted every reminder as due), and only the text of
  `next` computes the reminders at all (`done`, `next --format=json` and the dialog after `done` no longer sweep every
  finished file for a result they do not use). `plan`, `estimate` and `quickwins` do not take `--reminders` in the editor
  either (the filter was lost when a plan block was refreshed); a named list that sets it is refused by `plan` and
  `estimate`. A `Backlog/<bucket>` folder that leads out of the vault is not read for reminders (the snapshot names it
  in `incomplete`).
- `engine.git`: a retry after a lookup that timed out waits 0.5 s, not 2 s (a loaded machine held a request for 6 s in
  all, now 3 s); the code 124 of the wait alone counts as "no answer".
- `engine.git` (the commit in `hello` and every document): a lookup of git that did not finish in 2 s (a loaded
  machine) was kept as "unknown" for the life of the process, so a long-lived host stayed "unknown". An answer that
  did not come in time is asked again later (three tries); a definite answer is still kept.
- `:Tasks new`: a vault without areas (the wrong folder, or one that moved while Neovim still held the old path) was
  reported as "'<name>' is not an area of the vault" for every name. The form now says "The vault has no areas: <folder>"
  and why that happens (the vault is read at startup), as a warning when the form opens and again in its report.
- `:Tasks new`: dismissing the "Attach assets?" question (`<Esc>`, `q`) created the task anyway, as if "No" had been
  answered. Now it creates nothing and the form stays open with what was typed; only "No" makes the plain task, and
  the question no longer shares the dialog seam of `estimate --walk` (`ui.cmd.chooser`).
- `:Tasks new`: an area that is not the folder's name (`hover` for `hover.nvim`) now says which areas come close (up to three,
  the ones that start with the typed name first).
- CLI: a global option typed before the command (`--vault=x new area -- "--title"`) was moved behind a bare `--`, where it became part of the text; it now goes right behind the command name, so a title that starts with `--` can be given.
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
