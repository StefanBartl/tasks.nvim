# `tasks_nvim` -- the task engine

Open work in a task vault is one Markdown file per task
(`<area>/ROADMAP/tasks/<slug>.md`, flat-YAML frontmatter; or a *folder task*
`<slug>/<slug>.md` that can hold assets), with a generated
overview per area (`<area>/ROADMAP/TASKS.md`). This namespace reads, ranks,
indexes, creates, changes, finishes and checks those files.

It is **pure Lua with no UI and no notifications**: functions return data or
`nil, err`, and the callers decide how loud to be. The editor commands and the
headless CLI are front ends over it.

**Why `lua/tasks_nvim/`.** `tasks` is a generic word, so a plugin shipping
`lua/tasks/` could shadow (or be shadowed by) another one; the `_nvim` suffix is the
fleet's convention for exactly that case.

**Setup.** There is no built-in vault path. Call `require("tasks_nvim").setup({ vault = "<dir>",
extra_areas = { ... } })` or set `$TASKS_VAULT` (and, for the headless CLI, `$TASKS_EXTRA_AREAS`,
comma separated). `extra_areas` names folders that are areas although they hold neither
`ROADMAP/` nor `Backlog/`.

```
lua/tasks_nvim/
├── init.lua      lazy aggregator (tasks_nvim.vault, ...) and `setup`
├── fsio.lua      byte-exact file primitives (atomic write, O_EXCL create, CRLF helpers)
├── vault.lua     vault root, areas, paths, id/slug validation
├── model.lua     task record, enums, ranking, filters
├── scan.lua      collect task files (open and Backlog)
├── index.lua     render/write ROADMAP/TASKS.md, global export text
├── mutate.lua    template, new, set, done
├── form.lua      the Markdown form of `task new` (template, parse, validate, tick rules)
├── check.lua     rule checker
├── frecency.lua  visit score behind `--sort=frecency` (pure scoring + a small state file)
├── staleness.lua `--stale=refs`: referenced files changed since `updated`
├── ci.lua        CI gate: check + index --check + md_lint
├── cli.lua       command-line front end
└── @types/       LuaLS types
scripts/tasks.lua   headless entry (nvim --headless -u NONE -l)
scripts/tasks-ci.lua  same as `tasks.lua ci`, the one entry point for a pipeline
TESTS/              specs (run with TESTS/run.lua)
```

## Modules

| Module | What it does | Key functions |
|---|---|---|
| `tasks_nvim.vault` | Resolves the vault root (`opts.root`, `set_root`, `configure`/`setup`, then `$TASKS_VAULT`; no default path). An *area* is a folder holding `ROADMAP/` or `Backlog/`, plus the configured `extra_areas`; `_`-prefixed folders, `TEMPLATES` and `TOOLS` are skipped. Builds every path; whitelists area names (no trailing dot: Windows drops it), slugs and ids before they become path segments; `is_reserved_name` knows the Windows device names. An area must be spelled exactly like its folder (`has_area`, `dir_listed`; `scan.find` too): on Windows `LIB.NVIM` or `lib.nvim.` would otherwise reach the folder `lib.nvim` under a different id. | `root`, `areas`, `has_area`, `dir_listed`, `tasks_dir`, `index_path`, `backlog_dir`, `parse_id`, `valid_slug`, `is_reserved_name` |
| `tasks_nvim.model` | `parse_text` / `from_file` turn a file into a `Tasks.Task`. `categories(task)` is the effective category set (below). A broken file is still returned, with `errors` / `error_codes` and `valid = false`: one bad file never hides the rest. `summary` is the frontmatter `summary`, else the first body paragraph. Sorting is status rank (`doing`, `decision`, `blocked`, `open`, `parked`), then prio, then area, then slug; `sort(tasks, order)` also knows `prio-effort` and `severity` (below). | `parse_text`, `from_file`, `sort`, `compare`, `parse_sort`, `effort_days`, `filter`, `filter_from_options`, `split_commas`, `is_date`, `days_between` |
| `tasks_nvim.scan` | `lib.nvim.fs.collect_recursive` (or the TTL cache `scan_cached` with `ttl_seconds`) over `ROADMAP/tasks/` and `Backlog/`. A folder task's `<slug>/<slug>.md` is a task (`task.folder`), the other files in its folder are assets and ignored; any other nested file is returned, flagged. Backlog files count as tasks only with frontmatter and a `status`. | `area`, `all`, `backlog`, `find`, `find_done`, `backlog_slugs` |
| `tasks_nvim.index` | `render` is pure and deterministic: the same tasks give the same bytes, whatever order they are found in. `write_area` writes only when the content differs (a CRLF checkout counts as equal and keeps its line endings), removes the file when no task is open, and with `check = true` only reports `stale` (`missing` / `outdated` / `orphan`). `render_global` returns the all-areas overview as text; nothing writes `ALL/TASKS.md` (decision E2: it is never committed). | `render`, `write_area`, `write_all`, `render_global` |
| `tasks_nvim.mutate` | `new` creates the file with `O_CREAT\|O_EXCL` (a taken slug gets `-2`, `-3`, ...; a slug used in `Backlog/` or as a folder counts as taken; `folder = true` makes a folder task). `set` validates the patch, changes only the named keys through `lib.nvim.markdown.frontmatter` and bumps `updated` only when something changed. `done` is rule R6 (below). `folderize` and `attach` turn a task into a folder task and copy assets into it. All regenerate the area index. | `template`, `new`, `set`, `done`, `folderize`, `attach`, `slugify`, `readme_add_row`, `SETTABLE` |
| `tasks_nvim.form` | The form behind `task new` without arguments, with no UI: `template` builds the Markdown text (`Area:` / `Title:` / `Tags:` / `Refs:` lines and one `- [ ]` / `- [x]` bullet list per choice field, the value sets read from `tasks.model`), `parse` reads what the user left in it, `validate` checks it (area known, title present, one tick on a single-choice list) and returns `tasks.mutate.new` options, `toggle` flips one bullet and keeps a single-choice list at one tick (`category` takes several). It creates nothing: the editor layer passes the values to `mutate.new`, the same write path as the CLI. | `fields`, `template`, `parse`, `validate`, `toggle`, `normalize`, `error_lines`, `strip_errors` |
| `tasks_nvim.check` | Collects findings over one area or the vault (table below). | `run`, `format` |
| `tasks_nvim.staleness` | `--stale=refs`: which open tasks carry a `refs:` path that changed after their `updated` (below). `compute(tasks, opts)` returns the report, `model.filter` calls it for `Tasks.Filter.stale_refs`, `classify` reads one ref. | `compute`, `classify`, `describe`, `git_dates` |
| `tasks_nvim.frecency` | The score behind `--sort=frecency` (below): `bump` / `decayed` / `scores` / `prune` are pure and take the time as an argument; `load` / `save` / `record` / `load_scores` touch `stdpath("state")/tasks/frecency.json` (or `$TASKS_FRECENCY_FILE`, `set_path`). Half-life 14 days, at most 500 entries, a corrupt file starts empty. | `record`, `load_scores`, `bump`, `scores` |
| `tasks_nvim.ci` | The vault gate for pipelines: `check` (errors fail; `strict` fails on warnings too), `index --check`, and the vault's `md_lint.lua` over every generated `ROADMAP/TASKS.md`. Returns exit code, step names and printed lines. | `run` |
| `tasks_nvim.cli` | Parses a command line, calls the engine, prints tab-separated lines, returns an exit code, never raises. | `run` |

## Front ends

- **Editor:** at the moment the editor commands (`tasks`, `task`, `open`, the dashboard, the form, the
  browser preview through the soft dependency mdview.nvim) still live in the author's Neovim config; they move
  into this plugin as `:Tasks <verb>` in the next stage. They add only what an editor needs on top of the
  engine: composer routes and completion, the `--to=` delivery, a form for a missing title, a confirmation
  before `done`, opening files and re-pointing buffers, a picker over one area folder. The filter words
  (`--status=`, `--prio=<=2`, ...) are parsed by `model.filter_from_options`, shared with the CLI, and
  the keys `task set` accepts are `mutate.SETTABLE`.
- **Headless:** `scripts/tasks.lua` (below).

### Categories

`category: [security, docs]` (optional, flat list) names the concern a task serves:
`bug`, `security`, `performance`, `docs`, `ruleset` (`model.CATEGORIES`; `ruleset` = the task
brings code in line with a rule set (for example the ones `rules.nvim` loads), optional free
field `rules: [LLS-45]` names the rule ids). An unknown value is `unknown-category`. The
*effective* categories (`model.categories`, what `--category=` filters on) are the written
list, plus `bug` for every `kind: bug`, plus every tag spelled like a category -- so tasks
written before the field existed are filterable without touching them. Categories narrow a
list, they do not reorder it (the sort stays status, prio, area, slug).

### Effort filter and sort orders

`effort` is `XS S M L XL` or days (`0.5d`, `3d`). `--effort=S,M` keeps the tasks whose written
effort is one of the words (size words are case-insensitive on the command line);
`--effort=<=M` keeps "this or smaller": sizes and days sit on one scale (`XS` 0.25d, `S` 0.5d,
`M` 1d, `L` 3d, `XL` 5d -- only used for ordering and `<=`, not a promise), and a task
without effort never matches. `list --sort=<order>` (`model.parse_sort`, `model.sort(tasks,
order)`) picks the order:

| `--sort=` | Order |
|---|---|
| `default` (no flag) | status rank, prio, area, slug -- what the index uses; unchanged |
| `prio-effort` | status rank, prio, **effort ascending**, area, slug: important and small first; a task without (valid) effort comes last of its prio |
| `severity` | **severity** (`critical`, `high`, `medium`, `low`, none last), then the default order |
| `frecency` | tasks the dashboard opened or changed, **highest score first** (see below), then the default order; ignores the status rank on purpose |

`prio-effort` and `severity` keep the status rank in front on purpose, so `doing` / `decision`
tasks do not sink below parked ones. The index (`ROADMAP/TASKS.md`) always uses the default order.

#### Frecency (`frecency.lua`)

`model.sort(tasks, "frecency", { scores = <id -> number> })` ranks by a score; without `scores`
it reads the frecency file, so `list --sort=frecency` and the dashboard's `--sort=frecency`
need no wiring (a missing or corrupt file means the default order). The dashboard records a
visit when a task is opened (`<CR>`) or changed (`s` / `p`). The scoring is pure and takes the
clock as an argument (`bump`, `decayed`, `scores`, `prune`; `opts.now` in the file functions):
an entry is `{ score, last }`, a visit adds 1 after the old score decayed to now, and the
score halves every 14 days (`HALF_LIFE_DAYS`). Entries below `MIN_SCORE` (0.05, about two
months of silence after one visit) are dropped and at most `MAX_ENTRIES` (500) are kept.
The file is `stdpath("state")/tasks/frecency.json` (`$TASKS_FRECENCY_FILE` or
`frecency.set_path` override it; the specs use a temp file), written atomically, keyed by
task id. A corrupt file (also one over `MAX_FILE_BYTES`, 1 MiB; a real one is ~120 KiB at most) starts empty (the old bytes stay as `frecency.json.bad`); a file
that cannot be read is never overwritten. Why not `lib.nvim.frecency`: its fixed recency
buckets use `os.time()` directly (nothing to inject), and it has neither a half-life nor
an entry cap.

### Severity

`severity: high` (optional) rates a **bug or security** task: `low`, `medium`, `high`,
`critical` (`model.SEVERITIES`). "Bug or security" means `kind: bug` or the effective category
`bug` / `security` (see Categories). An unknown word is the error `unknown-severity`; a
severity on any other task is the warning `severity-without-bug-or-security`. `--severity=`
filters (a task without one never matches), `new --severity=` / `set severity=` write it, `set
severity=` removes it. The generated index (`ROADMAP/TASKS.md`) does **not** show it: its
format stays as it is (an extra column would make every index stale at once, and `check`
reports that as an error); the dashboard, the CSV export and `--sort=severity` use it. The
`list` TSV columns are unchanged as well.

### Folder tasks

A task is a file `tasks/<slug>.md` **or** a folder `tasks/<slug>/<slug>.md` (same name) that
may hold assets, by convention under `assets/`. Both forms live side by side; the id is
`<area>/<slug>` either way. Only `<slug>/<slug>.md` is the task; every other file in the
folder is an asset, never read as a task. `attach <id> <file>` copies a file to
`<slug>/assets/` (turning a plain task into a folder task first) and prints the Markdown link
(`![]()` for images); `folderize <id>` converts without an attachment. `done` moves the
whole folder to `Backlog/<bucket>/<date>_<slug>/<date>_<slug>.md` and puts it back when a
later step fails. `index` links `tasks/<slug>/<slug>.md`. Reasoning: concept section 12.

An asset name (`--name=`, else the file's own name; spaces become `-`) may use letters,
digits, `_`, `.`, `-` and non-ASCII; no separators, no `..`, no trailing dot, and no name
Windows treats as a device (`nul`, `con`, `aux`, `prn`, `com1`-`com9`, `lpt1`-`lpt9`, with or
without an extension): writing to `nul` "succeeds" and stores nothing. The same names are
never generated as a slug (`new "Nul"` gives `nul-task`) and are refused as `--slug=`. An
existing asset is never replaced. A failed `attach` leaves the task as it was: the folder
conversion it started is undone (and said so in the error when that fails too). The editor
command gets the file argument already resolved by the composer (`~`, `$VAR`, `%VAR%`) and
never expands it a second time: `report[1].pdf` is that file, not `report1.pdf`, and a backtick
in a name never reaches a shell.

### `done` (rule R6)

`status: done`, `done_in`, `updated`; the file moves to `Backlog/FEATURES/`
(`feature`, `idea`, `research`) or `Backlog/TASKS/` (`task`, `bug`, and tasks
without a kind) as `YYYY-MM-DD_<slug>.md`; the row goes on top of that
section of `Backlog/README.md` (count recomputed, `_noch leer_` replaced by a
table, line endings kept); the area index is regenerated.

Failure safety: the finished copy, the README and the index are snapshotted with
`lib.nvim.checkpoint` first and restored byte-exact when any step fails. The task file
itself is deliberately not part of the snapshot (a restore would overwrite whatever was
written to it since): it is checked once more right before it is removed or moved -- when
it changed since `done` read it (the editor saved, another run), `done` stops with
`changed while it was being finished` and changes nothing -- and put back by hand only if
`done` already removed it. A folder task moves with a plain rename and is moved back by
hand-written steps (original file name and text first, the finished copy dropped only after
that); what cannot be undone is named in the error as `rollback incomplete: <path> (...)`,
never left silent.
Re-running a finished task answers `already` and changes nothing; if an earlier
run died after creating the Backlog file but before deleting the old one, the
next run completes it. A target that exists with different content, or a
finished task with the same id under another date, is refused.

### Findings of `check`

| Code | Meaning |
|---|---|
| `frontmatter-missing`, `frontmatter-invalid`, `title-missing`, `status-missing`, `field-type`, `unreadable` | the file cannot be read as a task |
| `unknown-status`, `unknown-kind`, `unknown-category`, `unknown-severity`, `bad-prio`, `bad-effort`, `bad-date` | a field has a value outside its enum / format |
| `severity-without-bug-or-security` (warning) | `severity` on a task that is neither `kind: bug` nor in the bug / security category |
| `slug` | filename is not a kebab-case ASCII slug, or the file lies in a subfolder of `tasks/` other than `<slug>/<slug>.md` |
| `slug-conflict` | the same slug exists as a file and as a folder task |
| `asset-dangling` (warning) | a folder task links `assets/<file>` that is not there |
| `index-stale`, `index-error` | `ROADMAP/TASKS.md` is missing, outdated or left over / could not be checked |
| `bad-blocked-by`, `blocked-by-self`, `blocked-by-dangling` | the blocker is malformed, the task itself, or exists nowhere |
| `blocked-by-done` (warning) | the blocker is already finished |
| `done-in-roadmap` | `status: done` in `ROADMAP/tasks/` |
| `open-in-backlog` | a task file in `Backlog/` whose status is not `done` |
| `duplicate-id` | an open and a finished task share an id |
| `frontmatter-warning` (warning) | a frontmatter line was kept but not understood |
| `title-comment` (warning) | the title has a trailing YAML comment: ` #` starts a comment, so `title: Fix bug #12` reads `Fix bug`; quote the title (`title: "Fix bug #12"`) when the `#` belongs to it. `new` and `set` quote automatically; only hand-written files are affected |

Only `error` findings make a run fail.

### `--stale=refs` -- tasks whose referenced files changed

`--stale=<days>` looks only at `updated`. `--stale=refs` (or `--stale-refs`) asks the
other question: a task with `refs: [lua/ai/config/init.lua, docs/a.md]` is stale when one of
those files changed on a **later day** than the task's `updated` (else `created`), so the task
needs a fresh read. The two combine (both must hold). The output names which file changed:
`list` appends `changed: lua/a.lua (2026-10-01, git)`, the editor listing puts the files under
the heading, and the dashboard shows the chip `[stale: refs]` (toggle it with `f` > `stale-refs`).

How a ref is read:

| Ref | Handling |
|---|---|
| `lua/a.lua`, `docs/x.md`, `lua\a.lua`, `dir/` | a path: backslashes become `/`, a trailing `:42` or `#anchor` is dropped |
| `lib.nvim@803de65`, `https://...`, `filetree.nvim:cheatsheet-paged` | skipped (a commit, a URL, an anchor: nothing on disk to date) |
| a task id like `ui.nvim/some-slug` | found as no path, so it is only counted as "found nowhere" |

A path is looked for, in order, in: the repo named like the task's area (`<repos>/<area>`, where
`<repos>` is the folder above the vault's checkout, `$REPOS_DIR` and `$REPOS_DIR/repos`), the nvim
config (`$NVIM_CONFIG_DIR`, optional), the vault, and the folder above the vault. The first place where it
exists wins. A file is dated by the commit date of the last commit touching it (a directory: the
newest file in it); a file git does not know (untracked, or a base that is no repository) uses its
mtime. Uncommitted edits are not seen.

Cost: one `git log` per repo and 100 paths, never one per task; a file is looked up once however
many tasks name it; at most `staleness.MAX_REFS` (1000) distinct files are checked per run (the
rest is reported). All git calls of a run share a time budget (`staleness.budget_ms` of `setup()`, 30 s):
once it is used up the remaining files are dated by their mtime. A missing repo, file or git only
produces a note on stderr / a notification, never an error; a path git refuses costs only its own
date (the call is halved until that path stands alone). A ref with `..` that leaves its repo
(`../lib.nvim/lua/x.lua`) is dated from the folder the file really lives in. `model.filter` looks
up only the tasks the other criteria kept, so `--status=doing --stale=refs` checks far fewer refs
than `--stale=refs` alone. Against the real vault: about 600 files in ~3.5 s.

## CI gate -- `tasks ci` / `scripts/tasks-ci.lua`

```sh
nvim --headless -u NONE -l scripts/tasks-ci.lua --vault=<vault>
```

Three steps, exit `0` only when all pass (`1` otherwise), a short summary at the end:

1. `check` -- every `error` finding fails (`--strict`: warnings too)
2. `index --check` -- no `ROADMAP/TASKS.md` missing, outdated or left over
3. `md_lint` -- `<vault>/TOOLS/scripts/md_lint.lua` over every generated `TASKS.md` (relative
   links, anchors, table columns; `$VAR/...` links when lsp.nvim is on `$REPOS_DIR` or in lazy's
   data folder). `--no-lint` skips it; a missing script fails the run, it is never skipped silently.
   `--md-lint=<file>` points at another copy. A linter that runs longer than 120 s
   (`ci.lint_timeout_ms` of `setup()`, `opts.timeout_ms`) is killed and the step fails with
   `timed out`; one killed by a signal fails as well (a signal reads as exit code 0 on POSIX).

A pipeline for a vault repo runs `scripts/tasks-ci.lua` with `TASKS_VAULT` set (checkout this plugin and `lib.nvim` next to it).

**Trust.** Step 3 *runs* `md_lint.lua` as Lua (`nvim --headless -u NONE -l <script> <files>`) with the rights of
whoever runs the pipeline. With the default path that script comes out of the vault itself, so a pipeline that
checks out a vault from a pull request or a fork runs the contributor's code. Run `ci` only on a vault whose
`TOOLS/scripts/md_lint.lua` you trust, or point `--md-lint=<file>` at a copy outside the vault (and use
`--no-lint` where neither holds).

## Headless CLI -- `scripts/tasks.lua`

For sessions without a running Neovim (rule R12) and for CI. One
implementation: the script only sets `runtimepath` (this plugin and
lib.nvim) and calls `tasks_nvim.cli`.

```sh
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing,decision
nvim --headless -u NONE -l scripts/tasks.lua new lib.nvim "Notify: unify channels" --kind=feature --prio=2 --tags=ui
nvim --headless -u NONE -l scripts/tasks.lua set lib.nvim/notify-unify-channels status=doing
nvim --headless -u NONE -l scripts/tasks.lua done lib.nvim/notify-unify-channels --done-in=lib.nvim@abc1234
nvim --headless -u NONE -l scripts/tasks.lua index --check
nvim --headless -u NONE -l scripts/tasks.lua check
```

| Command | Effect |
|---|---|
| `list [area] [--status=a,b] [--prio=1,2\|<=2] [--effort=S,M\|<=M] [--kind=k] [--category=c,d] [--severity=high,critical] [--tag=t] [--stale=N|refs] [--stale-refs] [--blocked] [--sort=default\|prio-effort\|severity] [--format=tsv\|ids]` | open tasks, sorted; `id status prio effort kind updated title`, tab-separated |
| `index [area] [--check]` | write / verify `ROADMAP/TASKS.md` (all areas without argument) |
| `new <area> <title> [--kind --prio --effort --tags=a,b --category=c,d --severity=s --refs=a,b --lang=de\|en --summary --slug --status] [--folder] [--no-index]` | create a task file (`--lang` picks the language of the body headings, default `de`; `--folder` a folder task) |
| `attach <area>/<slug> <file> [--name=n] [--no-index]` | copy a file to `<slug>/assets/` (a plain task becomes a folder task), print the Markdown link |
| `folderize <area>/<slug> [--no-index]` | turn a plain task file into a folder task |
| `set <area>/<slug> key=value ... [--no-index]` | change frontmatter; an empty value removes the key |
| `done <area>/<slug> [--done-in=text] [--date=YYYY-MM-DD] [--no-index]` | finish and move to `Backlog/` |
| `check [area]` | rule check |
| `ci [--strict] [--no-lint] [--md-lint=<file>]` | the CI gate: check + `index --check` + md_lint of the generated indexes (see above) |
| `template [--title --kind --prio --effort --tags --lang=de\|en]` | print the task template |
| `areas` | list the vault's areas |
| `export [--top=N] [--no-links]` | all-areas overview as Markdown on stdout (never written to a file) |

Global options (before or after the command): `--vault=<dir>`,
`--today=YYYY-MM-DD`; both need a value (an empty `--vault=`, say from an unset shell
variable, is a usage error, not "the default vault"). Exit codes: `0` success, `1` a finding
/ stale index in `--check` / a failed operation, `2` a usage error. Errors go to stderr.
Terminal control characters in what is printed (ESC, other C0 controls, DEL, a lone CR, the
8-bit C1 range) come out as `?`: a task title is read from a file anyone may have edited.
Tab and newline are the output format and stay.

The vault is `--vault=<dir>`, else `$TASKS_VAULT` (no built-in default path); `$TASKS_EXTRA_AREAS` names
extra areas. lib.nvim is looked up in `$LIB_NVIM_DIR`, `$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`,
`.deps/lib.nvim`, a sibling checkout, then lazy.nvim's data folder.

## Limits and what is refused

A vault is data that other people and tools write, so the engine is strict about what it will load:

- `fsio.read` loads a regular file of at most `fsio.MAX_READ_BYTES` (2 MiB); a directory, a FIFO, a
  `/dev/zero` symlink or a bigger file is `nil, err`. A task file like that is an invalid task (`unreadable`),
  not a stall. A Backlog README that cannot be read stops `done` instead of being treated as missing.
- A frontmatter line, a title or a summary is never matched with a pattern that backtracks on whitespace or
  backslashes; table cells are escaped in one linear pass (`fsio.md_cell`).
- Filter options with no value (`--status=`) and a `--today` that is no date are usage errors, not filters
  that match nothing.
- `done` never removes a finished copy it did not create, and re-reads the task right before removing the
  original; the dashboard re-reads a task before advancing `s` / `p`.

## Tests

Specs live in `TESTS/` and run against a temporary fixture vault, never
against the real one:

```sh
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua            # all
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua tasks_mutate   # one
```

One spec per module (`tasks_<module>_spec.lua`) plus the CLI and CI end-to-end specs; the shared helper is
`TESTS/harness.lua`, the fixture vault `TESTS/fixture.lua`.
