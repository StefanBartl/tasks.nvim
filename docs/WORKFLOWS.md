# Workflows and use cases

How tasks.nvim is meant to be used, one scenario at a time. The reference documents say *what* every command
does ([COMMANDS.md](COMMANDS.md), [ENGINE.md](ENGINE.md), [BINDINGS.md](BINDINGS.md)); this one says *when you
reach for it* and what happens around it.

Every scenario carries a tag:

| Tag | Meaning |
| --- | --- |
| **works today** | built, covered by specs |
| **planned** | designed, not built yet; the text says what to do instead until then |

## Contents

- [The idea in four sentences](#the-idea-in-four-sentences)
- [Vocabulary](#vocabulary)
- [Scenarios that work today](#scenarios-that-work-today)
- [Planned scenarios](#planned-scenarios)
- [Which command for which intention](#which-command-for-which-intention)
- [What goes wrong, and how you notice](#what-goes-wrong-and-how-you-notice)

## The idea in four sentences

1. A task is **one Markdown file** with a few lines of frontmatter; nothing lives in a database.
2. **Capturing is one call with a title**, always: no required field, no question, no plan.
3. The **overview per area (`ROADMAP/TASKS.md`) is generated**, never edited; finished tasks move to `Backlog/`.
4. The same engine answers in the editor (`:Tasks <verb>`, a dashboard) and without an editor
   (`scripts/tasks.lua`, for scripts, CI and AI sessions), so both always agree.

## Vocabulary

| Word | Meaning |
| --- | --- |
| **vault** | the folder that holds the areas (`setup({ vault = ... })` or `$TASKS_VAULT`) |
| **area** | one project inside the vault: `<vault>/<area>/ROADMAP/tasks/*.md` (open) and `.../Backlog/` (done) |
| **id** | `<area>/<slug>`, the same everywhere (commands, `blocked_by`, exports) |
| **status** | `doing`, `decision` (waits for you), `blocked`, `open`, `parked`; `done` only in `Backlog/` |
| **folder task** | `tasks/<slug>/<slug>.md` that can hold `assets/` (screenshots, logs) |

## Scenarios that work today

### 1. Capture something in two minutes — works today

An idea, a bug, a "this still has to happen". No planning.

```vim
:Tasks new my-area "Reply check reports a doubled greeting"
```

With a few attributes, without an editor:

```sh
nvim --headless -u NONE -l scripts/tasks.lua new my-area "Reply check reports a doubled greeting" --kind=bug --prio=2
```

`:Tasks new` without arguments opens a small Markdown form instead: tick the kind, prio, effort, categories and
status, type area and title, `<C-s>` submits and asks whether the task should get an `assets/` folder. The new file
opens; the area index is regenerated. Nothing else is asked, now or later.

### 2. Capture ten things after a meeting, sort later — works today

Create every point as its own task (title only is fine). Do **not** decide the order while capturing. Later, in one
quiet moment, read the list and add structure where it matters:

```vim
:Tasks list my-area --status=open --sort=prio-effort
:Tasks set my-area/some-slug prio=2 effort=S tags=ui,docs
```

`set` changes only the keys you name, keeps everything else byte for byte, and bumps `updated`. An empty value
(`effort=`) removes the key.

### 3. "What do I do now?" — works today (approximately)

```vim
:Tasks list --status=doing,decision
:Tasks list my-area --status=open --effort=<=M --sort=prio-effort
```

The first command is "what is in flight and what waits for me". The second is "important and small first".
`--sort=prio-effort` knows nothing about dependencies, so it can show a task that waits for another one (see 4);
the dashboard shows the blocker next to such a task (`←`). A command that answers "what is *ready*" is planned.

### 4. One task must not start before another — works today

```vim
:Tasks set my-area/send-via-gateway blocked_by=[my-area/gateway-config, other-area/policy-decision]
```

Ids may point into other areas. Set `status=blocked` while it applies. `:Tasks list --blocked` shows everything
with an open blocker; `check` reports a blocker that does not exist, points at itself or is already finished.
A decision you owe is a task with `status=decision`: it stays on top of the list until you answer, and anything
that names it in `blocked_by` waits for it.

### 5. Work on a task — works today

```vim
:Tasks set my-area/some-slug status=doing
:Tasks open my-area/some-slug
```

Write what you learn into the task file: a `refs:` list names the files the task is about
(`refs: [lua/foo/init.lua, docs/design.md]`), and the acceptance section says when it is done. Add `rules: [LUA-45]`
and `category: [ruleset]` when the task brings code in line with a rule set.

### 6. Finish a task — works today

```vim
:Tasks done my-area/some-slug done_in=my-repo@abc1234
```

After a confirmation (`--yes` skips it) the task becomes `status: done`, moves to
`Backlog/TASKS/` or `Backlog/FEATURES/` as `YYYY-MM-DD_<slug>.md` (by `kind`), gets a row in `Backlog/README.md`
and disappears from the index. Everything is snapshotted first; if any step fails the files come back
byte for byte, and what cannot be undone is named in the message. Running it again says "already finished".
If the file changed while `done` ran (you saved in the editor), it stops and changes nothing.

### 7. A task with screenshots and logs — works today

```vim
:Tasks new my-area "Crash on startup" --folder
:Tasks attach my-area/crash-on-startup E:/shots/crash.png
```

The attach command copies the file into `assets/`, turns a plain task into a folder task when needed, and puts the
Markdown link into the `+` register: paste it into the task body. `done` moves the whole folder. A link to a file
that is not there is reported by `check` as `asset-dangling`.

### 8. Keep the list honest — works today

| Question | Command |
| --- | --- |
| Is any task file malformed, a blocker dangling, an index outdated? | `:Tasks index --check`, headless: `scripts/tasks.lua check` |
| Which tasks have not been touched for a while? | `:Tasks list --stale=60` |
| Which tasks talk about files that changed since the task was last updated? | `:Tasks list --stale=refs` |
| Rewrite the generated overviews | `:Tasks index` (also done by every command that changes a task) |

`--stale=refs` dates every `refs:` path by its last commit (file modification time when git does not know it) and
lists the task with the file that changed: the signal to re-read a task before acting on it.

### 9. A dashboard session — works today

`:Tasks list [area]` without `--to=` opens the dashboard (needs snacks.nvim; without it a plain selection list).

1. Type to search; `f` sets a filter chip (status, prio, effort, kind, category, severity, tag, blocked,
   stale-refs); `o` cycles the sort (default, prio-effort, severity, frecency).
2. `<Tab>` marks tasks. `s` advances the status of the marked tasks (or the current one), `p` the prio, `D` finishes
   them after **one** confirmation. A task that someone else changed since the list was drawn is skipped with a
   message instead of being overwritten.
3. `<CR>` opens the file, `gp` previews it in the browser (mdview.nvim), `gb` / `gr` open the area's Backlog and
   ROADMAP, `e` exports the marked tasks.
4. The list refreshes by itself when a task file changes on disk; cursor and marks stay on the same tasks.

The filter and sort you leave are remembered for the next time; a `--sort=` on the command line wins over it.

### 10. Hand a list to somebody else — works today

```vim
:Tasks list my-area --status=open --to=clipboard
:Tasks list --to=file:~/tasks.csv --format=csv
:Tasks list my-area --to=mdview
:Tasks list --status=decision --to=qf
```

Targets: `buffer` (default), `clipboard`, `qf` (one quickfix entry per task, each jumping to the file),
`file:<path>`, `echo`, `mdview` (a browser preview). An existing file is never overwritten unless you pass
`--force` (the dashboard asks instead). CSV cells that start like a formula are defused.

### 11. An AI session or a script without an editor — works today

```sh
export TASKS_VAULT=~/vault
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing,decision
nvim --headless -u NONE -l scripts/tasks.lua set my-area/some-slug status=doing
nvim --headless -u NONE -l scripts/tasks.lua done my-area/some-slug --done-in=my-repo@abc1234
nvim --headless -u NONE -l scripts/tasks.lua check
```

Same rules, same files, tab-separated output, exit codes `0` / `1` (finding or failed operation) / `2` (usage
error). A task a session creates is indistinguishable from one you created. Nothing in the format needs the editor
open.

### 12. A pipeline guards the vault — works today

```sh
nvim --headless -u NONE -l scripts/tasks-ci.lua
```

Three steps: `check` (errors fail), `index --check` (no outdated or missing overview), and the vault's own
`TOOLS/scripts/md_lint.lua` over the generated overviews. Exit `0` only when all pass. Read the trust note in
[ENGINE.md](ENGINE.md): the lint script is *run*, so use the gate only on a vault whose script you trust.

### 13. Many areas, one view — works today

`:Tasks list` without an area covers every area; `--category=bug,security --sort=severity` answers "what is the
worst open thing, anywhere", `--effort=<=S --prio=<=2` answers "what is small and important". An area is any folder
that holds `ROADMAP/` or `Backlog/`; names listed in `extra_areas` count even when empty.

## Planned scenarios

These are designed and sized; until they exist, the "instead" column is what to do.

| Scenario | What it will do | Instead, today |
| --- | --- | --- |
| **Next task after `done`** | Finishing a task opens a small non-blocking popup: the best ready task (freed by this one first, then same plan, same area, whole vault) with a key to jump to it; when nothing is startable it says what waits for you instead of "all done" | `:Tasks list --status=doing,decision`, then 3 |
| **Plans close themselves** | A task's plan steps are ticked when it is done, a plan file closes when its last member is done, generated plan blocks in documents are refreshed | tick the steps by hand |
| **Effort and value** | `value: 1-5` next to `effort`; sums, a return-on-effort order and quick wins per area or plan, always saying how many tasks have no estimate | `effort=` only, `--sort=prio-effort` |
| **Who does it** | `actor: cdx / me / pair`: filter and queue "what an AI session may do alone" vs "what only I can do", derived from existing tags without migrating | tags such as `needs-user` |
| **Plans** | `blocked_by` and a soft `after` become waves, a critical path, "what is ready", "which decision unlocks most" (`tasks plan`, `tasks next`) | 3 and 4 by hand |
| **Triage** | after a brain dump an AI proposes edges and groups, with one sentence of reasoning each; you accept one by one | 2 by hand |

The design lives with the author's notes; the tasks for it are ordinary tasks in the author's vault.

## Which command for which intention

| I want to ... | Command |
| --- | --- |
| capture | `:Tasks new <area> "title"` |
| capture with attributes | `:Tasks new` (form) or `new <area> "title" kind= prio= effort= tags= category= severity=` |
| change attributes | `:Tasks set <id> key=value ...` |
| say "A waits for B" | `:Tasks set <A> blocked_by=[<B>]` |
| see the work | `:Tasks list [area] [filters] [--sort=]` |
| see what is stale | `:Tasks list --stale=60`, `--stale=refs` |
| finish | `:Tasks done <id> [done_in=...]` |
| attach a file | `:Tasks attach <id> <file>` |
| open or preview | `:Tasks open <id>`, `:Tasks preview <id>` |
| regenerate / verify overviews | `:Tasks index [--check]` |
| browse an area's folders | `:Tasks folder <area> [tasks\|roadmap\|backlog\|handover\|notes\|all]` |
| do all of this without an editor | `scripts/tasks.lua <verb> ...` |

## What goes wrong, and how you notice

| Situation | What you see | What to do |
| --- | --- | --- |
| a task file has broken frontmatter | it is listed as invalid; `check` names the problem | fix the file; one bad file never hides the others |
| two sessions edit the same task | `done` stops with "changed while it was being finished"; dashboard `s`/`p` skips the task | run it again after looking at the file |
| an export would replace a file | "already exists (pass --force ...)" | choose another path or pass `--force` |
| `TASKS.md` is your own file | "not a generated index": it is never overwritten | move it; the generated one gets the name |
| a `blocked_by` id does not exist | `check`: `blocked-by-dangling` | correct the id (ids are `<area>/<slug>`) |
| no vault configured | "vault not found" | `setup({ vault = ... })` or `$TASKS_VAULT` |
| `--stale=refs` is slow | it runs `git log` per repo, synchronously | narrow with `--status=` first |
