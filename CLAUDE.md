# tasks.nvim (Engine und maschinenlesbarer Vertrag)

Lua-Plugin für Neovim; zusätzlich der Vertrag `tasks-export/1` und `tasks-ops/1`, den
`tasks-desktop` über `engine.lock` pinnt. Konventionen wie in der Vorlage `nvim-plugin`.

## Vor jedem Commit (alles muss grün sein)

```
stylua --check lua TESTS
luacheck lua TESTS scripts            # 0 Warnungen: eine Warnung macht die CI rot
LIB_NVIM_DIR=E:/repos/lib.nvim bash scripts/test.sh
bash scripts/contract.sh              # schema, goldens, typen (Schritt `contract` von scripts/ci.sh)
```

- Ein Fix ohne Spec, der ohne den Fix rot wird, gilt nicht als fertig.
- Die Specs laufen einzeln mit `bash scripts/test.sh --filter <teil>`. Der Filter
  ist ein Teilstring des Dateinamens; die Zeile `PARTIAL | ...` ist bei einem Filter
  normal.

## Den Vertrag ändern (neues Dokument, neues Feld, neue Methode)

1. Code in `lua/tasks_nvim/contract.lua`, Methode in `api.lua` (`METHODS`), Name in
   `contract.CAPABILITIES` (alphabetisch, sonst schlägt der `hello`-Spec an).
2. Schema `schemas/tasks-export/1/tasks-export.schema.json` (Eintrag in `$defs` und
   in der `oneOf`-Liste).
3. Golden-Fall in `TESTS/contract_golden.lua`, dann
   `nvim --headless -u NONE -l TESTS/golden/regenerate.lua` und die Diffs in
   `TESTS/golden` lesen.
4. `cd contract && node check.mjs --write` erzeugt `tasks-export.d.ts`; Mutationen
   (kaputte Dokumente) in `check.mjs` ergänzen.
5. `docs/CONTRACT.md`, `CHANGELOG.md`, Spec in `TESTS/tasks_contract_spec.lua`.
6. Erst **committen und pushen**, dann in `tasks-desktop` die Typen kopieren und
   `engine.lock` auf diesen Commit setzen.

- Eine Eingabe, die ein Dokument nicht schreiben könnte (zu große Zahlen, `inf`),
  gehört an den Eingang des Modells (`model.is_effort`), nicht in eine einzelne
  Methode: sonst bringt eine Datei oder ein Schreibzugriff alle Dokumente zu Fall.
- Ein Dokument nennt nie einen Pfad dieser Maschine (`redact`, `safe_path`).

## Git

- Im Checkout `E:\repos\tasks.nvim` liegen manchmal lokale, noch nicht gepushte
  Commits einer anderen Sitzung. Vor dem Push `git log origin/main..HEAD` ansehen und
  nicht blind `git push` ausführen.
- Keine Pull Requests, keine Co-Autorenschaft von Claude.
