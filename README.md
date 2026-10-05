# tasks.nvim

Offene Arbeit als **eine Markdown-Datei pro Task** (flaches YAML-Frontmatter), pro Projekt ("Area") ein erzeugter
Überblick `ROADMAP/TASKS.md`. Die Engine (`lua/tasks_nvim/*.lua`) liest, sortiert, indiziert, legt an, ändert,
schließt ab und prüft diese Dateien und kommt ohne UI aus; darüber liegen der Befehl `:Tasks` mit Dashboard,
Formular und Vorschau (`lua/tasks_nvim/ui/`) und eine Headless-CLI für Sitzungen ohne Neovim und für CI.

> **Stand:** früh. Aus einer privaten Neovim-Config herausgelöst, Specs laufen (24). **Noch nicht
> veröffentlicht**, kein Release, nur unter Windows getestet.

## Anforderungen

| | |
| --- | --- |
| Neovim | 0.10+ |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | erforderlich (Dateien, Frontmatter, Checkpoint) |

## Einrichten

Es gibt keinen eingebauten Vault-Pfad:

```lua
require("tasks_nvim").setup({
  vault = "~/vault",          -- ein Ordner je Area; alternativ $TASKS_VAULT
  extra_areas = { "ALL" },    -- Ordner, die Areas sind, obwohl sie weder ROADMAP/ noch Backlog/ enthalten
  dashboard = { watch = true, debounce_ms = 250 },   -- Live-Refresh des Dashboards
  staleness = { git_timeout_ms = 20000, budget_ms = 30000, repo_bases = {} },  -- --stale=refs
  ci = { lint_timeout_ms = 120000 },                 -- md_lint im CI-Gate
})
```

Lazy-Laden (lazy.nvim): `{ "StefanBartl/tasks.nvim", cmd = "Tasks", dependencies = { "StefanBartl/lib.nvim" },
opts = { vault = "~/vault" } }`. Ohne `cmd`/`event` legt `plugin/tasks_nvim.lua` den Befehl beim Start an
(`vim.g.tasks_nvim_no_command = true` verhindert das).

## Headless

```sh
export TASKS_VAULT=~/vault
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing
nvim --headless -u NONE -l scripts/tasks.lua new my-project "Fix the thing" --kind=bug --prio=2
nvim --headless -u NONE -l scripts/tasks.lua done my-project/fix-the-thing
nvim --headless -u NONE -l scripts/tasks-ci.lua          # check + index --check + md_lint, Exit 0/1
```

Format, Regeln, Verben und Prüfungen: [docs/ENGINE.md](docs/ENGINE.md).
Wie man damit arbeitet, an Szenarien (was heute geht, was geplant ist): [docs/WORKFLOWS.md](docs/WORKFLOWS.md).
Befehle: [docs/COMMANDS.md](docs/COMMANDS.md), Tasten: [docs/BINDINGS.md](docs/BINDINGS.md).

## Tests

```sh
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua            # alle
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua tasks_mutate
```

Die Specs laufen gegen einen temporären Fixture-Vault, nie gegen einen echten.

## Lizenz

MIT
