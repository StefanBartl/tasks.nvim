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
the dashboard shows the open blocker next to such a task (`←`). What is *ready* is answered by `:Tasks list --ready` and the plan (14a).

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

1. Type to search; `f` sets a filter chip (status, prio, effort, kind, category, severity, value, actor, tag,
   blocked, unestimated, stale-refs, readiness, plan, phase); `o` cycles the sort (default, prio-effort, severity, frecency, roi).
2. `<Tab>` marks tasks. `s` advances the status of the marked tasks (or the current one), `p` the prio, `D` finishes
   them after **one** confirmation. A task that someone else changed since the list was drawn is skipped with a
   message instead of being overwritten.
3. `<CR>` opens the file, `gp` previews it in the browser (mdview.nvim), `gb` / `gr` open the area's Backlog and
   ROADMAP, `e` exports the marked tasks.
4. The list refreshes by itself when a task file changes on disk; cursor and marks stay on the same tasks.
5. `v` switches to the **stage view**: the tasks grouped by stage ("Stage 1 · 5 tasks · not parallel" when two of them
   name the same file in `refs`), each row with what it still waits for, and an "Unsorted" block for tasks without a
   plan, an edge or dependants. `P` gives the marked (else current) tasks a plan and one of its stages (`plan:` /
   `phase:` in one batch). `J` / `K` move a task up or down among the tasks of its stage: `order` becomes a fraction
   between the two neighbours, and it only breaks ties behind status and prio. `v` again returns to the list; marks and
   filter stay.

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
nvim --headless -u NONE -l scripts/tasks-ci.lua --trust-vault-lint
```

Three steps: `check` (errors fail), `index --check` (no outdated or missing overview), and the vault's own
`TOOLS/scripts/md_lint.lua` over the generated overviews. Exit `0` only when all pass. Read the trust note in
[ENGINE.md](ENGINE.md): the lint script is *run*, so the gate refuses it until you pass `--trust-vault-lint`
(your own vault, your own script) or name a script of your own with `--md-lint=<file>`.

### 13. Many areas, one view — works today

`:Tasks list` without an area covers every area; `--category=bug,security --sort=severity` answers "what is the
worst open thing, anywhere", `--effort=<=S --prio=<=2` answers "what is small and important". An area is any folder
that holds `ROADMAP/` or `Backlog/`; names listed in `extra_areas` count even when empty.

### 14a. Who is startable, and in what order -- works today

```vim
:Tasks list --ready --sort=prio-effort
:Tasks plan my-area
:Tasks plan --for=my-area/send-via-gateway
```

`blocked_by` is all it reads: nothing new to write. The plan answers "what can I start" (**ready now**), "which
decision is worth deciding first" (**decisions by leverage**: how many tasks depend on it, transitively), "in what
order" (**stages**, every task in the earliest stage it can be in) and "how long is the longest chain" (**critical
path**, weighted by the effort; a task without an effort counts as a day and the plan says how many did). A task that
blocks a better one is ranked by that one's prio. `--for=<id>` is "what do I need so that X works", across areas.
A cycle over `blocked_by` is named, left out of the stages and reported by `check` as an error.

### 14b. What do I do next -- works today

```vim
:Tasks next
:Tasks next my-area --n=5
:Tasks next --actor=cdx
```

The best **ready** task with the reason: freed by the task you just finished, then your area, then the vault. Tasks
written `cdx` are not offered as your next task, they are listed apart; `--actor=cdx` is the queue for an AI session.
The same answer comes in a small dialog after every `:Tasks done` (`Not now` is the first choice, so a stray <CR> opens
nothing), once after a whole stack finished in the dashboard, and as `next:` lines from the headless `done`. When
there is nothing, it says which kind of nothing: "Nothing can be started. Still open: 4 for you, 6 blocked, 3 parked."
-- never "all done" while work is only waiting.

### 14c. How big is this -- works today

```vim
:Tasks estimate my-area
:Tasks estimate --for=my-area/big-thing
:Tasks estimate my-area --walk
```

"22 d from 17 of 20 (range 14-31 d) · value 61 · roi 2.8 · me 8.5 d / cdx 13.5 d / unclear 3 -- estimate from the scale,
not a promise." The sum says how many tasks it is made of, the range puts every T-shirt size at both ends, the roi uses
only tasks with both numbers, and quick wins (value 4+, effort S-) are named. `--walk` asks for the missing efforts and
values one task at a time (`Skip` is the first choice, `Stop` keeps what you gave) and writes them in one batch.

### 14. What is worth the effort — works today

```vim
:Tasks set my-area/some-slug effort=S value=4
:Tasks list my-area --sort=roi
:Tasks list --value=>=4 --effort=<=S --sort=roi
```

`value` (1-5) is the expected benefit, independent of time; `prio` stays your order decision. `--sort=roi` puts the
most value per effort first (`value / effort in days`, never below a quarter day). A task without a value or without
an effort has **no** figure and sorts after the ones that do: it is not "worth 0", it is unestimated. The dashboard
shows `v4` on the row; the CSV export gets `Value` and `ROI` columns. Sums per plan and area, and a helper that walks
the unestimated tasks, are scenario 14c (above).

#### Quick wins — the definition

A task is a **quick win** when it has a `value` of **4 or more** *and* an `effort` of **`S` or less** (`XS`, `S`, or
up to `0.5d`). Both numbers have to be written: a task without a value or without an effort is *unestimated*, never a
quick win. Small but unrated tasks are therefore invisible here until they get a value; `:Tasks estimate --walk`
asks for the missing numbers. The thresholds are `QUICK_WIN_VALUE` and `QUICK_WIN_DAYS` in `tasks_nvim.estimate`
(one definition, used by every place that names quick wins).

```vim
:Tasks estimate                                 " the line 'quick wins: ...' (best roi first)
:Tasks list --value=>=4 --effort=<=S --sort=roi " the same set, as a list
```

### 15. Who can do this — works today

```vim
:Tasks set my-area/some-slug actor=cdx
:Tasks list --actor=me
:Tasks list --actor=cdx --status=open --sort=prio-effort
```

`cdx` can be done by an AI session alone, `me` only by you (decisions, live tests, accounts, publishing), `pair` is a
draft by the AI and an answer by you. `--actor=me` also finds every `status: decision` task and every task tagged
`needs-user` without anything written, so the existing vault is filterable on day one; `--actor=none` lists what
nobody classified. `check` warns when a task written `cdx` waits on something only you can do
(`actor-cdx-waits-on-me`). A headless session that sets `status=doing` on a task that is for you gets a warning.
To write the derivable answers into the files once:

```sh
nvim --headless -u NONE -l scripts/tasks.lua migrate-actor            # dry run, writes nothing
nvim --headless -u NONE -l scripts/tasks.lua migrate-actor --write
```

Every other task stays empty on purpose: the share of empty ones is the honest number.

### 16. An undertaking with stages -- works today

```vim
:Tasks planfile my-area Ship the gateway --phases=clarify,build,ship --areas=my-area,other-area
:Tasks set my-area/gateway-config plan=my-area/ship-the-gateway phase=clarify
:Tasks plan --plan=my-area/ship-the-gateway
```

The plan file holds what only a human can justify: the goal, the boundaries, when it is done, the names of the stages.
It holds **no task list**: every task carries `plan:` and `phase:`, and the plan is drawn from them (two tasks edited
on two machines never collide). Stages follow `phase_order` as a soft hint; `--gate=hard` makes them a rule (a task of
a stage waits until the earlier stage is finished -- `list --ready`, `next` and the plan all see it). `check` catches a
task that names a plan nobody wrote (`plan-unknown`), another area than the plan lists, a stage the plan does not
list.

### 17. "This one should come after that one" -- works today

```vim
:Tasks set my-area/send-it after=[my-area/write-it]
:Tasks set my-area/small-fix order=1.5
```

`after` is soft: the task stays startable, it only moves to a later stage; a soft edge that would close a cycle is
dropped with a warning. `order` is a tie-breaker inside a stage (a fraction slots a task in without renumbering).
Tasks of one stage that name the same file in `refs` are marked `same-file`: they are not parallel work, and the plan
says which to do first.

### 18. Steps inside one task -- works today

```vim
:Tasks template --with-plan
:Tasks plan my-area --with-steps
```

A task may carry `## Plan` with checkbox steps (`- [ ] 2. validators -- Acceptance 2, 3`). The engine only reads the
progress ("2/4") and shows the steps with `--with-steps`; a step marked `(dropped)` is struck from the count.
Finishing the task ticks the open steps (written with the finish, so a failed finish leaves them open). With
`steps = { ask_finish = true }` ticking the last step in the buffer asks whether to finish the task. `check` hints
(never errors) at acceptance points no step refers to.

### 19. A hand-written handover that stays true -- works today

```markdown
<!-- GENERATED:plan scope=ship-the-gateway start -->
...
<!-- GENERATED:plan end -->
```

```vim
:Tasks plan --plan=my-area/ship-the-gateway --write=docs/HANDOVER.md
```

Only the block changes; the rest of the document keeps its bytes and its line endings, line by line. The first
`--write` also records on the start marker how the block was made (`plan=my-area/ship-the-gateway`, a `ready=1` view,
filters), so the refresh builds the same block later; two plans that share a slug are told apart that way, and a block
that cannot be told is skipped with the candidates named. Name the document once in
`setup({ chain = { marker_docs = { "docs/HANDOVER.md" } } })` -- for the headless CLI (an agent finishing tasks) in
`$TASKS_MARKER_DOCS` -- and every `done` refreshes its blocks (a stack finished in the dashboard refreshes them once);
when the plan's last task is done the plan is finished too, and its block becomes "Plan ... is done: 12 tasks, estimate
9.5 d, finished in 14 days". Blocks are not part of `check` or CI (a task change must not turn the pipeline red);
`plan --write=... --check` says whether one is out of date.

## Planned scenarios

These are designed and sized; until they exist, the "instead" column is what to do.

| Scenario | What it will do | Instead, today |
| --- | --- | --- |
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
| see what can be started, in what order | `:Tasks plan [area]`, `:Tasks list --ready` |
| decide what to start next | `:Tasks next [area]` |
| see how big something is | `:Tasks estimate [area]`, `--walk` to fill the gaps |
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
| two tasks wait on each other | `check`: `blocked-by-cycle` (an error) naming the members; the plan leaves them out of the stages | remove one `blocked_by` |
| a task waits on a `parked` task | `check` warns `blocked-by-parked`; the plan marks it stuck and `next` never offers it | un-park the blocker or drop the edge |
| `next` says nothing can be started | "Still open: 4 for you, 6 blocked, 3 parked" -- not "all done" | decide what waits for you (`:Tasks list --actor=me`) |
| no vault configured | "vault not found" | `setup({ vault = ... })` or `$TASKS_VAULT` |
| `--stale=refs` is slow | it runs `git log` per repo, synchronously | narrow with `--status=` first |
