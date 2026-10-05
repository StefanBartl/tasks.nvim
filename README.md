# tasks.nvim

Offene Arbeit als **eine Markdown-Datei pro Task** (flaches YAML-Frontmatter), pro Projekt ("Area") ein erzeugter
Überblick `ROADMAP/TASKS.md`. Die Engine liest, sortiert, indiziert, legt an, ändert, schließt ab und prüft diese
Dateien; sie ist reines Lua ohne UI, dazu kommt eine Headless-CLI für Sitzungen ohne Neovim und für CI.

> **Stand:** früh. Die Engine und die CLI sind aus einer privaten Neovim-Config herausgelöst und laufen
> (13 Specs); die Editor-Befehle (`:Tasks`, Dashboard, Formular) folgen im nächsten Schritt. **Noch nicht
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
})
```

## Headless

```sh
export TASKS_VAULT=~/vault
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing
nvim --headless -u NONE -l scripts/tasks.lua new my-project "Fix the thing" --kind=bug --prio=2
nvim --headless -u NONE -l scripts/tasks.lua done my-project/fix-the-thing
nvim --headless -u NONE -l scripts/tasks-ci.lua          # check + index --check + md_lint, Exit 0/1
```

Format, Regeln, Verben und Prüfungen: [docs/ENGINE.md](docs/ENGINE.md).

## Tests

```sh
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua            # alle
nvim -n -i NONE --headless -u NONE -l TESTS/run.lua tasks_mutate
```

Die Specs laufen gegen einen temporären Fixture-Vault, nie gegen einen echten.

## Lizenz

MIT
