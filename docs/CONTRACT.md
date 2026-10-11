# The machine contract `tasks-export/1`

What an app, an agent or a pipeline reads from the vault: a handful of JSON documents with a fixed shape, each with a
JSON Schema. The Markdown files stay the single source of truth; the documents are built from what the engine already
knows (`scan`, `plan`, `next_pick`, `estimate`), never from a second reading of the files. Reading is the larger part;
changes go through one door, `ops`, which asks the engine to write ([Writing](#writing-tasks-ops1)).

- [Asking](#asking) -- `tasks call`, the Lua door, the request
- [The documents](#the-documents) -- `hello`, `snapshot`, `list`, `task`, `next`, `areas`, `donepreview`, `result`, `error`
- [Writing](#writing-tasks-ops1) -- `ops`: `set`, `new`, `reorder`, `done`, `move_area`; conflicts, `done_preview`, dry runs
- [The rules every document keeps](#the-rules-every-document-keeps)
- [`etag`, `rev`, `digest`](#etag-rev-digest) -- what changed
- [Errors](#errors)
- [Writing a reader](#writing-a-reader) -- versions and unknown words
- [The vault stays the vault](#the-vault-stays-the-vault) -- links, network paths, refs
- [Schemas, golden files, checks](#schemas-golden-files-checks)

## Asking

Every document is one JSON object on one line (the canonical form, below). From a shell:

```sh
export TASKS_VAULT=~/vault
nvim --headless -u NONE -l scripts/tasks.lua call hello
nvim --headless -u NONE -l scripts/tasks.lua call snapshot
nvim --headless -u NONE -l scripts/tasks.lua call list --params='{"area":"my-project","status":["doing","open"],"limit":20}'
nvim --headless -u NONE -l scripts/tasks.lua call task --params='{"id":"my-project/fix-the-thing"}' --pretty
nvim --headless -u NONE -l scripts/tasks.lua --capabilities          # the same as `call hello`
```

`--params=-` reads the JSON from stdin instead (no limit of the command line, nothing for the shell to interpret).

| Method | Parameters | Answer (`kind`) |
|---|---|---|
| `hello` | none | `tasks.hello`: the handshake, reads no task |
| `snapshot` | none | `tasks.snapshot`: counts, areas, the plan head, the plans and every open task with its readiness |
| `list` | `area`, `status` (list), `limit` (1..100), `offset` | `tasks.list`: a page of open tasks in plan order |
| `task` | `id` (`<area>/<slug>`) | `tasks.task`: one task with its body and steps |
| `next` | `n` (0..10), `actor`, `area` | `tasks.next`: what to start next, with the reason |
| `areas` | none | `tasks.areas`: the areas with their open counts |
| `done_preview` | `id` | `tasks.donepreview`: what finishing the task would do, and the token for it |
| `ops` | the request itself (below) | `tasks.result`: what happened to each operation |

The exit code of `tasks call` is `0` for an answer, `2` for `invalid_argument`, `1` for any other error. An error is a
`tasks.error` document on stdout like any answer, so a reader parses one stream. `--pretty` indents the same document.

The command line also has a few forms of the same documents: `tasks list --format=json [--limit=N] [--offset=N]` (the
filters of the text form, the plan's order; `--sort` has no meaning there), `tasks next --format=json`,
`tasks areas --format=json|tsv`, `tasks show <id> [--format=json|text]`, `tasks plans [area]` and `tasks list --done`
(the finished tasks of the Backlogs).

From Lua, `require("tasks_nvim.api").call(method, request, { root = ..., indent = ... })` is the one door. It answers
with the text of the document and an error code (`nil` for an answer) and **never throws**: an unreadable vault, a
bad request and a bug of the engine are all a `tasks.error`.

A request is a JSON object, `{ "schema": 1, "params": { ... } }`. Both fields may be left out. A field or a parameter the
method does not know is `invalid_argument`: a request that is silently half-understood is worse than one that is refused.
A request is at most 256 KiB.

## The documents

Every document starts with the same head:

| Field | |
|---|---|
| `schema` | the version of the contract (`1`) |
| `plugin` | `tasks.nvim` |
| `kind` | `tasks.hello`, `tasks.snapshot`, `tasks.list`, `tasks.task`, `tasks.next`, `tasks.areas`, `tasks.donepreview`, `tasks.result`, `tasks.error` |
| `generated_at` | UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `vault.id` | the name of the vault folder (never its path) |
| `engine` | `version`, `git` (short commit of the plugin checkout, `unknown` without git) and `nvim` |

**`tasks.hello`** -- `schemas` (the versions this engine speaks), `capabilities` (what it can answer, sorted: an app shows
only what is listed), `limits` (`title`, `summary`, `body_bytes`, `list_items`, `batch_ops`) and `enums` (the words of
`status`, `kind`, `prio`, `value`, `effort`, `actor`, `category`, `severity`, so a client needs no copy of them).

**`tasks.snapshot`** -- the primary document.

| Field | |
|---|---|
| `counts` | `listed`, `unlisted`, `by_status` |
| `areas` | `[{ name, open, by_status }]` |
| `unlisted` | files in `ROADMAP/tasks/` that are not open tasks (`no-status`, `unknown-status`, `done-in-roadmap`), so nothing disappears silently |
| `plan` | `summary` (open tasks and how many are `ready`, `decision`, `waiting`, `stuck`, `freed`, `parked`), `critical_path` (`days`, `path`, `unknown_effort`), `stage_sizes`, `cycles`, `conflict_groups`, `warnings` |
| `plans` | the plan files: `id`, `title`, `status`, `areas`, `target`, `phase_order`, `gate`, `valid` |
| `estimate` | the sums of `estimate.rollup`: `tasks`, `days`, `n_with_effort`, `n_without_effort`, `value`, `n_with_value`, `roi`, `quick_wins`, `unestimated` |
| `tasks` | every open task, in the order a person would work in (below) |
| `incomplete` | folders that could not be read (relative paths): the document is what could be read, and says so |

A **task entry** (`tasks[]`, `items[]`, `task`) has: `id`, `area`, `slug`, `title`, `status`, `kind`, `prio`, `order`,
`effort`, `effort_days`, `value`, `roi`, `actor`, `actor_written`, `severity`, `created`, `updated`, `plan`, `phase`,
`done_in`, `tags`, `category`, `blocked_by`, `after`, `refs`, `summary`, `folder`, `file` (`<area>/ROADMAP/tasks/<slug>.md`,
relative to the vault), `valid`, `problems` (`[{ code, msg }]`), `steps` (`total`, `ticked`, `dropped`, only when the
task has a `## Plan` section), `etag` and, for an open task, `readiness`:

```json
"readiness": { "state": "ready", "stage": 1, "rank": 3, "eff_prio": 1, "leverage": 4, "open_blockers": [] }
```

`state` is `ready`, `decision`, `waiting`, `stuck`, `freed` or `parked` (the one definition of "can be started",
`tasks_nvim.plan`); `inversion`, `in_cycle` and `same_file` appear when they apply. `group` is `<status>|<eff_prio>`.

**`tasks.donepreview`** and **`tasks.result`** belong to writing and are described there.

**`tasks.list`** -- `total` (all matches), `offset`, `limit`, `items` (task entries) and `next_offset` while there is
more. Pages are 100 entries at most. **`tasks.task`** -- `task`, `body` (the Markdown after the frontmatter, cut at 256 KiB
with `body_truncated`) and `steps` (`[{ n, text, ticked, dropped }]`). **`tasks.next`** -- `task` (`id`, `title`, `status`,
`prio`, `effort` and the `reason`), `alternatives`, `cdx` (the queue written for the AI), `freed`, `ready` and `open`
(counts for the area and the vault) and, when there is no task, `empty` (`kind`: why). **`tasks.areas`** -- `areas`.

## Writing: `tasks-ops/1`

Changes go through one door, `ops`: a list of operations answered with one `tasks.result`. The engine stays the only
writer and the only implementation of the rules; a front end never touches a file.

```sh
echo '{"client_op_id":"c-1","ops":[{"op":"set","id":"my-project/fix-the-thing","patch":{"status":"doing"},"if_match":"sha256:3f6c9a1e0b7d4c22"}]}' \
  | nvim --headless -u NONE -l scripts/tasks.lua call ops --params=-
```

(`--params=-` reads the request from stdin, so there is no limit of the command line and the shell never sees it. For
`ops` the JSON is the whole request; for the read methods it is their `params`.)

A request is `{ "schema": 1, "client_op_id": "c-81f2", "dry_run": false, "ops": [ ... ] }`. `client_op_id` (1 to 64
characters of letters, digits and `. _ : -`) is echoed in the answer, for a client that must not repeat itself;
`dry_run` checks everything and writes nothing. At most 100 operations.

| `op` | Fields | |
|---|---|---|
| `set` | `id`, `patch`, `if_match`?, `expect`? | change frontmatter keys; `null` in the patch removes a key. `if_match` is the task's `etag`; `expect` is `{ "key", "value" }`: that key must still have that value |
| `new` | `area`, `title`, `fields`? | create a task. `fields`: `kind`, `prio`, `effort`, `tags`, `category`, `severity`, `value`, `actor`, `summary`, `refs`, `status`, `slug`. Relations (`blocked_by`, `after`, `plan`, `phase`) are set afterwards with `set` |
| `reorder` | `id`, `after`?, `before`?, `group`?, `if_match`? | move a task inside its group (same stage, same `status|eff_prio`, the `group` of the task entry): it gets an `order` between its neighbours'; tasks that have no `order` yet are numbered only where the spot needs it, and a crowd of halvings is renumbered. A move that would write more than 50 files is refused |
| `done` | `id`, `confirm`, `done_in`? | finish a task. `confirm` is the token of `done_preview` for the version of the file that was shown |
| `move_area` | `id`, `to_area` | only as a dry run in this version: the report of what the move would break (below) |

**The shape is checked first, for the whole request**: an unknown operation or field, a wrong type, an empty or too long
list is `invalid_argument` (`payload_too_large` for more than 100 operations) and nothing runs. After that every
operation runs on its own, in order, and **one that fails does not stop the others**. This is not all-or-nothing, and
the answer never says "ok" for a part: `ok` of the document is true only when every operation was.

The answer, `tasks.result`, has one entry per operation:

| Field | |
|---|---|
| `n`, `op`, `id` | the position, the operation and the task it is about (for `new`: the id it got) |
| `ok`, `outcome` | `changed`, `unchanged`, `created`, `done`; a dry run says `would_change`, `would_create`, `would_done`, `would_move` (or `blocked`: the move cannot be made); `failed` |
| `etag_before`, `etag_after` | the version of the file before and after (a dry run: only before) |
| `inverse` | the operation that undoes it: send it as a new operation, its `if_match` is the version the change left. A key a `set` added is `null` in the inverse patch. `done` and `new` have none in this version |
| `changed_ids` | the ids whose files this wrote |
| `index` | what happened to the generated overview of the area: `written`, `unchanged`, `removed` or `error`. It is written **once** for the whole request, however many tasks of the area changed |
| `error` | for a failed operation: `code`, `message`, `retryable`, `details` (see below) |
| `file`, `group`, `renumbered`, `writes`, `to`, `steps_ticked`, `plans_closed`, `notes`, `move` | what is particular to the operation |

**Conflicts.** `if_match` and `expect` are checked against the text read **under the file lock**, so two writers cannot
both win: the second gets `conflict` with `details`: `id`, `expected` and `actual` (the version it found) and, for
`expect`, the `key`. Another key of the same file that changed meanwhile is kept, never overwritten. A change of the
relations (`blocked_by`, `after`, `plan`, `phase`) is judged first with the codes of `check` (`blocked-by-self`,
`blocked-by-dangling`, `blocked-by-cycle` with the members named, `after-self`, `after-dangling`, `plan-unknown`,
`plan-phase`): an `invalid_argument` whose `details.problems` lists them. A `reorder` that is not what the caller saw (a
neighbour of another group, neighbours that are no longer next to each other, another `group`) is a `conflict` too: the
list moved on, ask again. A `reorder` is not all-or-nothing: what was written stays, and `details.written` says how far
it got.

**Finishing a task takes two steps** on purpose. `done_preview` (a read method, `{"id": ...}`) answers `tasks.donepreview`:
the target, the README row, the steps it would tick, the plan it would close (`closes_plan`), the tasks it would free
(`freed`), the `etag` of the file it read and a `confirm` token for exactly that version. `done` needs the token; if the
file changed since, it is a `conflict` and nothing moves. A task that is finished already answers `unchanged`, so a
repeated request does no harm. The token is not a secret (the engine keeps no state); a host that needs authorisation
adds its own.

**What a front end may not write.** Limits are kept on writing (title 300 characters, summary 1000, lists of 100
entries of 300 characters). A `refs` entry that is **new** must be a plain relative path, optionally with a line suffix
(`lua/a.lua:42`, `lua/a.lua:10-20`), an anchor (`docs/a.md#top`), a `repo@commit` or an id: no `..`, no drive or network
prefix, no absolute path, no control character, no colon but the line suffix. Entries the task already has stay as they
are. A task file that is a link is not written through (`forbidden`). No error carries a path of this machine, only ids.

**`move_area`** answers, as a dry run, with `move`: `new_id`, `from`, `to`, `conflicts` (the slug is taken in the target
area), `references` (the `blocked_by`, `after`, `refs`, plan `target` and documents that name the old id and would
dangle) and `notes`. The move itself, rewriting those places with a rollback, is a later version; without `dry_run` the
operation fails with `invalid_argument`.

The exit code of `tasks call ops` is `0` when every operation worked, `1` when any failed (the document says which), `2`
for a bad request.

## The rules every document keeps

- **No path of this machine.** A file is `<area>/ROADMAP/tasks/<slug>.md`, relative to the vault; an absolute `refs:`
  entry shows as `<external>/<name>`; the vault root inside a message is `<vault>`.
- **Missing means unknown, never 0.** A task without an effort has no `effort_days` and no `roi`; a task without a
  value has no `value`. Only values that are valid words of their enum are written.
- **A broken task is still there.** It has `valid: false` and `problems`, it does not vanish from the list. One without a
  usable status is in `unlisted`.
- **A document is at most 8 MiB.** A bigger one is the error `payload_too_large`, not a cut-off document. Ask for a page
  (`list`) or an area. (An error document is exempt: the limit must never keep a client from being told why.)
- **Canonical bytes.** Object keys are sorted by byte value; an empty list is `[]`, an empty object `{}` (as its kind says,
  never the other); a whole number below 2^53 is written without a fraction, any other number with the fewest digits that
  read back as the same number; `NaN`, `inf` and a whole number of 2^53 or more are an error, not a silent loss of
  digits. Strings are valid UTF-8 (a bad byte becomes U+FFFD); control bytes (C1 included), `"`, `\`, U+2028, U+2029 and
  `<` are escaped, so a document can sit inside a `<script>` block and be printed to a terminal as it is. There is no
  whitespace: the same vault gives the same bytes.

## `etag`, `rev`, `digest`

| | |
|---|---|
| `etag` (a task) | `sha256:` and the first 16 hex digits of the SHA-256 of the **bytes** of the task file as they were parsed. A later write compares against it; there is no second read, so no race between reading and hashing. A file that was not read has none. |
| `rev` (`snapshot`, `list`, `task`) | what the document's content stood on: `rev:` and six hex digits over the id and `etag` of the tasks in the document, of every plan file, and of the unlisted files. The same request with the same `rev` found the same files. |
| `digest` (every document that comes from a scan) | `sha256:` and 16 hex digits of the compact document **without `generated_at` and `engine`**. Two runs on an unchanged vault give the same digest, whenever and by whichever build of the engine they ran. |

## Errors

A `tasks.error` document: `code`, `message`, `retryable` and, when there is more to say, `details`.

| `code` | |
|---|---|
| `invalid_argument` | the request is not valid JSON, has an unknown field or parameter, or a value out of range |
| `not_found` | unknown method, area or task; no vault |
| `conflict` | the file is not the version the caller saw (`if_match`, `expect`, a stale `confirm`, a list that moved on); `details` says what was found |
| `exists` | the slug that was asked for is taken |
| `forbidden` | a task file that is a link is not written through |
| `unsupported_schema` | the request asks for a higher `schema` than this engine speaks |
| `payload_too_large` | a request over 256 KiB, a document over 8 MiB, more than 100 operations, a value over the limits |
| `locked` | another writer holds the file right now (`retryable: true`) |
| `lock_stuck` | a lock nobody will release (older than the takeover age and not deletable, or a folder where the lock file should be): the message names the lock to remove by hand |
| `rollback_incomplete` | a failed write could not be fully undone; the message names the files |
| `io` | something could not be listed, read or written |
| `internal` | a bug of the engine; the message says what failed |

## Writing a reader

- Read `schema` first. A document with a **higher** `schema` than you know is refused; the contract only ever **grows**
  inside a version (a field is added, none is removed or changes its meaning).
- **Ignore a field you do not know.** Treat an enum word you do not know as "unknown", not as an error.
- A field that is missing is unknown. Never read it as `0` or `""`.
- Ask `hello` once: `capabilities` says what the engine can answer, `enums` which words exist, `limits` what is kept.
- Use `etag` as the version of a task and `rev` / `digest` to see whether anything changed at all.
- Send requests to a long-running Neovim one at a time (the engine is not re-entrant: a second request that arrives while
  one is being answered is a re-entry). One process per request, as `tasks call` does, needs no care.

## The vault stays the vault

The documents are built from files anyone may have edited or synced, so the read side keeps to the vault:

- **A link is not followed.** A task file that is a symbolic link or a junction is not read (it is an invalid task with
  the finding `symlink-task`, no `etag`, no body, and it is in `unlisted`); a `ROADMAP`, `tasks`, `Backlog` or `plans`
  folder whose real path is outside the vault is not read and is reported in `incomplete`; a folder of the vault root that
  is a link is no area. A vault that itself lies below a link (`/var` on macOS) is fine: it is the links *inside* it
  that count. `tasks check` reports the first as `symlink-task` (an error).
- **A ref is no way to ask about any file.** For `--stale=refs`, a `refs:` entry that is a network or device path
  (`\\server\share\x`, `//server/share/x`, `\\?\C:\x`, `\\.\pipe\x`) is skipped: a stat on it makes Windows connect to a
  host the task's author chose. An **absolute** ref is looked up only inside the places the engine was told to look in
  (the folders that hold the repos, the nvim config, the vault, `extra_bases`), after its `..` are resolved; anywhere else
  it is "found nowhere". The documents never run `--stale=refs`; `refs` is shown as written, with absolute entries as
  `<external>/<name>`.
- A file bigger than 2 MiB, a FIFO or a directory named `x.md` is an invalid task (`unreadable`), never a stall.

## Schemas, golden files, checks

| | |
|---|---|
| `schemas/tasks-export/1/tasks-export.schema.json` | JSON Schema (draft 2020-12), `oneOf` by `kind`, shared pieces in `$defs` |
| `schemas/tasks-export/1/tasks-export.d.ts` | the TypeScript types generated from it (`json-schema-to-typescript` 16; no tuples: the generator does not understand `prefixItems`) |
| `TESTS/golden/tasks-export-1/*.json` | the documents of the synthetic fixture vault (`TESTS/contract_fixture.lua`), byte for byte: a change of one is a change of the contract |
| `TESTS/tasks_contract_spec.lua`, `TESTS/tasks_cli_contract_spec.lua`, `TESTS/tasks_ops_spec.lua` | the Lua side: every document against the golden files, the dispatcher, the command line, the write door (every operation, conflicts, dry runs, limits, two writers at once in two processes) |
| `contract/check.mjs` | the outside view (Node 22): every golden document validates (Ajv, strict), 23 broken documents are refused, the reader rules hold, the `.d.ts` equals the generated one |

```sh
nvim --headless -u NONE -l TESTS/golden/regenerate.lua     # on purpose; read `git diff TESTS/golden`, commit with the code
cd contract && npm ci && node check.mjs                    # `--write` regenerates the .d.ts
scripts/test.sh                                            # the Lua specs
```

The CI job `contract` runs the Node checks next to the Lua suite.

Size against a real vault (about 620 open tasks, read only): the snapshot is ~800 KB and takes about one second from a
cold process (Neovim's start included); a page of `list` is a few KB.
