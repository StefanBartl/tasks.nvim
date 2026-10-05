> Moved here from the author's Neovim config (where the same routes are mounted under `:MyPlugins tasks | task | open`;
> `routes.routes()` in `tasks_nvim.ui.routes` builds both grammars). In this plugin the verbs are flat:
> `:Tasks list`, `index`, `new`, `set`, `done`, `attach`, `folderize`, `template`, `open <id>`, `preview <id>`,
> `folder <area> ...`. Paths that name the author's vault layout (`$REPOS_DIR/WKDBooks/...`) are examples only:
> the vault is whatever `setup({ vault = ... })` or `$TASKS_VAULT` says.

# Editor commands (`:Tasks`)

The commands for the open work of the wkdbook vault
(`$REPOS_DIR/WKDBooks/Development/wkdbook-myplugins`): one Markdown file per task
in `<area>/ROADMAP/tasks/`, a generated overview `<area>/ROADMAP/TASKS.md`, finished
tasks in `<area>/Backlog/`. Format, rules R1-R12 and reasoning:
`wkdbook-myplugins/ALL/Task-System-Konzept.md`. All rules live in the engine, the plugin `tasks.nvim`
(`docs/ENGINE.md` in its repo); this layer only parses the command line,
asks, notifies and opens windows. The same engine runs without an editor as
`nvim --headless -u NONE -l scripts/tasks.lua <command>` (rule R12).

The grammar is **verb-first** (`:Tasks list cascade.nvim`, not
`:MyPlugins cascade.nvim tasks`): the composer routes over literal path segments and
has no dynamic first segment. An *area* is a folder of the vault holding `ROADMAP/` or
`Backlog/`, plus `ALL`, `nvim-config`, `docmap-desktop`, `migrate.nvim` -- which is
why areas are read from the vault (argument type `TASK_AREA`) and not taken from the
plugin list. `<Tab>` completes areas, task ids (`<area>/<slug>` of the *open* tasks,
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
| `--tag=a,b` | any of these tags |
| `--stale=<days>` | not updated for at least that many days (no date counts as stale) |
| `--stale=refs` | a file named in the task's `refs:` changed on a later day than `updated` (git commit date, mtime as fallback); the heading names the changed files. Details in [`lua/tasks/README.md`](../../../tasks/README.md) (section `--stale=refs`) |
| `--blocked` | status `blocked`, or a non-empty `blocked_by` |
| `--sort=default` / `prio-effort` / `severity` / `frecency` | the order: `default` is status, prio, area, slug; `prio-effort` is status, prio, then effort ascending (important and small first, no effort last of its prio); `severity` is `critical` first, then `high`, `medium`, `low`, no severity last, each group in the default order; `frecency` is what the dashboard opened or changed most first (see below), the rest in the default order |
| `--to=` | where the list goes: `buffer` (default), `clipboard`, `qf`, `file:<path>`, `echo`, `mdview` (Markdown written to a temp file and shown in the browser by [mdview.nvim](https://github.com/StefanBartl/mdview.nvim); see [Browser preview](#browser-preview-mdview)) |
| `--format=md` / `--format=csv` | table (default) or CSV with the extra columns tags, blocked by, summary, path, severity; a `file:` target ending in `.csv` implies `csv`. A CSV cell that starts with `=`, `+`, `-`, `@` or a tab gets a leading `'`, so a title like `=HYPERLINK(...)` is text, not a formula, when the file is opened in a spreadsheet |

```vim
:Tasks list                                    " everything open, in a scratch buffer
:Tasks list lib.nvim --status=doing,decision
:Tasks list --status=decision --to=qf          " what is waiting for me, jump into the files
:Tasks list --stale=60 --to=clipboard
:Tasks list --status=open --effort=<=M --sort=prio-effort   " important and small first
:Tasks list --category=bug,security --sort=severity         " worst first
:Tasks list all --to=file:$REPOS_DIR/WKDBooks/Development/wkdbook-myplugins/ALL/TASKS.md
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

An interactive `Snacks.picker` (source `wkdbook_tasks`, the engine `picker.lua` uses):
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
| `f` | set a filter chip: pick `status`, `prio`, `effort` (`XS`..`XL`, `<=S`, `<=M`), `kind`, `category`, `severity`, `tag`, `blocked`, `stale-refs` (toggle: shows the chip `[stale: refs]`) or "clear all", then a value (`(any)` clears one chip) |
| `o` | cycle the sort order: `default` -> `prio-effort` (small first within a prio) -> `severity` (critical first) -> `frecency` (most opened / changed first) -> `default`; a non-default order shows as `[sort: ...]` in the title |
| `e` | export the marked (else all shown) tasks: scratch buffer, clipboard, quickfix or a file, as Markdown or CSV, or "Preview in browser (mdview)" -- the `--to=` sinks |
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

Without snacks.nvim a `vim.ui.select` flow lists the same tasks; picking one opens a menu
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
(`s` / `p`) counts as a visit: `tasks/frecency.lua` keeps a decayed counter per task id --
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

`:Tasks new` without an area opens a Markdown form in a split, in the manner of
`:Case new` of casedesk.nvim:

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
Refs: lua/lib/nvim/notify.lua
```

The choice fields `kind`, `prio`, `effort`, `category`, `severity` and `status` are bullet
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

### `:Tasks set <id> key=value ...`

Changes frontmatter of an *open* task and sets `updated` -- but only when something really
changed (an identical value rewrites nothing). Settable: `title status kind prio effort tags
category severity summary blocked_by refs rules done_in created`. A value may contain spaces
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

### `:Tasks done <id> [done_in=...] [date=YYYY-MM-DD] [--yes]`

Rule R6, after a confirmation (`--yes` skips it): `status: done`, `done_in`; the file moves
to `Backlog/FEATURES/` (`feature`, `idea`, `research`) or `Backlog/TASKS/` (`task`, `bug`, no
kind) as `YYYY-MM-DD_<slug>.md`; its row goes on top of that section of `Backlog/README.md`;
the index is regenerated. On any failure the files involved are restored byte for byte.
Windows showing the open file follow it to the new path (an unchanged buffer is replaced,
one with unsaved changes is left alone and reported). Running it for an already finished
task says so and changes nothing.

### `:Tasks template [--to=clipboard|buffer|file:<path>]`

The task file template (every field, visible placeholders) into the `+` register (default)
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
[mdview.nvim](https://github.com/StefanBartl/mdview.nvim). The wire is `tasks_preview.lua`:

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
- **Seams** (for specs and replacement): `tasks_preview.probe` (is mdview there?),
  `tasks_preview.opener` (open + start the preview, returns `ok, err`),
  `tasks_preview.temp_root` (temp directory).

### `:Tasks folder <area> [folder] [--action=files|grep|smart] [--list] [--to=]`

A picker over the files of **one folder of one area**. `folder` is `tasks`
(`ROADMAP/tasks`), `roadmap` (`ROADMAP`), `backlog` (`Backlog`), `handover` (`handovers`),
`notes` (`NOTES`) or `all` (the whole area, the default). A folder the area does not have is
reported and no picker opens.

It calls `pickers.command.dispatch(action, { roots = { <folder> }, prompt = ... }, engine)`
of [pickers.nvim](https://github.com/StefanBartl/pickers.nvim) -- the entry every `:Pickers`
action goes through, so `:PickersRepeat` replays it and the configured engine (snacks here)
is used; `--action=grep|smart` searches file contents. `--list` (or `--to=`) delivers the
list of files, relative to the folder, instead of opening a picker.

**Limitation and fallback.** A pickers.nvim *collection* cannot express "one area, one
subfolder" (a collection offers "pick one subfolder of this directory"), so `open` does not
use one. Without pickers.nvim it falls back to a plain `vim.ui.select` over the folder's
`*.md` files: no content search, and `--action=grep|smart` is answered with that hint.
Ad-hoc full-text search over the whole vault is the `plugins_book` collection in
`lua/plugins/personal/specs/navigate.lua` (`:Pickers plugins_book files|grep|smart`, `<leader>pbs/pbg`);
a second collection `vault` was removed as a duplicate (it also could not reach `ALL`).
