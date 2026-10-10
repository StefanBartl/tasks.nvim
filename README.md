> **Alpha, not released yet.** The engine, the `:Tasks` command, the dashboard, the form and the headless CLI are
> built and covered by specs (44 spec files). Developed and tested on Windows; the CI runs the specs on Linux, Windows
> and macOS and is green on all three.
> Pin a commit if you depend on this.

# tasks.nvim

```
  _            _                         _
 | |_ __ _ ___| | _____   _ ____   _(_)_ __ ___
 | __/ _` / __| |/ / __| | '_ \ \ / / | '_ ` _ \
 | || (_| \__ \   <\__ \_| | | \ V /| | | | | | |
  \__\__,_|___/_|\_\___(_)_| |_|\_/ |_|_| |_| |_|
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-alpha-red)

> Part of the [wkd](https://stefanbartl.github.io/wkd/) family of plugins. It pairs with
> [rules.nvim](https://github.com/StefanBartl/rules.nvim) (findings of a rule check become tasks; planned) and
> builds on [lib.nvim](https://github.com/StefanBartl/lib.nvim).

Open work as **one Markdown file per task**, with a few lines of flat YAML frontmatter, and a generated overview
per project. The engine reads, ranks, indexes, creates, changes, finishes and checks those files; on top sit the
`:Tasks` command with a dashboard, a form and a browser preview, and a headless CLI for scripts, CI and AI
sessions that run without an editor. Nothing is stored anywhere but in the files.

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Configuration](#configuration)
- [Headless](#headless)
- [Documentation](#documentation)
- [Tests](#tests)
- [License](#license)

## What it does

- **Capture in one call**: `:Tasks new my-area "Title"`, or a Markdown form. No required field, no question.
- **A vault of areas**: `<area>/ROADMAP/tasks/<slug>.md` for open tasks, `<area>/Backlog/` for finished ones,
  `<area>/ROADMAP/TASKS.md` generated (never edited, never overwritten when it is your own file).
- **Plan and next**: stages, what is ready, which decision unlocks most, the critical path (`:Tasks plan`); the best
  next task with the reason and an honest empty answer (`:Tasks next`, and a dialog after `done`); sums that say what
  is missing (`:Tasks estimate`)
- **Undertakings**: an optional plan file per undertaking (goal, boundaries, stage names; no task list: tasks join with
  `plan:` / `phase:`), soft edges (`after`), a sort hint (`order`), a `## Plan` section with checkbox steps per task;
  finishing a task ticks its steps, finishes a plan with its last member and refreshes generated blocks in the
  documents you name (`<!-- GENERATED:plan scope=... -->`)
- **Rank and filter**: status, priority, effort, value (and a derived return on effort), who can do it (`cdx` / `me` / `pair`), kind, category, severity, tags, blockers, staleness
  (`--stale=60`, or `--stale=refs`: files a task names that changed since it was last updated).
- **Finish safely**: `:Tasks done` moves the file to `Backlog/`, adds a row to its README, regenerates the index,
  and restores everything byte for byte if a step fails.
- **Dashboard** (needs [snacks.nvim](https://github.com/folke/snacks.nvim); a plain list without it): filter chips,
  marks, bulk status/priority/finish, export, live refresh when files change.
- **Folder tasks** with an `assets/` folder for screenshots and logs.
- **Export** to a buffer, the clipboard, the quickfix list, a file (CSV or Markdown) or a browser preview.
- **Headless CLI** with the same rules and a CI gate (`check`, `index --check`, `md_lint`).

How it is meant to be used, scenario by scenario: [docs/WORKFLOWS.md](docs/WORKFLOWS.md).

## Requirements

| | |
| --- | --- |
| Neovim | 0.10+ |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | required (files, frontmatter, checkpoints, the command composer) |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | optional: the interactive dashboard |
| [mdview.nvim](https://github.com/StefanBartl/mdview.nvim) | optional: browser preview |
| [ui.nvim](https://github.com/StefanBartl/ui.nvim) | optional: themed confirmation dialogs |
| [pickers.nvim](https://github.com/StefanBartl/pickers.nvim) | optional: `:Tasks folder` |
| [cascade.nvim](https://github.com/StefanBartl/cascade.nvim) | optional: cycle values in the form |
| `git` | optional: dates for `--stale=refs` (file times otherwise) |

`:checkhealth tasks_nvim` shows what is present.

## Installation

lazy.nvim:

```lua
{
  "StefanBartl/tasks.nvim",
  dependencies = { "StefanBartl/lib.nvim" },
  cmd = "Tasks",
  opts = {
    vault = "~/vault", -- one folder per area; or set $TASKS_VAULT
  },
}
```

Without `cmd` or `event` the plugin registers `:Tasks` at startup; set `vim.g.tasks_nvim_no_command = true` to
register your own verb from `tasks_nvim.ui.routes` instead. There is no built-in vault path.

## Quickstart

```vim
:Tasks new my-area "Fix the thing"          " capture
:Tasks list my-area                          " the dashboard
:Tasks set my-area/fix-the-thing status=doing prio=2
:Tasks done my-area/fix-the-thing done_in=my-repo@abc1234
```

An area is any folder in the vault that holds `ROADMAP/` or `Backlog/`; create the folders once (or name the area
in `extra_areas`). Every verb, flag and filter: [docs/COMMANDS.md](docs/COMMANDS.md).

## Configuration

Every key is optional.

```lua
require("tasks_nvim").setup({
  vault = "~/vault",         -- one folder per area; $TASKS_VAULT when unset
  extra_areas = { "ALL" },   -- folders that are areas although they hold neither ROADMAP/ nor Backlog/
  dashboard = { watch = true, debounce_ms = 250, backend = "auto" },            -- live refresh; backend: auto | snacks | kit | select
  staleness = { git_timeout_ms = 20000, budget_ms = 30000, repo_bases = {} },   -- --stale=refs
  ci = { lint_timeout_ms = 120000 },                                            -- md_lint in the CI gate
  next = { popup = true, cdx_hint = true },                                     -- the dialog after done
  chain = { marker_docs = {} },                                                 -- documents with generated plan blocks
  steps = { ask_finish = false },                                               -- ask to finish when the last step is ticked
})
```

A wrong key or value is reported (and listed in `:checkhealth`) and the default stays. Every key of the
dashboard and the form can be moved or switched off with `keys = { dashboard = {...}, dashboard_input = {...},
form = {...} }`, for example `keys = { form = { cancel = false } }` ([docs/BINDINGS.md](docs/BINDINGS.md)).

## Headless

```sh
export TASKS_VAULT=~/vault
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing
nvim --headless -u NONE -l scripts/tasks.lua new my-project "Fix the thing" --kind=bug --prio=2
nvim --headless -u NONE -l scripts/tasks.lua done my-project/fix-the-thing
nvim --headless -u NONE -l scripts/tasks-ci.lua    # check + index --check + md_lint, exit 0/1
nvim --headless -u NONE -l scripts/tasks-html.lua --out=tasks.html   # one-file HTML overview, open it in a browser
```

The CI gate can *run* `<vault>/TOOLS/scripts/md_lint.lua`, code that lives in the vault, so it refuses to until
you pass `--trust-vault-lint` (or `--md-lint=<your own copy>`, or `--no-lint`; [docs/ENGINE.md](docs/ENGINE.md)). A finished task needs `<area>/Backlog/README.md` to get its row; without
the file `done` says so and moves the task anyway.

## Documentation

| | |
| --- | --- |
| [docs/WORKFLOWS.md](docs/WORKFLOWS.md) | scenarios: what to do when, what works today, what is planned |
| [docs/COMMANDS.md](docs/COMMANDS.md) | every `:Tasks` verb, flag and the dashboard |
| [docs/BINDINGS.md](docs/BINDINGS.md) | commands, dashboard and form keys, autocommands |
| [docs/ENGINE.md](docs/ENGINE.md) | file format, rules, checks, the CLI, limits |
| `:help tasks_nvim` | the same in short |

## Tests

```sh
scripts/test.sh                     # all specs
scripts/test.sh --file tasks_mutate # spec files whose name contains the argument
scripts/test.sh --json ir.json      # also write the machine-readable result
```

The specs run on [testing.nvim](https://github.com/StefanBartl/testing.nvim) (configured in `.testing.lua`) against a
temporary fixture vault, never a real one. testing.nvim and lib.nvim are looked up in `$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR`,
`.deps/<name>`, next to this repository and in lazy.nvim's data folder. The dashboard specs also drive snacks.nvim's
picker: `scripts/test.sh` looks for it in the same places (override `$SNACKS_DIR`) and passes the folder on, because the
runner gives every spec its own sandboxed data folder. Without snacks.nvim the script says so and the two picker specs
(`tasks_dash_picker_spec`, `tasks_dash_refresh_spec`) report a skip (CI requires it); the dashboard's plain
`vim.ui.select` fallback has its own spec that always runs. The same goes for the option-float texts: with a lib.nvim
that cannot list the undescribed options (`composer.help.undocumented`) `tasks_usrcmds_help_spec` reports a skip, and
`tasks_usrcmds_help_style_spec` (shape of the texts) still runs.

## License

[MIT](LICENSE)
