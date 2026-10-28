# Task vault

One folder per project (an "area"). Each area has:

- `ROADMAP/tasks/<slug>.md` -- one Markdown file per open task
- `ROADMAP/TASKS.md` -- generated overview, never edited by hand
- `Backlog/FEATURES`, `Backlog/TASKS` -- finished work, with an index in `Backlog/README.md`

Managed by tasks.nvim: `:Tasks new <area> <title>`, `:Tasks done <id>`, `:TasksVault open <area>`.
