# Using the vault in Obsidian

A task vault is plain Markdown with flat YAML frontmatter, so Obsidian can open it as it is: no plugin, no export,
no second copy. This page says what Obsidian sees, gives a Bases view and a Dataview query for the open tasks, and
lists the few rules that keep Obsidian and `tasks.nvim` from stepping on each other.

Short version: **edit fields and text in Obsidian as you like; finish, move and rename tasks only with `:Tasks` or
the CLI.**

## Table of contents

- [Open the vault](#open-the-vault)
- [What Obsidian sees](#what-obsidian-sees)
- [A Bases view: open tasks by priority](#a-bases-view-open-tasks-by-priority)
- [A Dataview query](#a-dataview-query)
- [Rules for editing in Obsidian](#rules-for-editing-in-obsidian)
- [Wikilinks between tasks](#wikilinks-between-tasks)
- [What is not there yet](#what-is-not-there-yet)

## Open the vault

1. In Obsidian choose **Open folder as vault** and pick the vault root (the folder you pass as
   `setup({ vault = ... })` or `$TASKS_VAULT`), not a single area.
2. Obsidian creates `.obsidian/` in that folder. `tasks.nvim` never treats it as an area (an area is a folder that
   holds `ROADMAP/` or `Backlog/`), and `check` ignores it. If the vault is a git repository, ignore at least
   `.obsidian/workspace*.json` (they change on every click); whether the rest of `.obsidian/` is committed is up to
   you.
3. Recommended settings (**Settings → Files and links**):
   - **Automatically update internal links**: off, or at least know that it rewrites the links in the generated
     index (see [Rules](#rules-for-editing-in-obsidian)).
   - **Default location for new notes**: anything outside `ROADMAP/tasks/` (new tasks are made with `:Tasks new`).

## What Obsidian sees

| In the vault | In Obsidian |
| --- | --- |
| `<area>/ROADMAP/tasks/<slug>.md`, `<area>/ROADMAP/tasks/<slug>/<slug>.md` (folder task) | one note per open task; the frontmatter appears as **Properties** |
| `<area>/ROADMAP/TASKS.md` | the generated index of the area: a table with one Markdown link per task |
| `<area>/ROADMAP/plans/*.md` | plan files (also notes with properties) |
| `<area>/Backlog/TASKS/`, `<area>/Backlog/FEATURES/` | finished tasks as `YYYY-MM-DD_<slug>.md`, with `status: done` |
| `<area>/Backlog/README.md` | one row per finished task |
| `.<name>.lock` next to a file | a short-lived lock file of a `tasks.nvim` writer; hidden, Obsidian does not list it |

**Properties.** `title`, `status`, `kind`, `prio`, `effort`, `value`, `actor`, `tags`, `blocked_by`, `after`, `refs`,
`created`, `updated` and the rest ([docs/ENGINE.md](ENGINE.md)) are ordinary properties. Obsidian infers a type per
name across the vault: `prio` and `value` are numbers, `created`, `updated` and `remind` are dates, `effort` is
text (it holds both `S` and `0.5d`), `tags`, `blocked_by`, `after` and `refs` are lists. `tasks.nvim` writes lists
inline (`tags: [obsidian, docs]`); Obsidian's Properties editor writes them as YAML block lists
(`tags:` followed by `  - obsidian`). Both forms are read, and `:Tasks set` keeps the form a list already has.

**Links of the index.** `ROADMAP/TASKS.md` links each task as a relative Markdown link, `[title](tasks/<slug>.md)`.
Obsidian resolves relative Markdown links against the folder of the note, so every row opens its task, and the
task shows the index under **Backlinks**. A task id (`<area>/<slug>`) in `blocked_by` or `after` is plain text,
not a link; written as a wikilink (`"[[<slug>]]"`) it is one (see [Wikilinks between tasks](#wikilinks-between-tasks)).

## A Bases view: open tasks by priority

[Bases](https://help.obsidian.md/bases) is a core plugin (Obsidian 1.9 or newer; enable it under **Settings → Core
plugins**). Save this as `Open tasks.base` anywhere in the vault, for example in the vault root:

```yaml
filters:
  and:
    - file.ext == "md"
    - file.path.contains("/ROADMAP/tasks/")
    - status != "done"
views:
  - type: table
    name: Open by priority
    order:
      - file.name
      - title
      - status
      - prio
      - effort
      - actor
      - blocked_by
    sort:
      - property: prio
        direction: ASC
      - property: file.name
        direction: ASC
  - type: table
    name: Ready to start
    filters:
      and:
        - status == "open"
        - actor != "me"
    order:
      - file.name
      - title
      - prio
      - effort
    sort:
      - property: prio
        direction: ASC
```

- `file.path.contains("/ROADMAP/tasks/")` takes the open tasks of every area, folder tasks included, and leaves out
  the index (`ROADMAP/TASKS.md`), the plan files and the Backlog. For one area use
  `file.inFolder("<area>/ROADMAP/tasks")` instead.
- `status != "done"` is a safety net: a task with `status: done` in `ROADMAP/tasks/` is a `check` error
  (`done-in-roadmap`), it should not be there at all.
- "Ready to start" here means only `status: open` and not marked for you. The real answer weighs blockers, plans and
  stages; ask `:Tasks next` or `:Tasks list --ready` for it.

## A Dataview query

With the community plugin [Dataview](https://blacksmithgu.github.io/obsidian-dataview/) installed, put this block
into any note:

````markdown
```dataview
TABLE title, status, prio, effort, actor, blocked_by
FROM ""
WHERE contains(file.folder, "/ROADMAP/tasks") AND status != "done" AND status != "parked"
SORT prio ASC, file.name ASC
```
````

`FROM ""` reads the whole vault; `FROM "<area>/ROADMAP/tasks"` limits it to one area and is faster on a big vault.
`file.folder` of a folder task is `<area>/ROADMAP/tasks/<slug>`, so it is included by the same `contains`.

Both recipes sort by the written `prio`; a task without `prio` sorts where the plugin puts empty values. The
ranking of `tasks.nvim` (effective priority, leverage, critical path) is not in the files and therefore not in
Obsidian: use `:Tasks plan` / `:Tasks next`, or `scripts/tasks.lua plan`, for that.

## Rules for editing in Obsidian

**Allowed: edit fields and text.** Change `status`, `prio`, `effort`, `tags`, `blocked_by`, ... in the Properties
editor or in the source, write notes, tick acceptance boxes. `tasks.nvim` reads the files on its next call; run
`:Tasks index` (or any command that changes a task, which rewrites the index anyway) to bring
`ROADMAP/TASKS.md` up to date. `check` reports `index-stale` until then, which is a hint, not damage.

**Only with `:Tasks` or the CLI: finish, move, rename.**

- **Finishing** is more than `status: done`. `:Tasks done` (CLI `done <id>`) moves the file to
  `Backlog/TASKS/` or `Backlog/FEATURES/` as `YYYY-MM-DD_<slug>.md`, adds the row to `Backlog/README.md`, ticks
  plan steps, closes a finished plan and rewrites the index, all or nothing. Setting `status: done` in Obsidian does
  none of that and leaves a `done-in-roadmap` error.
- **Moving** a file in Obsidian (drag and drop into another folder or area) changes its id. Every `blocked_by` and
  `after` that named the old id now points nowhere (`blocked-by-dangling`, `after-dangling`), and a file dropped
  into `Backlog/` without `status: done` is `open-in-backlog`. Moving a task to another area is the operation
  `move_area` of the engine (the app uses it), which rewrites the references with it.
- **Renaming** a file changes the slug, and with it the id, in the same way. There is no rename verb: if you must,
  rename it, fix the `blocked_by` / `after` entries that named the old id, then run `check` and `:Tasks index`.
- **New tasks** belong to `:Tasks new` (or the CLI `new`): it picks the slug, writes the template and `created`.
  A note made by hand in `ROADMAP/tasks/` works too, as long as it has a kebab-case file name and at least `title`
  and `status`.

**`updated` is not kept by Obsidian.** Every `:Tasks set`, `tick_step` or note added through `tasks.nvim` sets
`updated` to today; an edit in Obsidian does not. `--stale=60` measures from `updated` (or `created`), so a task
you work on only in Obsidian looks stale, and `--stale=refs` compares the `refs` files against an old date. Set
`updated` by hand in the Properties editor when it matters, or make the change through `:Tasks set`.

**Saving at the same time.** `tasks.nvim` writes under a lock (`.<name>.lock` next to the file) and checks the text
it read under that lock, so two `tasks.nvim` writers (the dashboard and an agent's CLI) never drop each other's
change. Obsidian does not take that lock and saves a note a moment after each keystroke. So:

- a `tasks.nvim` write that lands while you type in the same note in Obsidian can be overwritten by Obsidian's next
  save, or Obsidian reloads the note under your cursor;
- `:Tasks done` stops and changes nothing when the file changed while it ran, so a save from Obsidian at that moment
  makes it fail safely; run it again.

Stop typing in a note (or close it) before a command writes the same task.

**The Tasks plugin.** The community plugin "Tasks" treats every `- [ ]` line as a task of its own. The acceptance
boxes and the `## Plan` steps of every task file then show up in its queries as separate tasks, and the plugin may
append its own markers (`✅ 2026-10-17`) when you tick one there. Either set a **global task filter** in its settings
(for example `#todo`, so only lines with that tag count) or exclude the vault folders in your queries
(`path does not include ROADMAP/tasks`). Ticking a box as a plain checkbox in the editor is fine.

**The Kanban plugin.** Do not use the community plugin "Kanban" on these files: it keeps a board in its own Markdown
format (a note of lists of cards with `kanban-plugin` frontmatter) and does not read task files as cards. A board
of the open tasks by status is the board of the `tasks.nvim` app, or a Bases table grouped by `status`.

## Wikilinks between tasks

`blocked_by`, `after` and `plan` take Obsidian wikilinks as well as ids, so the graph and the backlinks show which task
waits on which. Write them in quotes, as the Properties editor does (`blocked_by: "[[x]]"` unquoted is a nested YAML
list and the file is `frontmatter-invalid`):

```yaml
blocked_by:
  - "[[fs-watch-meldet-fehler]]"                 # the one task of that slug, in any area
  - "[[lib.nvim/frontmatter-block-lists|Lists]]" # an id, with an alias
after: "[[lib.nvim/ROADMAP/tasks/old-task]]"      # the vault path (what Obsidian writes when a name is not unique)
plan: "[[desktop-ui]]"                            # a plan file
```

- **Read**: every form is the id it names; a heading (`#...`) and an alias (`|...`) are ignored, `.md` and the date
  prefix of a finished file (`2026-10-01_<slug>`) too. `plan`, `next`, `estimate`, `list --ready` and the generated
  index are exactly what plain ids give.
- **A bare `[[<slug>]]`** must name one task or plan of the whole vault. A slug used in several areas is
  `wikilink-ambiguous` in `check` (the candidates are named), one that exists nowhere `wikilink-dangling`; the task
  then waits as on a blocker that does not exist. Give such a link the area (`[[<area>/<slug>]]`) or the path. A new
  task of the same slug in another area makes an old `[[<slug>]]` ambiguous: `check` says so.
- **Write**: `setup({ links = "wikilink" })` (headless CLI: `TASKS_LINKS=wikilink`) makes `:Tasks set`, `new`, the
  dashboard's assign (`P`) and a move to another area write new references as `"[[<slug>]]"`, or, when the slug is
  in several areas, as the vault path with the id as alias (`"[[<area>/ROADMAP/tasks/<slug>|<area>/<slug>]]"`), which
  Obsidian resolves too. The default `plain` writes ids. A reference a file already holds keeps its form in both
  modes, and a value you type as a wikilink is written as typed.
- **Plan files**: the `target` of a plan file (`target: "[[<slug>]]"`) takes the same forms and is read as its id
  (`check`: `wikilink-dangling` / `wikilink-ambiguous` there too). `plan-new --target=[[<slug>]]` writes it as typed,
  an id follows `links`; a move rewrites a target that named the old id and keeps a bare `[[<slug>]]`, and `new`
  names a plan whose `[[<slug>]]` target the new slug makes ambiguous.
- **Finishing** moves the file to `Backlog/` under a date prefix: Obsidian then shows `[[<slug>]]` to the finished
  task as unresolved, `tasks.nvim` still reads it as the finished id. Wikilinks in `refs` (file paths) and in the
  generated index are not part of this.

## What is not there yet

- **YAML block lists** in the frontmatter are read and kept since `lib.nvim@9b7a7f3`; older versions of `lib.nvim`
  report such a file as `frontmatter-invalid`. Update `lib.nvim` if `check` does that after an edit in Obsidian.
- Opening a task in Obsidian from Neovim (`obsidian://open`) is not part of `tasks.nvim`.
