# Bindings

## Command

`:Tasks <verb>` (a `lib.nvim` composer verb, `<Tab>` completes verbs, areas, task ids and values). No default
keymaps and no autocommands at load time (the browser preview adds a short-lived `TasksPreviewTemp` group while a temporary file exists). Set `vim.g.tasks_nvim_no_command = true` to register your own verb from
`tasks_nvim.ui.routes` instead.

| Verb | Arguments | Does |
| --- | --- | --- |
| `list` | `[<area>\|all]` + filters (`--status= --prio= --effort= --kind= --category= --severity= --tag= --stale= --blocked`), `--sort=`, `--to=`, `--format=` | open tasks as a table, or the dashboard when nothing is delivered elsewhere |
| `index` | `[<area>] [--all] [--check]` | (re)write `ROADMAP/TASKS.md`; `--check` writes nothing |
| `new` | `[<area> [title...]] [kind= prio= effort= tags= category= severity= status=] [--folder]` | create a task (without arguments: the Markdown form) |
| `set` | `<id> key=value ...` | change frontmatter |
| `done` | `<id> [done_in= date=] [--yes]` | finish after confirmation, move to `Backlog/` |
| `attach` | `<id> <file> [name=]` | copy a file into the task's `assets/` |
| `folderize` | `<id>` | turn a plain task into a folder task |
| `template` | `[--to=]` | the task file template |
| `open` | `<id>` | open the file of a task |
| `preview` | `<id>` | browser preview through mdview.nvim |
| `folder` | `<area> [tasks\|roadmap\|backlog\|handover\|notes\|all] [--action=] [--list] [--to=]` | picker over an area folder |

Details of every verb: [COMMANDS.md](COMMANDS.md).

## Dashboard keys (buffer-local, `g?` shows them)

| Key | Does |
| --- | --- |
| `<CR>` | open the file(s); counts as a visit for `--sort=frecency` |
| `<Tab>` | mark / unmark |
| `s` / `p` | advance status / prio of marked (else current) tasks |
| `D` | finish (asks first) |
| `f` | set a filter chip |
| `gl` | named lists: apply one, save the current filter and sort as one, rename or delete a saved one |
| `o` | cycle the sort |
| `e` | export marked (else all shown) tasks |
| `gp` | preview the task file in the browser |
| `r` | rescan now |
| `gb` / `gr` | Backlog picker / ROADMAP of the area under the cursor |
| `v` | switch between the list and the stage view |
| `P` | give the marked (else current) tasks a plan and a stage |
| `J` / `K` | stage view: move the task down / up among its stage's tasks (sets `order`) |
| `g?` | help |

A count works on the cycling keys: `3p` advances the priority three steps, `2s` the status, `3o` the sort order. The other keys ignore a count (mark several tasks with `<Tab>` instead).

In the input window the same actions are on Alt (these shadow snacks.nvim's own `<M-d>` inspect, `<M-f>` follow,
`<M-r>` regex, `<M-m>` maximize and `<M-p>` preview toggles there; turn any of them off or move it with `keys`, below): `<M-s> <M-p> <M-d> <M-f> <M-l> <M-o> <M-e> <M-r> <M-b> <M-m> <M-v> <M-?>` (`<M-l>` is the lists menu).

## Changing or switching off keys

```lua
require("tasks_nvim").setup({
  keys = {
    dashboard = { done = "X", preview = false },     -- list window; false: no key for that action
    dashboard_input = { sort = "<M-t>", filter = false },  -- input window (normal and insert mode)
    form = { cancel = false, submit = "<C-CR>" },    -- `:Tasks new` form
  },
})
```

An action that is not named keeps its default. Dashboard actions: `status prio done filter sort export rescan
backlog roadmap preview view assign move_down move_up help`. Form actions: `tick_space tick_enter submit cancel cancel_ctrl help`. An unknown
action name is reported (and listed in `:checkhealth`), never bound. The help (`g?`) lists the default keys.

## Form (`:Tasks new` without arguments)

Buffer-local keys of the form buffer:

| Key | Does |
| --- | --- |
| `<Space>` / `<CR>` on a `- [ ]` line | tick or untick (single-choice lists keep one tick, `category` takes several) |
| `<C-s>` (normal and insert) | submit |
| `q` (normal) / `<C-q>` | cancel; asks first when text was typed |
| `g?` | help |

## Headless

`scripts/tasks.lua` and `scripts/tasks-ci.lua`; see [ENGINE.md](ENGINE.md).
