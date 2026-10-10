# Editor commands (`:Tasks`)

The commands for the open work of a task vault: one Markdown file per task in `<area>/ROADMAP/tasks/`, a
generated overview `<area>/ROADMAP/TASKS.md`, finished tasks in `<area>/Backlog/`. Format and rules:
[ENGINE.md](ENGINE.md); scenarios: [WORKFLOWS.md](WORKFLOWS.md). All rules live in the engine; this layer only
parses the command line, asks, notifies and opens windows. The same engine runs without an editor as
`nvim --headless -u NONE -l scripts/tasks.lua <command>`.

The grammar is **verb-first** (`:Tasks list my-area`): the composer routes over literal path segments and
has no dynamic first segment. An *area* is a folder of the vault holding `ROADMAP/` or `Backlog/` (plus the
`extra_areas` of `setup()`), which is why areas are read from the vault (argument type `TASK_AREA`).
`<Tab>` completes areas, task ids (`<area>/<slug>` of the *open* tasks,
type `TASK_ID`), the filter and `--to=` values and, for `task set`, every settable `key=`.

All mutating commands (`task new`, `task set`, `task done`, `tasks index`) regenerate
the area's `ROADMAP/TASKS.md` through the engine; it is never written by hand (rule
R7). The global overview `ALL/TASKS.md` is **never written** by any command:
`tasks all --to=file:<path>` produces it on demand (decision E2, not committed).

### `:Tasks list [<area>|all] [filters] [--to=] [--format=]`

Lists the open tasks, sorted by status (`doing`, `decision`, `blocked`, `open`,
`parked`), then prio, then area and slug. No area, or `all`, means every area. (The
lowercase word `all` is the keyword; `ALL` with capitals is the area of that name.)

| Flag | Meaning |
|---|---|
| `--status=a,b` | one or more of `doing decision blocked open parked` |
| `--prio=1,2` / `--prio=<=2` | exact prios, or "at most" |
| `--kind=a,b` | `feature task bug idea research` |
| `--category=a,b` | any of `bug security performance docs ruleset` (`bug` also finds every `kind: bug`; a tag spelled like a category counts) |
| `--effort=S,M` / `--effort=<=M` | the written effort (`XS S M L XL`, or days like `0.5d`; sizes are case-insensitive), or "this or smaller" (`<=S`, `<=M`, `<=1d`; sizes and days share one scale, a task without effort never matches) |
| `--severity=a,b` | any of `low medium high critical` (the optional `severity` of a bug / security task; a task without one never matches) |
| `--value=4,5` / `--value=>=4` | the written `value` (1-5, the expected benefit), or "this or more"; a task without a value never matches |
| `--actor=a,b` | any of `cdx me pair none`: who can do it. `me` also finds `status: decision` and the tag `needs-user` (derived, nothing to migrate); `none` finds the tasks nobody classified |
| `--tag=a,b` | any of these tags |
| `--stale=<days>` | not updated for at least that many days (no date counts as stale) |
| `--stale=refs` | a file named in the task's `refs:` changed on a later day than `updated` (git commit date, mtime as fallback); the heading names the changed files. Details in [ENGINE.md](ENGINE.md#--stalerefs----tasks-whose-referenced-files-changed) (section `--stale=refs`) |
| `--blocked` | status `blocked`, or a non-empty `blocked_by` |
| `--ready` / `--waiting` | the tasks that can be started now (nothing open blocks them; a `decision` counts: it waits for you, not for a task) / the tasks that wait on an open blocker. One definition for the plan, the dashboard, `next` and these flags, judged against every open task of the vault (a blocker in another area counts). The two exclude each other |
| `--unestimated` | missing the effort or the value |
| `--quick-win` | a quick win: value and effort at the thresholds of `setup({ quick_wins })` (default value 4+, effort S-). Shorthand for `--value=>=N --effort=<=X`, so it cannot be combined with `--value` or `--effort` (an error, never a silent pick) |
| `--sort=default` / `prio-effort` / `severity` / `frecency` / `roi` | the order (`roi`: highest `value / effort` first, tasks without both numbers after the ones with a figure, each group in the default order): `default` is status, prio, area, slug; `prio-effort` is status, prio, then effort ascending (important and small first, no effort last of its prio); `severity` is `critical` first, then `high`, `medium`, `low`, no severity last, each group in the default order; `frecency` is what the dashboard opened or changed most first (see below), the rest in the default order |
| `--to=` | where the list goes: `buffer` (default), `clipboard`, `qf`, `file:<path>`, `echo`, `mdview` (Markdown written to a temp file and shown in the browser by [mdview.nvim](https://github.com/StefanBartl/mdview.nvim); see [Browser preview](#browser-preview-mdview)) |
| `--format=md` / `--format=csv` | table (default) or CSV with the extra columns tags, blocked by, summary, path, severity, value, roi, actor; a `file:` target ending in `.csv` implies `csv`. A CSV cell that starts with `=`, `+`, `-`, `@` or a tab gets a leading `'`, so a title like `=HYPERLINK(...)` is text, not a formula, when the file is opened in a spreadsheet |

```vim
:Tasks list                                    " everything open, in a scratch buffer
:Tasks list lib.nvim --status=doing,decision
:Tasks list --status=decision --to=qf          " what is waiting for me, jump into the files
:Tasks list --stale=60 --to=clipboard
:Tasks list --status=open --effort=<=M --sort=prio-effort   " important and small first
:Tasks list --category=bug,security --sort=severity         " worst first
:Tasks list all --to=file:~/vault/ALL-TASKS.md
```

The command line splits at spaces, so a `--to=file:` path with a space needs a backslash before
each space (`--to=file:C:/my\ dir/tasks.csv`). A word a command has no use for is an error
(`unexpected argument: ...`), not silently ignored -- otherwise the export would go to a file named
after the part before the space.

The scratch buffer is plain Markdown (yank it, `:sort` it, search it) with a heading and
the active filter above the table. `qf` puts one entry per task into the quickfix list,
each jumping to the task file. Rendering and delivery are `lib.nvim.harvest` (`render`,
`emit`) and `lib.nvim.ui.list`. Nothing is delivered when no task matches; the command
says so instead.

### The dashboard (`:Tasks list [<area>|all]` without `--to=` / `--format=`)

An interactive `Snacks.picker` (source `tasks_nvim`):
one line per open task -- prio, status, effort, area, title, the `[severity]` of a bug /
security task and a `<- blocker` hint -- the task file as the preview, and a title with the
counts, the active filter chips and, when it is not the default, the sort order:

```
 Tasks (lib.nvim) · 41 open · 3 decision · 5 blocked  [status: open,doing] [prio: <=2] [sort: prio-effort]
```

| Key | Action |
|---|---|
| `<CR>` | open the file (all marked ones when there are marks) |
| `<Tab>` / `<S-Tab>` | mark / unmark (snacks' own multi-select; the marks are the target of `s p D e`) |
| `s` | advance the status of the marked (else the current) tasks: `doing` -> `decision` -> `blocked` -> `open` -> `parked` -> `doing` |
| `p` | advance the prio: none -> 1 -> 2 -> 3 -> none (3 -> none removes the key) |
| `D` | finish after **one** confirmation naming every task (engine `done`, moved to `Backlog/`) |
| `f` | set a filter chip: pick `status`, `prio`, `effort` (`XS`..`XL`, `<=S`, `<=M`), `kind`, `category`, `severity`, `value`, `actor`, `tag`, `blocked`, `unestimated`, `quick-win` (toggle: value and effort at the quick-win thresholds, shown as the one chip `[quick-win]`), `stale-refs` (toggle: shows the chip `[stale: refs]`),
`plan` and `phase` (the plans and stages in use), `readiness` (`ready` / `waiting`: the same cut as `list --ready` / `--waiting`, which the dashboard keeps when it was
opened with them) or "clear all", then a value (`(any)` clears one chip) |
| `gl` (input window `<M-l>`) | named lists: pick one to make it the view (its filter, sort and area), `Save the current filter and sort as a list ...` (asks for a name; replacing a saved list asks first), `Delete a saved list ...`. Lists of `setup()` and built-in lists cannot be deleted here |
| `o` | cycle the sort order: `default` -> `prio-effort` (small first within a prio) -> `severity` (critical first) -> `frecency` (most opened / changed first) -> `default`; a non-default order shows as `[sort: ...]` in the title |
| `e` | export the marked (else all shown) tasks: scratch buffer, clipboard, quickfix or a file, as Markdown or CSV, or "Preview in browser (mdview)" -- the `--to=` sinks |
| `v` | switch to the **stage view**: tasks grouped by stage ("Stage 1 · 5 tasks · not parallel"), what each waits for, tasks without plan, edge or dependants in an "Unsorted" block; `v` again returns to the list (marks and filter stay) |
| `P` | give the marked (else current) tasks a plan (an open plan file) and one of its stages: `plan:` / `phase:` in one batch |
| `J` / `K` | stage view: move the task down / up among its stage's tasks: `order` becomes a fraction between the two neighbours, nothing is renumbered. `order` only breaks ties behind status and prio, so the move shows among tasks of equal status and prio |
| `r` | rescan the vault now (the list also refreshes by itself, see "Live refresh"); keeps the cursor task and the marks |
| `gp` | preview the task file under the cursor in the browser through mdview.nvim ([Browser preview](#browser-preview-mdview)); the single-task menu of the plain fallback has "preview the file (mdview)" |
| `gb` / `gr` | the Backlog picker (`:Tasks folder <area> backlog`) / `ROADMAP/ROADMAP.md` of the area under the cursor |
| `g?` | key help float (any key closes it) |

The letters work in the list window. In the input window they would shadow the editing
commands (`s`, `p`, `D`, `e` in normal mode) and the typing in insert mode, so there the same
actions are Alt chords (normal and insert mode): `<M-s>` `<M-p>` `<M-d>` `<M-f>` `<M-o>` `<M-e>`
`<M-r>`, `<M-b>` (backlog), `<M-m>` (roadmap), `<M-v>` (preview), `<M-?>` (help). `s` and `p` are applied
at once, as **one batch**: every task advances from its own value, one `tasks.mutate.set`
per task without its own index write, then each touched area's `ROADMAP/TASKS.md` is
regenerated **once**, and one notification reports `changed / unchanged / failed`. The
picker stays open and rescans. `D`, `f`, `e`, `gb`, `gr` and `gp` ask something or open a window, and snacks
closes a picker whose window loses focus, so they close it first; `D` and `f` reopen it
afterwards (the marks are gone then), `e` does not when it delivered something.

The last filter and sort order are remembered between sessions (`lib.nvim.store.project`,
keyed by the vault, key `tasks/dashboard-filter`). A filter given on the command line
(`--status=...`) wins for that session and is not stored until it is changed with `f`; the
same goes for `--sort=` (the default order is "not given": the remembered one applies, `o`
cycles back to it). An empty result
stays open (`show_empty`), so a filter that matches nothing can be cleared with `f`.

**Backends.** `setup({ dashboard = { backend = ... } })`: `snacks` (snacks.nvim; letter keys in the list window),
`kit` (lib.nvim's own picker, **no snacks needed**: marks with `<Tab>`, highlighted rows, a file preview, the same
live refresh, the stage view, `P` and `J`/`K`; the prompt keeps the focus, so the keys are the Alt chords of
`keys.dashboard_input`, e.g. `<M-s>`, `<M-g>`, `<M-a>`), `select` (below) or `auto` (default): snacks when installed,
else kit.

Without a picker (`backend = "select"`) a `vim.ui.select` flow lists the same tasks; picking one opens a menu
(open the file, advance status / prio, finish, filter, next sort order, export the list,
Backlog, ROADMAP.md) for **that one task** -- no marks, no batch. It never raises.

**Live refresh.** While the dashboard is open it watches the folders its list is made of
(`ui/dash_watch.lua`, handles from `lib.nvim.fs.watch`): `<area>/ROADMAP/tasks` and each
folder-task folder in it, and `<area>/Backlog/FEATURES` and `Backlog/TASKS` where finished
tasks land -- the shown area, or every area for `all`. When a file changes (this Neovim,
another one, a Claude session, `git pull`) the list rescans by itself, after 250 ms of quiet
(a burst of events is one rescan). Cursor and marks are found again **by task id**, so they
stay on the same tasks even when a rescan moved rows around; filter chips and the sort order
are not touched. A rescan that finds the same list (files in the folder that are no tasks, a
file saved unchanged) redraws nothing. The dashboard's own batches (`s`, `p`) are not echoed:
their file events are muted and no second scan runs. Closing the picker (any way out,
including the `D` / `f` / `e` detours) stops every handle and timer; the reopened dashboard
starts its own. Only direct folders are watched (libuv's `recursive` flag does nothing on
Linux), so after every refresh (and after `r`) the handles are re-aimed: a folder task
created while open is watched from then on. An area that has no `ROADMAP/tasks/` yet is
watched at `ROADMAP/` until the folder appears (its first task is noticed, however the burst of
events ends: `lib.nvim.fs.watch` reports only the last file name of a burst). A whole new area is only noticed by `r` or by
reopening the dashboard (the vault root itself is not watched). Off with `setup({ dashboard = { watch = false } })` (or per call `open(v, { watch = false })`); the debounce
is `dashboard.debounce_ms` (default 250). If no
folder can be watched (handle limit, no `lib.nvim.fs.watch`) the dashboard says so once and
`r` stays the way to rescan. The plain `vim.ui.select` fallback has no live list.

**Frecency.** Opening a task (`<CR>`, or "open the file" in the fallback menu) or changing it
(`s` / `p`) counts as a visit: `tasks_nvim.frecency` keeps a decayed counter per task id --
each visit adds 1, the old count halves every 14 days (a task opened three times today
outranks one opened five times last month, one left alone fades out after a couple of
months). The file is `stdpath("state")/tasks/frecency.json` (`$TASKS_FRECENCY_FILE`
overrides it; at most 500 entries, the lowest scores go first; a corrupt file starts empty and
is kept as `frecency.json.bad`). `o` -> `frecency` (or `:Tasks list --sort=frecency`,
`tasks list --sort=frecency` in the CLI) lists the tasks with a score first, highest first,
and the rest in the default order. It is opt-in because it ignores the status/prio order the
default list is for: a `parked` task you keep opening is above an untouched `doing` one.

*Seam.* `require("tasks_nvim.ui.cmd").dashboard` decides what
happens: `nil` (the default) opens this dashboard, a function replaces it
(`view = { tasks, area, filter, sort, root }`), `false` gives the scratch buffer back.

### `:Tasks index [<area>] [--all] [--check]`

Without `--check`: (re)writes `ROADMAP/TASKS.md` of the area (all areas without an
argument or with `--all`), only where the content changed, and removes a stale one when
no task is open any more. With `--check`: writes nothing and runs the rule check of the
engine -- missing or invalid frontmatter, unknown status/kind/prio/effort, dangling
`blocked_by`, a stale or missing `TASKS.md`, a `done` task in `ROADMAP/`, an open one in
`Backlog/`, ... -- and reports the findings (a notification, or a scratch buffer when
there are more than ten). Errors are `ERROR` level, warnings `WARN`.

### `:Tasks new` -- the form (no arguments)

`:Tasks new` without an area opens a Markdown form in a split, as a Markdown
template:

```markdown
# New task
Area: lib.nvim
Title: Notify: unify the output channels

## kind (one)
- [ ] feature
- [x] task
...
## category (several)
- [ ] bug
- [x] docs
...
Tags: ui, notify
Refs: lua/foo/init.lua
```

The choice fields `kind`, `prio`, `effort`, `value`, `actor`, `category`, `severity` and `status` are bullet
lists whose values come from the engine (`tasks.model`); `category` takes several ticks, the
others one (ticking a bullet clears its siblings; leaving a list empty means "not set", and
`kind` / `status` then get the engine defaults `task` / `open`). `Area:` and `Title:` are
required; `Tags:` and `Refs:` are comma separated. `key=value` words on the command line
(`:Tasks new kind=bug category=docs,ruleset tags=a`) pre-tick the form. A hint line
lists the areas of the vault.

| Key (form buffer) | Does |
|---|---|
| `<Space>` / `<CR>` on a bullet | tick / untick it (`<CR>` on other lines is a plain `<CR>`) |
| `<C-s>` (normal and insert) | submit |
| `q` (normal) / `<C-q>` | cancel -- nothing is created |
| `g?` | help |

The tick is cascade.nvim's checkbox toggle (`require("cascade").toggle_checkbox`) when that
plugin is installed (a soft dependency, wrapped in `pcall`), with the result normalised to
the form's rules; without it, or when cascade does nothing on that line, the form flips the
bullet itself on the same keys.

Submitting checks the form: the problems are written at the top of the buffer as `!` lines
(they vanish on the next submit), and nothing is lost -- the buffer stays as it is. A valid
form asks **"Attach assets?"**: *Yes* creates a folder task (`<slug>/<slug>.md`, as
`--folder` does), makes `assets/` and opens the file explorer on it (filetree.nvim's
`:Filetree open` when installed, else Neovim's directory browser); *No* creates a plain task
file. The task is written by `tasks.mutate.new`, the one write path the CLI uses as well; an
error of the engine (a tag with a forbidden character, say) is shown in the form, which stays
open. Afterwards the form closes and the new file opens.

With an area (`task new <area> ...`) nothing changes: that is the old behaviour below.

Seams for tests and other front ends: `ui.cmd.form_open` (replaces the form buffer,
signature of `ui.form.open`) and `ui.cmd.explorer_open(dir)`.

### `:Tasks new <area> [title...] [kind= prio= effort= tags= status=]`

Besides these keys `value=`, `actor=`, `after=`, `order=`, `plan=` and `phase=` are accepted.

Creates `<area>/ROADMAP/tasks/<slug>.md` (slug from the title; a taken slug gets `-2`,
`-3`; a slug used in `Backlog/` counts as taken), regenerates the index and opens the
file. The words after the area are the title; one surrounding pair of `"` is dropped.

```vim
:Tasks new lib.nvim Notify: unify the output channels kind=feature prio=2 tags=ui
:Tasks new cascade.nvim "Cycle: count support" effort=S
:Tasks new lib.nvim                         " asks: title, kind, prio, effort
```

Without a title it asks for it -- through `ui.kit.form` (ui.nvim) when installed, else a
chain of `vim.ui.input` prompts. Fields already given as `key=value` are not asked again;
`<Esc>` on an optional field leaves it out, `<Esc>` on the title cancels. Tags may not
contain `, [ ] " ' #` (they sit in an inline list).

**With a range** (a visual selection, or `:5,10Tasks new <area>`) the task is *about those lines*: it gets a
`refs:` entry for them (`lua/a.lua:5`: file relative to the working directory, first line -- the staleness check
reads it) and, when you typed no title, the first non-blank selected line as the title. Without an area the form
opens with the same title and ref filled in.

```vim
:'<,'>Tasks new lib.nvim                    " title = first selected line, refs = this file:line
```

### `:Tasks set <id> key=value ...`

Changes frontmatter of an *open* task and sets `updated` -- but only when something really
changed (an identical value rewrites nothing). Settable: `title status kind prio effort tags
category severity value actor summary blocked_by after order plan phase refs rules done_in created`. A value may contain spaces
(`title=Fix the thing status=doing`: a word that does not start with a known `key=`
continues the value before it); an empty value removes the key (`kind=`). `status=done` is
refused: finishing moves the file, see `task done`. A buffer showing the file is reloaded
when it has no unsaved changes.

### `:Tasks attach <id> <file> [name=<file name>]` / `task folderize <id>`

A task may be a folder `tasks/<slug>/<slug>.md` that holds assets (concept section 12.2).
`attach` copies the file into `<slug>/assets/` -- a plain task file becomes a folder task
first -- and puts the Markdown link (`![name](assets/name)` for images) in the `+` register.
`name=` renames the copy; an asset that already exists is never replaced. Spaces in the file
name become hyphens, and names Windows treats as devices (`nul`, `con`, ...) are refused. The
file argument is resolved once, by the composer (`~`, `$VAR`, `%VAR%`) and never expanded a second time,
so `report[1].pdf` is that file, not `report1.pdf`, and a backtick in a name never reaches a shell.
A failed copy
leaves the task as it was (no half-made folder task). `folderize` converts a task without
attaching anything. Windows showing
the old task file follow it. `task new ... --folder` creates a folder task from the start.

### `:Tasks plan [<area>|all] [--for=<id>|--plan=<id>] [filters] [--ready] [--with-steps] [--format=md|tsv|ids] [--to=] [--force]`

The plan of the open tasks, computed from `blocked_by` alone (nothing new to write): what is **ready now**, the
**decisions by leverage** (how many tasks depend on each, transitively: the one that unlocks most comes first),
**stages** (every task in the earliest stage it can be in), the **critical path** (the longest chain, weighted by the
effort), an estimate line, and warnings (a cycle, a parked or unknown blocker). `--for=<id>` plans one task and
everything that has to be finished before it, across areas. The filters are those of `list`; `--ready` keeps only the
"ready now" part. A task that blocks a better one is ranked by that one's prio (`prio 3 -> 1 because of ...`); the
written prio is never changed. A cycle over `blocked_by` is reported with its members and left out of the stages, the
rest is still ordered. `--to=` is `buffer` (default), `clipboard`, `file:<path>`, `echo` or `mdview`.

More than `blocked_by` shapes the plan, all of it optional:

- **`after=[id, ...]`** is a soft edge ("should come after X"): it moves a task to a later stage, never makes it wait
  (it is still ready), never counts as leverage, and one that would close a cycle is dropped with a warning.
- **`order=2.5`** is a tie-breaker inside a stage, behind status and prio; a fraction slots a task in between without
  renumbering.
- Tasks of one stage that name the same file in `refs` are marked **`same-file`**: not parallel work, the order says
  which comes first. The stage says so.
- **`--plan=<id>`** draws the plan of a plan file (below): its tasks (`plan: <id>`), the stage order (`phase_order`),
  the goal, the status and the target in the head. **`--with-steps`** shows each task's `## Plan` steps and progress.
- **`--write=<file>`** replaces only the generated block of a hand-written document:
  `<!-- GENERATED:plan scope=<name> start -->` ... `<!-- GENERATED:plan end -->`. The rest of the file keeps its bytes
  and its line endings **line by line** (a document with mixed endings is not normalised); headings inside the block
  sit one level below the document's own, and the plan's summary is quoted (`> `), so a summary that reads like a marker
  cannot split the block. The block name is the plan's slug, the area, `for-<slug>` or `all` (`--scope=<name>` picks
  another); `--check` writes nothing and says whether the block is out of date. Blocks are not part of `check` or CI.
  The path is literal (`~`, `$VAR` are expanded, `[1]` is no wildcard) and a symlink is written **through**.
  - The start marker **records how the block was made**: the target (`plan=<id>`, `for=<id>`, `area=<name>`), the
    view (`ready=1`, `steps=1`) and the filters (`status=doing`, ...), e.g.
    `<!-- GENERATED:plan scope=release plan=lib.nvim/release ready=1 start -->`. The refresh after a `done`, and
    `--check`, read it back and build the same block. A plain marker you wrote by hand is rewritten with these
    attributes by the first `--write`; one without them is resolved by its name (an area, an open plan's slug or id,
    `for-<slug>`, `all`) and, when two plans or tasks share that slug, **skipped with the candidates named** instead of
    refreshed from a guess. A filter value that cannot live on a marker line (a blank, `--`) is refused.
  - Several blocks of one scope are all refreshed; a marker inside a fenced code block (a document that shows the
    syntax) is no marker. A scope with a folder that could not be read is not written (a degraded copy of the plan).
  - Refreshing reads the vault once for all the blocks of a document and reads the file again right before it
    writes: an edit made meanwhile is kept, and a document that keeps changing is given up on with a message.

### `:Tasks planfile <area> <title...> [--areas=a,b] [--phases=a,b,c] [--gate=hard] [--target=<id>] [--status=]`

Creates `<area>/ROADMAP/plans/<slug>.md`, the plan file of an undertaking: the goal, the boundaries, the definition of
done and the names of the stages. It holds **no task list**: tasks join with `plan=<area>/<slug> phase=<word>` (so two
tasks edited on two machines never collide on a list). `--areas` names the areas whose tasks belong (`check` warns
about another), `--phases` the stages in order (a later stage follows the earlier one in the plan), `--gate=hard` makes
that a real rule (a task of a stage waits until the earlier stage is finished, and `list --ready`, `next` and the plan
all see it), `--target` the task that means "done". When the last member task is finished the plan is finished too (see
`:Tasks done`). Headless: `plan-new`.

### `:Tasks next [<area>|all] [--n=3] [--actor=cdx|me|pair|none]`

What to start next: the best **ready** task and why, with a small dialog (`Not now` first, `Open <id>`, `Show another`).
The order is fixed: freed by the task you just finished, then the same area, then the vault; `doing` before `open`
before `decision`; the effective prio; the return on effort; the smaller effort; the id. Tasks written `cdx` are not
"your next task": they are listed apart ("an AI session could take ..."); `--actor=cdx` asks for that queue instead.
When there is nothing, the answer says which kind of nothing: **never** "all done" while work is only waiting
("Nothing can be started. Still open: 4 for you, 6 blocked, 3 parked.").

### `:Tasks estimate [<area>|all] [--for=<id>] [filters] [--walk]`

Sums of effort and value, always saying what they are made of: "22 d from 17 of 20 (range 14-31 d) · value 61 ·
roi 2.8 · me 8.5 d / cdx 13.5 d / unclear 3 -- estimate from the scale, not a promise". The range puts every size at
its low and its high end (a T-shirt size is not a number). The return on effort counts only the tasks that have both
numbers. Quick wins (value 4 or more, effort S or less) are named. `--walk` goes through the tasks that miss an effort
or a value, asks for them one by one (`Skip` first; `Stop`, and a dismissed dialog (Esc), end the walk and keep what was given)
and writes everything in one batch.

### Tasks lists

A **list** is a filter combination plus a sort order (and optionally one area) under a name. Its fields are the option
words of `:Tasks list`, written as strings: `status prio effort kind category severity value actor tag stale plan phase`,
the booleans `blocked unestimated stale_refs quick_win`, `readiness` (`ready` or `waiting`), `sort`, `area` and a one-line
`desc`. A list is checked by the same parser as the command line and a complaint names the list; an unknown key is an
error, never ignored.

Three sources, the later one wins by name:

1. **built in**: `quick-wins` (the quick-win definition, best return first), `small-and-important` (prio 1-2, effort S
   or less, startable now), `unestimated` (missing an effort or a value);
2. **saved**: a small state file (`stdpath("state")/tasks/lists.json`, or `$TASKS_LISTS_FILE`), written from the
   dashboard (`gl`) or by `tasks lists save`. A saved list may replace a built-in one;
3. **`setup({ lists = {...} })`**: your config, which cannot be changed or deleted from the dashboard or the CLI (edit
   the config). A saved list of the same name is shadowed and `:checkhealth` says so; a later `setup()` replaces the
   whole set.

```lua
require("tasks_nvim").setup({
  lists = {
    ["small-and-good"] = { effort = "<=S", value = ">=4", sort = "roi", desc = "worth doing in an hour" },
    ["my-bugs"] = { kind = "bug", actor = "me", status = "open,doing" },
  },
})
```

Running one: `:Tasks list --list=small-and-good` opens the dashboard on it; every option you type on top wins over the
list (`:Tasks list --list=my-bugs --prio=1`); `--list=` also works for `plan`, `estimate` and `quickwins`. `:Tasks lists`
opens a menu of all of them. A saved file that cannot be read is never written over (the dashboard menu says why), and a
single broken list in it is skipped and named, the rest stays.

Headless:

```sh
nvim --headless -u NONE -l scripts/tasks.lua lists                                  # name, source, what it selects
nvim --headless -u NONE -l scripts/tasks.lua lists save worth --effort='<=S' --value='>=4' --sort=roi --desc='worth an hour'
nvim --headless -u NONE -l scripts/tasks.lua lists show worth                       # the equivalent command line
nvim --headless -u NONE -l scripts/tasks.lua list @worth --prio=1                   # run it, with an override
nvim --headless -u NONE -l scripts/tasks.lua lists rename worth worthy
nvim --headless -u NONE -l scripts/tasks.lua lists delete worthy
```

### `:Tasks quickwins [<area>|all] [filters] [--to=] [--format=md|tsv|ids] [--by-actor] [--paths] [--report=<file>]`

The quick wins: a task with **both** numbers written, a value of at least `quick_wins.min_value` (default 4) and an
effort of at most `quick_wins.max_effort` (default `S`), best return on effort first. The report also names what the
rule cannot see, never as a quick win: the small tasks **without a value** ("one number away") and the high-value tasks
**without an effort**. By default only what can be picked up is looked at (`--status=open,doing,decision`; a parked or
blocked task is not offered, name it with `--status=`). `--value`, `--effort` and `--quick-win` do not exist here: they
are the definition. `--by-actor` splits the table into "for me", "pair", "for an AI session" and "unclassified",
`--paths` adds a column with the absolute path of each task file. `--to=` delivers it like `list` does (default: a scratch
buffer).

`--report=<file>` writes the Markdown to a file instead. The file starts with a generated-comment and is replaced by the
next run; a file at that path that this command did not write is **never** overwritten (an error). Headless:

```sh
nvim --headless -u NONE -l scripts/tasks.lua quickwins                       # tab-separated: id prio effort value roi actor title
nvim --headless -u NONE -l scripts/tasks.lua quickwins --format=md --by-actor --paths
nvim --headless -u NONE -l scripts/tasks.lua quickwins --min-value=3 --max-effort=M --report=quickwins.md
```

`--min-value` and `--max-effort` override the thresholds for one headless run. To keep a different definition, set
`setup({ quick_wins = { min_value = 3, max_effort = "M" } })`: every place that names quick wins (`:Tasks estimate`, the
plan header, `--quick-win`, this report) follows it.

### `:Tasks done <id> [done_in=...] [date=YYYY-MM-DD] [--yes]`

Rule R6, after a confirmation (`--yes` skips it): `status: done`, `done_in`; the file moves
to `Backlog/FEATURES/` (`feature`, `idea`, `research`) or `Backlog/TASKS/` (`task`, `bug`, no
kind) as `YYYY-MM-DD_<slug>.md`; its row goes on top of that section of `Backlog/README.md`;
the index is regenerated. On any failure the files involved are restored byte for byte.
Windows showing the open file follow it to the new path (an unchanged buffer is replaced,
one with unsaved changes is left alone and reported). Running it for an already finished
task says so and changes nothing.

Finishing sets a chain in motion, each step on its own (a failure after the finish never undoes it, it is a
message): the open steps of the task's own `## Plan` are **ticked** (a step marked `(dropped)` or `(entfaellt)` stays
open; the ticks are written with the finished copy, so the rollback covers them), a **plan file** whose last member this
was is finished (moved to `Backlog/FEATURES/`, "Plan x is done: 12 tasks, estimate 9.5 d, finished in 14 days"), and
the **generated blocks** of the documents named in `setup({ chain = { marker_docs = { ... } } })` are refreshed (only
those files; the block of a finished plan becomes its closing line). The headless CLI has no `setup`: it reads the same
list from `$TASKS_MARKER_DOCS` (comma separated). A plan counts as finished when no task with `plan: <id>` is left that
is not `done` -- valid or not: a mistyped `status:` keeps the plan open; a scan that could not read every folder closes
nothing and says so. One id namespace holds plans, tasks and Backlog files: a plan whose id an open task or a finished
item already has is not finished (and `plan-new` / `new` skip such a slug).

After the finish a small dialog names the tasks it freed and the next task to start (see `:Tasks next`); with
`setup({ next = { popup = false } })`, or without a UI, the same text is a plain message. A task that waited only on
this one and still says `status: blocked` is offered to be set to open (a question, never silently). In the
dashboard, `D` on several marked tasks shows ONE dialog after the whole stack.

### `:Tasks template [--to=clipboard|buffer|file:<path>] [--with-plan]`

The task file template (every field, visible placeholders; `--with-plan` adds the optional `## Plan` section with
checkbox steps) into the `+` register (default)
plus a notification. Without a working clipboard provider it opens in a buffer instead and
says so.

### `:Tasks open <id>`

Opens the file of an open task, or its finished copy in `Backlog/`.

### `:Tasks preview <id>`

The same file (an open task, else its finished copy) rendered in the browser by mdview.nvim:
see [Browser preview](#browser-preview-mdview).

### Browser preview (mdview)

`task preview <id>`, `tasks ... --to=mdview` and the dashboard keys (`gp`, and "Preview in
browser" in the `e` menu) put the rendered Markdown in the browser through
[mdview.nvim](https://github.com/StefanBartl/mdview.nvim). The wire is `ui/preview.lua`:

- **A task file** is opened as it is (`:edit`, then `:MDView start <file>`, the path handed over as
  one argument, so a space, `#`, `%` or `'` in it survives), so edits show up in the preview live.
  Nothing is copied and nothing is written to the vault.
- **A list export** (`--to=mdview`, `--format=md` only; `--format=csv` is refused) is rendered to
  Markdown, written to a temp file `tasks-<scope>.md` (`-2`, `-3` on a name clash; the scope is the
  area or `all`) in Neovim's per-session temp directory, and opened the same way. The buffer is
  unlisted. The file is deleted when its buffer is deleted, wiped or unloaded (a plain `:bdelete`
  included; a reload with `:edit!` keeps it; retrying a few times, Windows
  holds a file for a moment) and, for whatever is left, when Neovim quits; Neovim removes its
  temp directory on exit anyway. A temp location inside the vault is refused.
- **mdview.nvim is a soft dependency.** The check is "the `:MDView` command exists (a lazy stub
  counts) or `require("mdview")` works"; otherwise the command says
  `mdview.nvim is not available ...` and writes nothing. No `require` happens at load time.
- **Frontmatter:** a task file starts with flat YAML. mdview.nvim renders a leading frontmatter
  block as a two-column table (before that, it showed a rule plus one big heading made of the
  metadata lines -- that needs the renderer of mdview.nvim from 2026-10-04 on, i.e. a rebuilt
  or newly released WASM bundle). The generated `ROADMAP/TASKS.md` has no frontmatter and needs
  nothing.
- **Seams** (for specs and replacement): `ui.preview.probe` (is mdview there?),
  `ui.preview.opener` (open + start the preview, returns `ok, err`),
  `ui.preview.temp_root` (temp directory).

### `:Tasks folder <area> [folder] [--action=files|grep|smart] [--list] [--to=]`

A picker over the files of **one folder of one area**. `folder` is `tasks`
(`ROADMAP/tasks`), `roadmap` (`ROADMAP`), `backlog` (`Backlog`), `handover` (`handovers`),
`notes` (`NOTES`) or `all` (the whole area, the default). A folder the area does not have is
reported and no picker opens.

It calls `pickers.command.dispatch(action, { roots = { <folder> }, prompt = ... }, engine)` of
[pickers.nvim](https://github.com/StefanBartl/pickers.nvim) when that plugin is installed, so the configured
picker engine is used; `--action=grep|smart` searches file contents. `--list` (or `--to=`) delivers the list of
files, relative to the folder, instead of opening a picker.

**Limitation and fallback.** A pickers.nvim *collection* cannot express "one area, one
subfolder" (a collection offers "pick one subfolder of this directory"), so `open` does not
use one. Without pickers.nvim it falls back to a plain `vim.ui.select` over the folder's
`*.md` files: no content search, and `--action=grep|smart` is answered with that hint.
Full-text search over the whole vault is a job for your picker's own grep on the vault folder.
