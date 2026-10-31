---@module 'tasks_nvim.cli'
---@brief Command-line front end of the task engine: `list`, `index`, `new`, `set`, `done`, `attach`, `folderize`, `check`, `template`, `areas`, `export`.
---@description
--- `run(argv, io)` parses one command line, calls the engine and prints plain,
--- tab-separated lines; it returns the exit code and never raises. The
--- headless entry `scripts/tasks.lua` is a three-line wrapper around it, so a
--- Claude session without a running Neovim creates and finishes tasks the same
--- way the editor commands will (rule R12).
---
--- Exit codes: 0 success; 1 a finding, a stale index in `--check`, or a failed
--- operation; 2 a usage error.
---
--- Key responsibilities:
---  - argument parsing (`--key=value`, `--flag`, `key=value` for `set`) with
---    unknown options reported instead of ignored
---  - one function per subcommand, each a thin call into `vault`/`scan`/`index`/
---    `mutate`/`check`
---
--- Not its job: any logic of its own about tasks. If something here grows a
--- rule, it belongs in the engine module it calls.

local check = require("tasks_nvim.check")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local done_flow = require("tasks_nvim.done_flow")
local estimate = require("tasks_nvim.estimate")
local contract_cli = require("tasks_nvim.cli_contract")
---@type Tasks.CliContractHelpers
local contract_helpers = {}
local lists = require("tasks_nvim.lists")
local quick_wins = require("tasks_nvim.quick_wins")
local fsio = require("tasks_nvim.fsio")
local mutate = require("tasks_nvim.mutate")
local questions = require("tasks_nvim.questions")
local next_pick = require("tasks_nvim.next_pick")
local plan_scope = require("tasks_nvim.plan_scope")
local plan_view = require("tasks_nvim.plan_view")
local scan = require("tasks_nvim.scan")
local staleness = require("tasks_nvim.staleness")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.CliIO
---@field out fun(text: string)   # Written verbatim (callers add the newline).
---@field err fun(text: string)
---@field stdin? file*   # Where `-` reads from (default `io.stdin`).

---@type Tasks.CliIO
M.stdio = {
  out = function(text)
    io.stdout:write(text)
  end,
  err = function(text)
    io.stderr:write(text)
  end,
}

local USAGE = [[
usage: nvim --headless -u NONE -l scripts/tasks.lua <command> [args]

commands:
  list [<area>] [--status=a,b] [--prio=1,2|<=2] [--effort=S,M|<=M] [--kind=k] [--tag=t]
       [--category=c,d] [--severity=high,critical] [--value=4,5|>=4] [--actor=cdx,me,pair,none]
       [--stale=<days>|refs] [--stale-refs] [--blocked] [--reminders] [--ready|--waiting] [--unestimated] [--quick-win]
       [--sheet=red,stale,never,inbox,manual,green,unknown|any]
       [--sort=default|prio-effort|severity|frecency|roi] [--format=tsv|ids|json] [--done]   open tasks, sorted; one line each
       (--format=json: the tasks.list document in plan order or that of --sort, with [--limit=1..100] [--offset=N]; --done: the finished tasks)
       (categories: @CATEGORIES@; --category=bug also finds kind=bug;
        --sort=prio-effort: small first within a prio; --sort=severity: critical first;
        --sort=roi: most value per effort first, tasks without value or effort last;
        --actor=me also finds status=decision and the tag needs-user; none = nobody classified it;
        --sort=frecency: what the dashboard opened or changed most, from the frecency file)
       (--ready: nothing open blocks it; --waiting: an open blocker; --unestimated: no effort or no value;
        --quick-win: value and effort at the quick-win thresholds, see `quickwins`;
        --reminders: a reminder (`remind:`) that is due, its date is today or earlier;
        --sheet: the state of the test-sheet block testing.nvim wrote into the task, its worst sheet (inbox:
        green and waiting for your judgement), any: a task with the block; nothing is run)
  plan-new <area> <title> [--areas=a,b] [--target=<id>] [--phases=a,b,c] [--gate=hard] [--summary=text]
                                          create ROADMAP/plans/<slug>.md; tasks join it with plan=<id> phase=<word>
  plan [<area>] [--for=<id>|--plan=<id>] [filters as for list] [--ready] [--with-steps] [--format=md|tsv|ids]
       [--write=<file> [--scope=<name>] [--check] ]   replace only the generated block of a document
                                          stages, ready tasks, decisions by leverage, critical path
                                          (--for: the task and everything that has to be finished before it)
  next [<area>] [--n=3] [--actor=cdx|me|pair|none] [--format=text|json]   the best ready tasks, with the reason
  call <method> [--params=<json>|-] [--pretty]   the machine contract (tasks-export/1): hello, snapshot, list, task, next,
                                          areas, done_preview and ops (the write door); `-` reads the JSON from stdin; the document
                                          on stdout, a tasks.error on failure (exit 1, 2 for a bad request)
  --capabilities                          the handshake document (call hello)
  show <area>/<slug> [--format=text|json]   one task: fields, readiness, body
  plans [<area>]                          the plan files: id, status, location, title
  estimate [<area>] [--for=<id>] [filters as for list]   sums of effort and value, what is missing, quick wins
  list|plan|estimate @<name> [more options]   run a named list (see `lists`); options you give override its own
  lists [save <name>|delete <name>|rename <old> <new>|show <name>] [filters] [--sort=] [--area=] [--desc=]
                                          the named lists (built in, saved, from setup({ lists })); `save` stores the
                                          filters you give under a name, `delete` / `rename` change saved lists only
  quickwins [<area>] [--status=a,b] [--prio=..] [--kind=k] [--tag=t] [--category=c,d] [--actor=..] [--stale=..] [--plan=<id>]
       [--min-value=1..5] [--max-effort=XS..XL|0.5d] [--format=tsv|md|ids] [--by-actor] [--paths] [--report=<file>]
                                          the quick wins (value >= 4 and effort <= S, both written; thresholds from
                                          setup({ quick_wins })), best return first, plus the small tasks that miss a
                                          value; default status open,doing,decision. --report writes the Markdown
  index [<area>] [--check]                (re)write ROADMAP/TASKS.md; --check only reports
  migrate-actor [<area>] [--write]        propose actor=me for tasks that wait for you (status decision, tag
                                          needs-user) and leave every other task EMPTY; dry run unless --write
  new <area>[,<area>...] <title> [--kind=k] [--prio=1..3] [--effort=XS..XL|0.5d] [--value=1..5] [--actor=cdx|me|pair] [--after=id,id] [--order=2.5] [--plan=id] [--phase=word] [--tags=a,b]
       [--category=c,d] [--severity=low|medium|high|critical] [--refs=path,repo@sha] [--links=https://...,...]
       [--summary=text] [--slug=slug] [--status=s]
       [--lang=de|en] [--folder]             create a task file (--lang: body headings;
                                               --folder: a folder task that can hold assets)
  set <area>/<slug> key=value ...         change frontmatter (empty value removes the key)
  answer <area>/<slug> <q1|#n> <n|clear>  answer a question of the `## Offene Fragen` section: tick option n (1-based),
                                          or take the answer back (clear)
  done <area>/<slug> [--commits=repo@sha,repo@sha] [--done-in=text] [--date=YYYY-MM-DD] [--remind=7d|YYYY-MM-DD]
                                          [--no-next] [--unblock]  (--commits adds to the task's own `commits`)
                                          finish: move to Backlog/; prints the tasks it freed and what to start
                                          next; --unblock sets the freed tasks that still say blocked to open
  attach <area>/<slug> <file> [--name=n]  copy a file to <slug>/assets/ (a plain task becomes a
                                          folder task) and print the Markdown link
  attach <area>/<slug> --clipboard [--name=n]
                                          the image on the clipboard, saved as a PNG named <slug>-<date>-<HHMM>.png
  attach <area>/<slug> --latest[=<folder>] [--name=n]
                                          the newest image of the screenshot folder(s) (config attach.screenshot_dirs),
                                          only when modified within attach.max_age_s (300 s); older: nothing is guessed
  folderize <area>/<slug>                 turn a plain task file into a folder task
  sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]
                                          run the test sheets of a live-check task now: testing.nvim's
                                          `testing sheets run` runs them headless and writes their state into the
                                          task's block (red: the first failure line); its exit code (0 green, 1 red,
                                          2 refused: trust, workstation, no sheet; 3 testing.nvim or the engine
                                          not reached). testing.nvim: --testing-cli, $TESTING_NVIM_DIR,
                                          $REPOS_DIR/testing.nvim, <vault>/../testing.nvim, lazy
  check [<area>]                          rule check; exit 1 on any error
  template [--title=t] [--kind=k] [--prio=n] [--effort=e] [--tags=a,b] [--lang=de|en] [--with-plan]
  ci [--strict] [--no-lint] [--md-lint=<file>] [--trust-vault-lint]   CI gate: check + index --check + md_lint of the
                                          generated indexes; exit 0/1 (--strict: warnings fail too).
                                          md_lint is a script RUN from the vault (TOOLS/scripts/md_lint.lua): it runs only with
                                          --trust-vault-lint (or TASKS_TRUST_VAULT_LINT=1); else --md-lint=<own copy> or --no-lint
  areas [--format=names|tsv|json]        list the vault's areas (tsv: with the open counts, then the area groups as
                                          <name> <open> group <members>; json: the tasks.areas document with area_groups)
                                          (an area group of <vault>/area-groups.json, e.g. nvim = *.nvim, stands for its
                                          member areas wherever list, plan, next, plans, estimate, quickwins take <area>;
                                          new refuses one: a task lives in one area)
  export [--top=N] [--no-links]           all-areas overview as Markdown on stdout (never written)
  import <area> --from-rules=<file|-> [--apply] [--lang=de|en]
                                          a work list of rules.nvim (rules-work-list/1) becomes tasks of the area: one
                                          per rule that fails or nobody judged; a rule with a task (open or finished),
                                          a waived and a passing one get none. A dry run unless --apply
  bootstrap <area> [--from-rules=<file|->] [--apply] [--lang=de|en]
                                          make the area (folders, READMEs, index; nothing overwritten), then import;
                                          a dry run unless --apply
  init-vault <dir> [--area=<name>] [--lang=de|en] [--force] [--apply]
                                          a new vault in <dir>: README, a first area (default Inbox) and an example
                                          task; nothing overwritten; a dry run unless --apply (try examples/vault first)

global options: --vault=<dir> (default: $TASKS_VAULT; no built-in default path)
                --today=YYYY-MM-DD (for reproducible runs); --no-index on new/set/done
]]
-- The category words come from the model, so --help, `new --category`, `set` and `check` never disagree.
USAGE = USAGE:gsub("@CATEGORIES@", function()
  return table.concat(model.CATEGORIES, " ")
end)

---@class Tasks.CliSpec
---@field value string[]   # Options that need `=value`.
---@field flag string[]    # Options without a value.

---@type table<string, Tasks.CliSpec>
local SPECS = {
  list = {
    value = {
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "value",
      "actor",
      "stale",
      "plan",
      "phase",
      "sort",
      "format",
      "limit",
      "offset",
      "sheet",
    },
    flag = {
      "blocked",
      "all",
      "done",
      "reminders",
      "stale-refs",
      "ready",
      "waiting",
      "unestimated",
      "quick-win",
    },
  },
  plan = {
    value = {
      "for",
      "plan",
      "write",
      "scope",
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "value",
      "actor",
      "stale",
      "phase",
      "format",
    },
    flag = { "blocked", "stale-refs", "ready", "unestimated", "with-steps", "check", "quick-win" },
  },
  estimate = {
    value = {
      "for",
      "plan",
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "value",
      "actor",
      "stale",
      "phase",
    },
    flag = { "blocked", "stale-refs", "unestimated", "quick-win" },
  },
  lists = {
    value = {
      "status",
      "prio",
      "effort",
      "kind",
      "category",
      "severity",
      "value",
      "actor",
      "tag",
      "stale",
      "plan",
      "phase",
      "sort",
      "desc",
      "area",
    },
    flag = { "blocked", "reminders", "stale-refs", "unestimated", "quick-win", "ready", "waiting" },
  },
  quickwins = {
    value = {
      "plan",
      "status",
      "prio",
      "kind",
      "tag",
      "category",
      "severity",
      "actor",
      "stale",
      "min-value",
      "max-effort",
      "format",
      "report",
    },
    flag = { "blocked", "stale-refs", "unestimated", "by-actor", "paths" },
  },
  next = { value = { "n", "actor", "format" }, flag = {} },
  ["plan-new"] = {
    value = { "areas", "target", "phases", "gate", "status", "summary", "slug", "title" },
    flag = {},
  },
  index = { value = {}, flag = { "check", "all" } },
  new = {
    value = {
      "kind",
      "prio",
      "effort",
      "tags",
      "category",
      "severity",
      "value",
      "actor",
      "after",
      "order",
      "plan",
      "phase",
      "refs",
      "links",
      "lang",
      "summary",
      "slug",
      "status",
      "title",
    },
    flag = { "no-index", "folder" },
  },
  set = { value = {}, flag = { "no-index" } },
  answer = { value = {}, flag = { "no-index" } },
  ["migrate-actor"] = { value = {}, flag = { "write", "no-index" } },
  done = {
    value = { "done-in", "commits", "date", "remind" },
    flag = { "no-index", "no-next", "unblock" },
  },
  -- `latest` is both: `--latest` (the configured screenshot folders) and `--latest=<folder>`.
  attach = { value = { "name", "latest" }, flag = { "no-index", "clipboard", "latest" } },
  folderize = { value = {}, flag = { "no-index" } },
  ["sheet-run"] = { value = { "testing-cli" }, flag = { "dry-run" } },
  check = { value = {}, flag = { "all" } },
  ci = { value = { "md-lint" }, flag = { "strict", "no-lint", "trust-vault-lint" } },
  template = {
    value = { "title", "kind", "prio", "effort", "tags", "lang" },
    flag = { "with-plan" },
  },
  areas = { value = { "format" }, flag = {} },
  export = { value = { "top", "link-prefix" }, flag = { "no-links" } },
  import = { value = { "from-rules", "lang" }, flag = { "apply", "dry-run" } },
  bootstrap = { value = { "from-rules", "lang" }, flag = { "apply", "dry-run" } },
  ["init-vault"] = { value = { "area", "lang" }, flag = { "apply", "dry-run", "force" } },
}

local GLOBAL_VALUE = { "vault", "today" }

---@class Tasks.CliArgs
---@field pos string[]
---@field opt table<string, string|boolean>

---@param argv string[]
---@param spec Tasks.CliSpec
---@return Tasks.CliArgs|nil args
---@return string|nil err
local function parse_args(argv, spec)
  local value, flag = {}, { help = true }
  for _, k in ipairs(spec.value) do
    value[k] = true
  end
  for _, k in ipairs(GLOBAL_VALUE) do
    value[k] = true
  end
  for _, k in ipairs(spec.flag) do
    flag[k] = true
  end
  local pos, opt = {}, {}
  local options_done = false
  for _, token in ipairs(argv) do
    if options_done or token:sub(1, 2) ~= "--" then
      pos[#pos + 1] = token
    elseif token == "--" then
      options_done = true
    else
      local name, val = token:match("^%-%-([%w][%w-]*)=(.*)$")
      if name then
        if not value[name] then
          return nil, "unknown or valueless option: --" .. name
        end
        opt[name] = val
      else
        name = token:sub(3)
        if flag[name] then
          opt[name] = true
        elseif value[name] then
          return nil, ("option needs a value: --%s=<value>"):format(name)
        else
          return nil, "unknown option: " .. token
        end
      end
    end
  end
  -- An empty `--vault=` (a shell variable that was not set) must not quietly mean "the default
  -- vault": a command meant for a scratch copy would write to the real one.
  for _, k in ipairs(GLOBAL_VALUE) do
    if opt[k] == "" then
      return nil, ("option needs a value: --%s=<value>"):format(k)
    end
  end
  return { pos = pos, opt = opt }, nil
end

local filter_opts = require("tasks_nvim.filter_opts")
local split_commas = filter_opts.split_commas

---Make a line safe to print: terminal control characters (ESC and the other C0 controls, DEL,
---a lone CR, the 8-bit C1 controls such as the CSI `U+009B`) become `?`. A task title comes
---from a file anyone may have edited, and it would otherwise reach the terminal verbatim.
---Tab and newline stay: they are the output format.
---@param text string
---@return string
local function clean(text)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("[%z\1-\8\11-\31\127]", "?")
  text = text:gsub("\194[\128-\159]", "?")
  return text
end

---@param value string
---@param what string
---@return integer|nil
---@return string|nil err
local function to_int(value, what)
  if not value:match("^%d+$") then
    return nil, ("%s must be a whole number, got '%s'"):format(what, value)
  end
  return tonumber(value), nil
end

---The filter options as `filter_opts.parse` takes them (also what a marker block records).
---@param opt table<string, string|boolean>
---@return table
local function filter_option_map(opt)
  return {
    status = opt.status --[[@as string|nil]],
    prio = opt.prio --[[@as string|nil]],
    effort = opt.effort --[[@as string|nil]],
    kind = opt.kind --[[@as string|nil]],
    tag = opt.tag --[[@as string|nil]],
    category = opt.category --[[@as string|nil]],
    severity = opt.severity --[[@as string|nil]],
    value = opt.value --[[@as string|nil]],
    actor = opt.actor --[[@as string|nil]],
    stale = opt.stale --[[@as string|nil]],
    stale_refs = opt["stale-refs"] == true,
    plan = opt.plan --[[@as string|nil]],
    phase = opt.phase --[[@as string|nil]],
    blocked = opt.blocked == true,
    reminders = opt.reminders == true,
    unestimated = opt.unestimated == true,
    quick_win = opt["quick-win"] == true,
    sheet = opt.sheet --[[@as string|nil]],
    today = opt.today --[[@as string|nil]],
  }
end

---Turn the filter options into a `Tasks.Filter` (the parsing itself is shared
---with the editor commands: `filter_opts.parse`).
---@param opt table<string, string|boolean>
---@return Tasks.Filter|nil filter
---@return string|nil err
local function filter_from(opt)
  return filter_opts.parse(filter_option_map(opt))
end

---@param opt table<string, string|boolean>
---@return table opts  engine options shared by every command
local function engine_opts(opt)
  return {
    root = opt.vault --[[@as string|nil]],
    today = opt.today --[[@as string|nil]],
  }
end

---@param s any
---@return string
local function cellv(s)
  if s == nil or s == "" then
    return "-"
  end
  return (tostring(s):gsub("[\t\r\n]+", " "))
end

---@class Tasks.CliCtx
---@field io Tasks.CliIO
---@field args Tasks.CliArgs
---@field say fun(line: string)
---@field warn fun(line: string)
---@field out fun(text: string)   # Like `io.out`, with control characters cleaned.
---@field eo table

---@type table<string, fun(ctx: Tasks.CliCtx): integer>
local commands = {}

function commands.list(ctx)
  local args, eo = ctx.args, ctx.eo
  local filter, ferr = filter_from(args.opt)
  if not filter then
    ctx.warn("error: " .. ferr)
    return 2
  end
  filter.ref_opts = { root = eo.root }
  local order, serr = model.parse_sort(args.opt.sort)
  if not order then
    ctx.warn("error: " .. serr)
    return 2
  end
  local format = args.opt.format or "tsv"
  if format ~= "tsv" and format ~= "ids" and format ~= "json" then
    ctx.warn("error: --format must be tsv, ids or json")
    return 2
  end
  if #args.pos > 1 then
    ctx.warn("error: list takes at most one area")
    return 2
  end
  if format ~= "json" and (args.opt.limit ~= nil or args.opt.offset ~= nil) then
    ctx.warn("error: --limit and --offset go with --format=json")
    return 2
  end
  if
    args.opt.done and (format == "json" or args.opt.ready or args.opt.waiting or args.opt.sort)
  then
    ctx.warn(
      "error: --done lists the finished tasks as tsv or ids; it takes no --sort, --ready, --waiting or json form"
    )
    return 2
  end

  local area
  -- `all` means every area, as it does for plan, next and estimate
  if args.pos[1] == "all" then
    args.pos[1] = nil
  end
  if args.pos[1] and not args.opt.all then
    local root, rerr = vault.root(eo)
    if not root then
      ctx.warn("error: " .. tostring(rerr))
      return 1
    end
    -- an area group (`list nvim`) is a filter name like an area
    if not vault.area_scope(root, args.pos[1]) then
      ctx.warn("error: unknown area: " .. args.pos[1])
      return 1
    end
    area = args.pos[1]
  end
  if args.opt.done then
    return contract_cli.list_done(ctx, filter, area, format, contract_helpers)
  end
  if format == "json" then
    return contract_cli.list_json(ctx, filter, area, contract_helpers)
  end
  local open, skipped, errors = scan.open_tasks(vim.tbl_extend("force", eo, { area = area }))
  if not open then
    ctx.warn("error: " .. tostring(skipped))
    return 1
  end
  -- `--stale=refs`: the second result of `model.filter` is the report that names the changed files.
  local filtered, report = model.filter(open, filter)
  if args.opt.ready or args.opt.waiting then
    if args.opt.ready and args.opt.waiting then
      ctx.warn("error: --ready and --waiting exclude each other")
      return 2
    end
    -- The same definition of "ready" as the plan, the dashboard and `next`.
    local kept, kerr =
      plan_scope.filter_readiness(filtered, args.opt.ready and "ready" or "waiting", eo.root)
    if not kept then
      ctx.warn("error: " .. tostring(kerr))
      return 1
    end
    filtered = kept
  end
  local shown = model.sort(filtered, order)
  for _, t in ipairs(shown) do
    if format == "ids" then
      ctx.say(fsio.clean(t.id))
    else
      local cells = {
        fsio.clean(t.id),
        cellv(t.status),
        cellv(t.prio),
        cellv(t.effort),
        cellv(t.kind),
        cellv(t.updated or t.created),
        cellv(t.title),
      }
      if report then
        cells[#cells + 1] = "changed: " .. staleness.describe(report.stale[t.id] or {}, 5)
      end
      ctx.say(table.concat(cells, "\t"))
    end
  end
  if report then
    for _, note in ipairs(report.notes) do
      ctx.warn("note: " .. note)
    end
    ctx.warn(
      ("note: --stale=refs checked %d file(s) of %d task(s); %d ref(s) found nowhere, %d skipped (commits, anchors, undated)"):format(
        report.files,
        report.tasks,
        report.unresolved,
        report.skipped
      )
    )
  end
  if skipped > 0 then
    ctx.warn(
      ("note: %d task file(s) not listed (missing or unknown status, or done); run `check`"):format(
        skipped
      )
    )
  end
  if type(errors) == "table" and #errors > 0 then
    for _, e in ipairs(errors) do
      ctx.warn("warn: cannot read directory " .. e)
    end
    return 1
  end
  return 0
end

---The area argument shared by `plan`, `next` and `estimate`: an area or an area group.
---@param ctx Tasks.CliCtx
---@param name string  The command, for the message.
---@return string|nil area
---@return boolean ok
local function area_arg(ctx, name)
  local given = ctx.args.pos[1]
  if #ctx.args.pos > 1 then
    ctx.warn("error: " .. name .. " takes at most one area")
    return nil, false
  end
  if not given then
    return nil, true
  end
  local root, rerr = vault.root(ctx.eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return nil, false
  end
  if not vault.area_scope(root, given) then
    ctx.warn("error: unknown area: " .. given)
    return nil, false
  end
  return given, true
end

---@param ctx Tasks.CliCtx
---@param name string
---@return Tasks.PlanScope|nil scope
---@return integer|nil code  # Set when the command must stop.
local function load_scope(ctx, name)
  local area, ok = area_arg(ctx, name)
  if not ok then
    return nil, 2
  end
  local filter, ferr = filter_from(ctx.args.opt)
  if not filter then
    ctx.warn("error: " .. ferr)
    return nil, 2
  end
  filter.ref_opts = { root = ctx.eo.root }
  local scope, err = plan_scope.load({
    root = ctx.eo.root,
    area = area,
    for_id = ctx.args.opt["for"] --[[@as string|nil]],
    plan_id = ctx.args.opt.plan --[[@as string|nil]],
    filter = filter,
  })
  if not scope then
    ctx.warn("error: " .. tostring(err))
    return nil, 1
  end
  for _, e in ipairs(scope.errors) do
    ctx.warn("warn: cannot read directory " .. e)
  end
  return scope, nil
end

---`plan --write=<file>`: replace only the marker block of the scope in a hand-written document (`--check`: report
---whether it is out of date and write nothing).
---@param ctx Tasks.CliCtx
---@param scope Tasks.PlanScope
---@param path string
---@return integer code
local function write_plan_block(ctx, scope, path)
  local opt = ctx.args.opt
  local key = opt.scope --[[@as string|nil]]
    or plan_view.default_scope({
      area = ctx.args.pos[1],
      for_id = opt["for"] --[[@as string|nil]],
      plan_id = opt.plan --[[@as string|nil]],
    })
  ---@type string|nil
  local area = ctx.args.pos[1]
  if area == "all" then
    area = nil
  end
  -- The marker records how the block was made (target, view, filters): the refresh after a finish builds the same.
  local attrs, aerr = plan_scope.marker_attrs(
    filter_option_map(opt),
    { ready = opt.ready == true, steps = opt["with-steps"] == true },
    {
      area = area,
      plan_id = opt.plan --[[@as string|nil]],
      for_id = opt["for"] --[[@as string|nil]],
      root = ctx.eo.root,
    },
    key
  )
  if not attrs then
    ctx.warn("error: " .. tostring(aerr))
    return 2
  end
  local res, err =
    plan_scope.write_block(path, scope, { key = key, attrs = attrs, check = opt.check == true })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("%s\t%s"):format(res.state, path))
  return res.state == "stale" and 1 or 0
end

function commands.plan(ctx)
  local format = ctx.args.opt.format or "md"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    ctx.warn("error: --format must be md, tsv or ids")
    return 2
  end
  local scope, code = load_scope(ctx, "plan")
  if not scope then
    return code or 1
  end
  local ready_only = ctx.args.opt.ready == true
  local write_to = ctx.args.opt.write --[[@as string|nil]]
  if write_to then
    return write_plan_block(ctx, scope, fsio.doc_path(write_to))
  end
  if ctx.args.opt.check then
    ctx.warn("error: --check goes with --write=<file>")
    return 2
  end
  if format == "ids" then
    for _, id in ipairs(plan_view.ids(scope.plan, { ready_only = ready_only })) do
      ctx.say(fsio.clean(id))
    end
  elseif format == "tsv" then
    for _, line in ipairs(plan_view.tsv(scope.plan, { ready_only = ready_only })) do
      ctx.say(line)
    end
  else
    ctx.out(plan_view.markdown(scope.plan, {
      title = scope.title,
      today = ctx.eo.today or model.today(),
      done = scope.done,
      ready_only = ready_only,
      with_steps = ctx.args.opt["with-steps"] == true,
      plan_file = scope.plan_file,
    }))
  end
  return #scope.errors > 0 and 1 or 0
end

function commands.estimate(ctx)
  local scope, code = load_scope(ctx, "estimate")
  if not scope then
    return code or 1
  end
  local sums = estimate.rollup(scope.tasks, { done = scope.done })
  ctx.say(estimate.describe(sums))
  if #sums.quick_wins > 0 then
    ctx.say("quick wins: " .. table.concat(sums.quick_wins, ", "))
  end
  if #sums.unestimated > 0 then
    ctx.say(("unestimated: %d (list them: list --unestimated)"):format(#sums.unestimated))
  end
  return #scope.errors > 0 and 1 or 0
end

---The quick-win thresholds of one run: the config, then `--min-value` / `--max-effort` over it.
---@param opt table<string, string|boolean>
---@return Tasks.QuickWinThresholds|nil th
---@return string|nil err
local function quick_win_thresholds(opt)
  local th = estimate.thresholds()
  if opt["min-value"] ~= nil then
    local v = model.to_value(opt["min-value"])
    if not v then
      return nil, "--min-value must be 1..5, got " .. tostring(opt["min-value"])
    end
    th.value = v
  end
  if opt["max-effort"] ~= nil then
    local raw = tostring(opt["max-effort"])
    local norm = raw:match("^%a+$") and raw:upper() or raw:lower()
    local days = model.effort_days(norm)
    if not days then
      return nil, "--max-effort must be XS..XL or days like 0.5d, got " .. raw
    end
    th.effort, th.days = norm, days
  end
  return th, nil
end

function commands.quickwins(ctx)
  local opt = ctx.args.opt
  local format = opt.format or "tsv"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    ctx.warn("error: --format must be md, tsv or ids")
    return 2
  end
  local th, terr = quick_win_thresholds(opt)
  if not th then
    ctx.warn("error: " .. tostring(terr))
    return 2
  end
  if opt.status == nil then
    -- A parked or blocked task is not something to start: the default is what can be picked up.
    opt.status = "open,doing,decision"
  end
  local scope, code = load_scope(ctx, "quickwins")
  if not scope then
    return code or 1
  end
  local report = quick_wins.build(scope.tasks, th)
  local text_opts =
    { title = scope.title, by_actor = opt["by-actor"] == true, paths = opt.paths == true }
  local rc = #scope.errors > 0 and 1 or 0
  if opt.report then
    local ok, where = quick_wins.write(tostring(opt.report), quick_wins.markdown(report, text_opts))
    if not ok then
      ctx.warn("error: " .. where)
      return 1
    end
    ctx.say("wrote\t" .. where)
    return rc
  end
  if format == "ids" then
    for _, id in ipairs(quick_wins.ids(report)) do
      ctx.say(id)
    end
  elseif format == "md" then
    ctx.out(quick_wins.markdown(report, text_opts))
  else
    for _, line in ipairs(quick_wins.tsv(report)) do
      ctx.say(line)
    end
  end
  return rc
end

---The list a `lists save` stores: the filter words of the command line as a definition.
---@param opt table<string, string|boolean>
---@return Tasks.ListDef
local function def_from_options(opt)
  local def = {}
  for _, key in ipairs({
    "status",
    "prio",
    "effort",
    "kind",
    "category",
    "severity",
    "value",
    "actor",
    "tag",
    "stale",
    "plan",
    "phase",
    "sort",
    "desc",
    "area",
  }) do
    if opt[key] ~= nil then
      def[key] = tostring(opt[key])
    end
  end
  def.blocked = opt.blocked == true or nil
  def.reminders = opt.reminders == true or nil
  def.unestimated = opt.unestimated == true or nil
  def.stale_refs = opt["stale-refs"] == true or nil
  def.quick_win = opt["quick-win"] == true or nil
  if opt.ready and opt.waiting then
    def.readiness = "both"
  else
    def.readiness = (opt.ready and "ready") or (opt.waiting and "waiting") or nil
  end
  return def
end

---Does the command take this option word (`--effort` is `value`, `--blocked` is `flag`)?
---@param spec Tasks.CliSpec
---@param flag string
---@return boolean
local function takes(spec, flag)
  return vim.tbl_contains(spec.value, flag) or vim.tbl_contains(spec.flag, flag)
end

---`list|plan|estimate @<name>`: the named list's options under the ones given on the command line (a word you
---typed wins), its area when no area was typed. A word of the list the command has no use for is an error, never
---dropped (`estimate @small-and-important` must not quietly leave out "startable"); only `sort` may be left over,
---it is a way to order, not a way to select.
---@param args { pos: string[], opt: table }
---@param name string
---@param command string
---@return string|nil err
local function apply_list(args, name, command)
  local entry, err = lists.get(name)
  if not entry then
    return err
  end
  local resolved, rerr = lists.resolve(entry.def)
  if not resolved then
    return rerr
  end
  local spec = SPECS[command]
  ---@type { flag: string, value: any }[]
  local overlay = {}
  for key, value in pairs(entry.def) do
    if key == "readiness" then
      overlay[#overlay + 1] = { flag = value, value = true }
    elseif key ~= "desc" and key ~= "area" then
      local flag = key:gsub("_", "-")
      if key == "stale_refs" and not takes(spec, flag) then
        -- `--stale=refs` is the same filter where the flag itself does not exist
        overlay[#overlay + 1] = { flag = "stale", value = "refs" }
      else
        overlay[#overlay + 1] = { flag = flag, value = value == true and true or tostring(value) }
      end
    end
  end
  for _, o in ipairs(overlay) do
    if o.flag ~= "sort" and not takes(spec, o.flag) then
      return ("list '%s' sets --%s, which `%s` does not take"):format(name, o.flag, command)
    end
  end
  table.remove(args.pos, 1)
  for _, o in ipairs(overlay) do
    if o.flag == "ready" or o.flag == "waiting" then
      if args.opt.ready == nil and args.opt.waiting == nil then
        args.opt[o.flag] = true
      end
    elseif args.opt[o.flag] == nil then
      args.opt[o.flag] = o.value
    end
  end
  if entry.def.area and args.pos[1] == nil then
    args.pos[1] = entry.def.area
  end
  return nil
end

---@param ctx Tasks.CliCtx
---@return integer code
function commands.lists(ctx)
  local args = ctx.args
  local sub = args.pos[1]
  if sub == nil or sub == "ls" then
    local entries, notes = lists.all()
    for _, e in ipairs(entries) do
      ctx.say(table.concat({ e.name, e.source, lists.summary(e.def) }, "\t"))
    end
    for _, n in ipairs(notes) do
      ctx.warn("warn: " .. n)
    end
    return 0
  end
  local name = args.pos[2]
  if sub == "show" then
    if not name or #args.pos > 2 then
      ctx.warn("error: usage: lists show <name>")
      return 2
    end
    local entry, err = lists.get(name)
    if not entry then
      ctx.warn("error: " .. err)
      return 1
    end
    ctx.say(("%s\t%s"):format(entry.name, entry.source))
    if entry.def.desc then
      ctx.say("desc: " .. fsio.clean(entry.def.desc))
    end
    ctx.say(
      "tasks list "
        .. (entry.def.area and (entry.def.area .. " ") or "")
        .. table.concat(lists.words(entry.def), " ")
    )
    return 0
  elseif sub == "save" then
    if not name or #args.pos > 2 then
      ctx.warn("error: usage: lists save <name> [filters] [--sort=] [--area=] [--desc=]")
      return 2
    end
    local def = def_from_options(args.opt)
    if def.readiness == "both" then
      ctx.warn("error: --ready and --waiting exclude each other")
      return 2
    end
    local saved, err = lists.save(name, def)
    if not saved then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    ctx.say(("saved\t%s\t%s"):format(name, lists.path()))
    return 0
  elseif sub == "delete" then
    if not name or #args.pos > 2 then
      ctx.warn("error: usage: lists delete <name>")
      return 2
    end
    local deleted, err = lists.delete(name)
    if not deleted then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    ctx.say(("deleted\t%s"):format(name))
    return 0
  elseif sub == "rename" then
    if not name or not args.pos[3] or #args.pos > 3 then
      ctx.warn("error: usage: lists rename <old> <new>")
      return 2
    end
    local renamed, err = lists.rename(name, args.pos[3])
    if not renamed then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    ctx.say(("renamed\t%s\t%s"):format(name, args.pos[3]))
    return 0
  end
  ctx.warn("error: unknown lists command: " .. tostring(sub) .. " (save, delete, rename, show)")
  return 2
end

commands["plan-new"] = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local area = args.pos[1]
  local title = args.pos[2] or args.opt.title
  if not area or not title or #args.pos > 2 then
    ctx.warn(
      'error: usage: plan-new <area> "<title>" [--areas=a,b] [--target=id] [--phases=a,b,c] [--gate=hard]'
    )
    return 2
  end
  local res, err = require("tasks_nvim.plans").new(area, {
    root = eo.root,
    today = eo.today,
    title = title,
    areas = args.opt.areas --[[@as string|nil]],
    target = args.opt.target --[[@as string|nil]],
    phases = args.opt.phases --[[@as string|nil]],
    gate = args.opt.gate --[[@as string|nil]],
    status = args.opt.status --[[@as string|nil]],
    summary = args.opt.summary --[[@as string|nil]],
    slug = args.opt.slug --[[@as string|nil]],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("created\t%s\t%s"):format(res.id, res.path))
  if res.ambiguous then
    ctx.warn("warn: " .. require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
  end
  return 0
end

commands["next"] = function(ctx)
  local area, ok = area_arg(ctx, "next")
  if not ok then
    return 2
  end
  local count = 3
  if ctx.args.opt.n then
    local n, nerr = to_int(ctx.args.opt.n --[[@as string]], "--n")
    if not n or n < 1 then
      ctx.warn("error: " .. (nerr or "--n must be at least 1"))
      return 2
    end
    count = n
  end
  local actor = ctx.args.opt.actor --[[@as string|nil]]
  if actor and not (model.is_actor(actor) or actor == "none") then
    ctx.warn("error: unknown actor in --actor: " .. actor .. " (expected cdx, me, pair or none)")
    return 2
  end
  local format = ctx.args.opt.format or "text"
  if format ~= "text" and format ~= "json" then
    ctx.warn("error: --format must be text or json")
    return 2
  end
  if ctx.eo.today ~= nil and not model.is_date(ctx.eo.today) then
    ctx.warn("error: --today must be YYYY-MM-DD, got '" .. tostring(ctx.eo.today) .. "'")
    return 2
  end
  if format == "json" then
    return contract_cli.next_json(ctx, area, count, actor)
  end
  local pick, err = next_pick.pick_from_vault({
    root = ctx.eo.root,
    today = ctx.eo.today,
    reminders = true,
    area = area,
    actor = actor,
    n = count - 1,
  })
  if not pick then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, line in ipairs(plan_view.next_lines(pick)) do
    ctx.say(line)
  end
  for _, e in ipairs(pick.incomplete or {}) do
    ctx.warn("warn: cannot read directory " .. e .. " (the answer may be incomplete)")
  end
  return 0
end

function commands.index(ctx)
  local args, eo = ctx.args, ctx.eo
  if #args.pos > 1 then
    ctx.warn("error: index takes at most one area")
    return 2
  end
  local opts = { root = eo.root, check = args.opt.check == true }
  local results, errors
  if args.pos[1] and not args.opt.all then
    local res, err = index.write_area(args.pos[1], opts)
    results, errors = res and { res } or {}, err and { args.pos[1] .. ": " .. err } or {}
  else
    results, errors = index.write_all(opts)
  end
  if not results then
    ctx.warn("error: " .. tostring(errors[1]))
    return 1
  end

  local counts = { written = 0, removed = 0, unchanged = 0, stale = 0 }
  for _, r in ipairs(results) do
    counts[r.action] = counts[r.action] + 1
    if r.action ~= "unchanged" then
      local reason = r.reason and (" (" .. r.reason .. ")") or ""
      ctx.say(("%s\t%s\t%d open\t%s%s"):format(r.action, r.area, r.open, r.path, reason))
    end
  end
  for _, e in ipairs(errors) do
    ctx.warn("error: " .. e)
  end
  if opts.check then
    ctx.say(
      ("index --check: %d area(s), %d stale, %d error(s)"):format(#results, counts.stale, #errors)
    )
    return (counts.stale > 0 or #errors > 0) and 1 or 0
  end
  ctx.say(
    ("index: %d area(s), %d written, %d removed, %d unchanged, %d error(s)"):format(
      #results,
      counts.written,
      counts.removed,
      counts.unchanged,
      #errors
    )
  )
  return #errors > 0 and 1 or 0
end

---@param ctx Tasks.CliCtx
---@param res table
local function report_index(ctx, res)
  if res.index_err then
    ctx.warn("warn: index not updated: " .. res.index_err)
  elseif res.index and res.index.action ~= "unchanged" then
    ctx.say(("index\t%s\t%s"):format(res.index.action, res.index.path))
  end
end

function commands.new(ctx)
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  local area = args.pos[1]
  local title = args.pos[2] or opt.title
  if not area or not title or #args.pos > 2 then
    ctx.warn('error: usage: new <area> "<title>" [options]')
    return 2
  end
  local new_opts = {
    root = eo.root,
    today = eo.today,
    title = title,
    kind = opt.kind --[[@as string|nil]],
    prio = opt.prio --[[@as string|nil]],
    effort = opt.effort --[[@as string|nil]],
    tags = opt.tags --[[@as string|nil]],
    category = opt.category --[[@as string|nil]],
    severity = opt.severity --[[@as string|nil]],
    value = opt.value --[[@as string|nil]],
    actor = opt.actor --[[@as string|nil]],
    after = opt.after --[[@as string|nil]],
    order = opt.order --[[@as string|nil]],
    plan = opt.plan --[[@as string|nil]],
    phase = opt.phase --[[@as string|nil]],
    refs = opt.refs --[[@as string|nil]],
    web_links = opt.links --[[@as string|nil]],
    lang = opt.lang --[[@as "de"|"en"|nil]],
    summary = opt.summary --[[@as string|nil]],
    slug = opt.slug --[[@as string|nil]],
    status = opt.status --[[@as string|nil]],
    folder = opt.folder == true,
    index = not opt["no-index"],
  }
  -- `a,b`: one task in each area, the same text in all; every area is tried as a dry run first, so a bad one
  -- stops the whole thing before anything is written
  local made, merr = mutate.new_many(area, new_opts)
  if not made then
    ctx.warn("error: " .. tostring(merr))
    return 1
  end
  for _, res in ipairs(made) do
    ctx.say(("created\t%s\t%s"):format(res.id, res.path))
    if res.ambiguous then
      ctx.warn("warn: " .. require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
    end
    report_index(ctx, res)
  end
  return 0
end

function commands.set(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos < 2 then
    ctx.warn("error: usage: set <area>/<slug> key=value [key=value ...]")
    return 2
  end
  local patch = {}
  for i = 2, #args.pos do
    local key, value = args.pos[i]:match("^([%w_]+)=(.*)$")
    if not key then
      ctx.warn("error: expected key=value, got " .. args.pos[i])
      return 2
    end
    patch[key] = value == "" and mutate.REMOVE or value
  end
  if patch.status == "doing" then
    -- A guard rail, not a lock (nothing is refused because of plan or meta fields): a headless session that
    -- starts a task marked for the human gets told.
    local current = scan.find(id, { root = eo.root })
    if current and model.actor(current) == "me" then
      ctx.warn(
        ("warn: %s is for you (actor: me); a headless session should not start it"):format(id)
      )
    end
  end
  local res, err = mutate.set(id, patch, {
    root = eo.root,
    today = eo.today,
    index = not args.opt["no-index"],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("set\t%s\t%s\t%s"):format(res.id, res.changed and "changed" or "unchanged", res.path))
  report_index(ctx, res)
  return 0
end

function commands.answer(ctx)
  local args, eo = ctx.args, ctx.eo
  local id, question, choice = args.pos[1], args.pos[2], args.pos[3]
  if not id or not question or not choice or #args.pos > 3 then
    ctx.warn("error: usage: answer <area>/<slug> <q1|#n> <n|clear>")
    return 2
  end
  local option = choice == "clear" and 0 or tonumber(choice)
  if option == nil or option % 1 ~= 0 or option < 0 then
    ctx.warn("error: the option is a whole number from 1, or `clear`")
    return 2
  end
  local res, err = mutate.edit_text(id, function(text)
    local new_text, info, qerr = questions.answer(text, question, option)
    if not new_text then
      return nil, qerr
    end
    return new_text, nil, { key = info and info.key or question }
  end, { root = eo.root, today = eo.today, index = not args.opt["no-index"] })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(
    ("answer\t%s\t%s\t%s\t%s"):format(
      res.id,
      res.extra and res.extra.key or question,
      choice,
      res.changed and "changed" or "unchanged"
    )
  )
  report_index(ctx, res)
  return 0
end

function commands.migrate_actor(ctx)
  local args, eo = ctx.args, ctx.eo
  local area, area_ok = area_arg(ctx, "migrate-actor")
  if not area_ok then
    return 2
  end
  local open, skipped, errors = scan.open_tasks({ root = eo.root, area = area })
  if not open then
    ctx.warn("error: " .. tostring(skipped))
    return 1
  end
  local batch = require("tasks_nvim.batch")
  local proposals, left = batch.plan_actor_migration(open)
  for _, p in ipairs(proposals) do
    ctx.say(
      ("%s\t%s\t%s\t%s"):format(args.opt.write and "set" or "propose", p.id, p.actor, p.reason)
    )
  end
  ctx.warn(
    ("%d proposed, %d left empty (of %d open)%s"):format(
      #proposals,
      left,
      #open,
      args.opt.write and "" or "; dry run, pass --write to apply"
    )
  )
  if errors and #errors > 0 then
    ctx.warn("warn: the result is incomplete, could not read: " .. table.concat(errors, ", "))
  end
  if args.opt.write and #proposals > 0 then
    local res = batch.set_many(
      batch.actor_steps(proposals),
      { root = eo.root, today = eo.today, index = not args.opt["no-index"] }
    )
    for _, f in ipairs(res.failed) do
      ctx.warn(("error: %s: %s"):format(f.id, f.err))
    end
    for _, e in ipairs(res.index_errors) do
      ctx.warn("warn: index " .. e)
    end
    return #res.failed > 0 and 1 or 0
  end
  return 0
end
commands["migrate-actor"] = commands.migrate_actor

function commands.done(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn(
      "error: usage: done <area>/<slug> [--commits=repo@sha,...] [--done-in=text] [--date=YYYY-MM-DD] [--remind=7d|YYYY-MM-DD]"
    )
    return 2
  end
  local flow, err = done_flow.run(id, {
    root = eo.root,
    today = eo.today,
    done_in = args.opt["done-in"] --[[@as string|nil]],
    commits = args.opt.commits --[[@as string|nil]],
    remind = args.opt.remind
        and (args.opt.remind:match("^%d+[dw]$") and "+" .. args.opt.remind or args.opt.remind)
      or nil,
    date = args.opt.date --[[@as string|nil]],
    index = not args.opt["no-index"],
  })
  if not flow then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local res = flow.done
  if res.already then
    ctx.say(("already\t%s\t%s"):format(res.id, res.to))
    return 0
  end
  ctx.say(("done\t%s\t%s"):format(res.id, res.to))
  if res.readme == "missing" then
    ctx.warn("warn: Backlog/README.md does not exist; no index row added")
  end
  if flow.steps_ticked > 0 then
    ctx.say(("steps\t%s\t%d"):format(res.id, flow.steps_ticked))
  end
  for _, plan_id in ipairs(flow.plans_closed) do
    ctx.say(
      ("plan-closed\t%s\t%s"):format(
        plan_id,
        plan_view.plan_closed_text(plan_id, flow.plan_summaries[plan_id])
      )
    )
  end
  for _, doc in ipairs(flow.docs_refreshed) do
    ctx.say(("refreshed\t%s"):format(doc))
  end
  for _, note in ipairs(flow.notes) do
    ctx.warn(("warn: %s: %s"):format(res.id, note))
  end
  if args.opt.unblock and flow.next and #flow.next.freed_blocked > 0 then
    -- Never without being asked: only the tasks that waited on exactly this one and still read `blocked`.
    local steps = {}
    for _, task_id in ipairs(flow.next.freed_blocked) do
      steps[#steps + 1] = { id = task_id, patch = { status = "open" } }
    end
    local unblocked = require("tasks_nvim.batch").set_many(
      steps,
      { root = eo.root, today = eo.today, index = not args.opt["no-index"] }
    )
    for _, changed in ipairs(unblocked.changed) do
      ctx.say(("unblocked\t%s"):format(fsio.clean(changed.id)))
    end
    for _, f in ipairs(unblocked.failed) do
      ctx.warn(("warn: %s: %s"):format(f.id, f.err))
    end
    if #unblocked.changed > 0 and not args.opt["no-next"] then
      -- The advice below was worked out while the freed tasks still read `blocked`: they rank first once open.
      local pick = next_pick.pick_from_vault({
        root = eo.root,
        done = { id = res.id, area = flow.done.area },
      })
      if pick then
        flow.next = pick
      end
    end
  end
  if flow.next and not args.opt["no-next"] then
    for _, line in ipairs(plan_view.next_lines(flow.next)) do
      ctx.say(line)
    end
    for _, e in ipairs(flow.next.incomplete or {}) do
      ctx.warn("warn: cannot read directory " .. e .. " (the answer may be incomplete)")
    end
  end
  report_index(ctx, res)
  return 0
end

function commands.attach(ctx)
  local args, eo = ctx.args, ctx.eo
  local id, file = args.pos[1], args.pos[2]
  local from_clipboard, from_latest = args.opt.clipboard, args.opt.latest
  local sourced = from_clipboard or from_latest
  if from_clipboard and from_latest then
    ctx.warn("error: --clipboard and --latest exclude each other")
    return 2
  end
  if not id or (sourced and file) or (not sourced and not file) or #args.pos > 2 then
    ctx.warn(
      "error: usage: attach <area>/<slug> <file> [--name=n]  |  attach <area>/<slug> --clipboard|--latest[=<folder>]"
    )
    return 2
  end
  local res, err, too_old
  if sourced then
    res, err, too_old =
      require("tasks_nvim.attach_source").attach(id, from_clipboard and "clipboard" or "latest", {
        root = eo.root,
        today = eo.today,
        name = args.opt.name --[[@as string|nil]],
        dir = type(from_latest) == "string" and from_latest or nil,
        index = not args.opt["no-index"],
      })
    if not res and too_old then
      err = tostring(err) .. " (pass the file, or raise attach.max_age_s)"
    end
  else
    res, err = mutate.attach(id, file, {
      root = eo.root,
      today = eo.today,
      name = args.opt.name --[[@as string|nil]],
      index = not args.opt["no-index"],
    })
  end
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("attached\t%s\t%s\t%s"):format(res.id, res.rel, res.link))
  if res.updated_err then
    ctx.warn("warning: the asset is attached, but `updated` was not changed: " .. res.updated_err)
  end
  if res.folderized then
    ctx.say(("folderized\t%s\t%s"):format(res.id, res.path))
  end
  report_index(ctx, res)
  return 0
end

function commands.folderize(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn("error: usage: folderize <area>/<slug>")
    return 2
  end
  local res, err = mutate.folderize(id, { root = eo.root, index = not args.opt["no-index"] })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("%s\t%s\t%s"):format(res.changed and "folderized" or "unchanged", res.id, res.path))
  report_index(ctx, res)
  return 0
end

---`sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]`: run the task's test sheets now through testing.nvim's
---`testing sheets run`, which writes their state into the task; its output and exit code are this command's.
commands["sheet-run"] = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 or not vault.parse_id(id) then
    ctx.warn("error: usage: sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]")
    return 2
  end
  local root, rerr = vault.root({ root = eo.root })
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local res = require("tasks_nvim.sheet_run").run(id, {
    vault = root,
    cli = args.opt["testing-cli"] --[[@as string|nil]],
    dry_run = args.opt["dry-run"] == true,
  })
  for _, line in ipairs(res.lines) do
    ctx.say(line)
  end
  if res.code ~= 0 then
    ctx.warn("sheet-run: " .. res.summary)
  end
  return res.code
end

function commands.check(ctx)
  local args, eo = ctx.args, ctx.eo
  if #args.pos > 1 then
    ctx.warn("error: check takes at most one area")
    return 2
  end
  local area = (not args.opt.all) and args.pos[1] or nil
  local res, err = check.run({ root = eo.root, area = area })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local root = assert(vault.root({ root = eo.root }))
  for _, f in ipairs(res.findings) do
    ctx.say(check.format(f, root))
  end
  ctx.say(
    ("check: %d finding(s) (%d error, %d warning) in %d area(s), %d task file(s) read"):format(
      #res.findings,
      res.errors,
      res.warnings,
      res.areas,
      res.tasks
    )
  )
  return res.ok and 0 or 1
end

function commands.ci(ctx)
  if #ctx.args.pos > 0 then
    ctx.warn("error: ci takes no positional argument")
    return 2
  end
  local opt = ctx.args.opt
  local res = require("tasks_nvim.ci").run({
    root = ctx.eo.root,
    strict = opt.strict == true,
    lint = opt["no-lint"] ~= true,
    trust_vault_lint = opt["trust-vault-lint"] == true,
    md_lint = opt["md-lint"] --[[@as string|nil]],
  }, ctx.say)
  return res.code
end

function commands.template(ctx)
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  if #args.pos > 0 then
    ctx.warn("error: template takes no positional argument (use --title=...)")
    return 2
  end
  local prio
  if opt.prio then
    prio = model.to_prio(opt.prio)
    if not prio then
      ctx.warn("error: --prio must be 1, 2 or 3")
      return 2
    end
  end
  if opt.lang ~= nil and opt.lang ~= "de" and opt.lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  ctx.out(mutate.template({
    lang = opt.lang --[[@as "de"|"en"|nil]],
    title = opt.title --[[@as string|nil]],
    kind = opt.kind --[[@as string|nil]],
    prio = prio,
    effort = opt.effort --[[@as string|nil]],
    tags = opt.tags and split_commas(opt.tags --[[@as string]]) or nil,
    today = eo.today,
    with_plan = opt["with-plan"] == true,
  }))
  return 0
end

function commands.areas(ctx)
  local format = ctx.args.opt.format or "names"
  if format ~= "names" and format ~= "tsv" and format ~= "json" then
    ctx.warn("error: --format must be names, tsv or json")
    return 2
  end
  if #ctx.args.pos > 0 then
    ctx.warn("error: areas takes no argument")
    return 2
  end
  if format ~= "names" then
    return contract_cli.areas(ctx, format)
  end
  local root, err = vault.root(ctx.eo)
  if not root then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, a in ipairs(vault.areas(root)) do
    ctx.say(a.name)
  end
  return 0
end

function commands.export(ctx)
  local args, eo = ctx.args, ctx.eo
  local root, rerr = vault.root(eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local top
  if args.opt.top then
    local n, err = to_int(args.opt.top --[[@as string]], "--top")
    if not n then
      ctx.warn("error: " .. err)
      return 2
    end
    top = n
  end
  local tasks, errors = scan.all({ root = root })
  if not tasks then
    ctx.warn("error: " .. tostring(errors))
    return 1
  end
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    names[#names + 1] = a.name
  end
  local text = index.render_global(tasks, {
    top = top,
    areas = names,
    links = not args.opt["no-links"],
    link_prefix = args.opt["link-prefix"] --[[@as string|nil]],
  })
  ctx.out(text)
  return 0
end

---The work list of `--from-rules`: a file, or stdin for `-` (one byte over the limit is read, so a larger one is
---refused, not cut).
---@param ctx Tasks.CliCtx
---@param source string
---@return string|nil text
---@return string|nil err
local function read_work_list(ctx, source)
  local rules_import = require("tasks_nvim.rules_import")
  if source == "-" then
    local stdin = ctx.io.stdin or io.stdin
    return stdin:read(rules_import.MAX_BYTES + 1) or "", nil
  end
  local text, err = fsio.read(source)
  if not text then
    return nil, "cannot read the work list: " .. tostring(err)
  end
  return text, nil
end

---`import` and `bootstrap`: the plan of a work list, printed one line per rule; written only with `--apply`.
---@param ctx Tasks.CliCtx
---@param make_area boolean  `bootstrap`: the area is made first
---@return integer
local function import_command(ctx, make_area)
  local rules_import = require("tasks_nvim.rules_import")
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  local verb = make_area and "bootstrap" or "import"
  local area = args.pos[1]
  local source = opt["from-rules"]
  if not area or #args.pos > 1 or (not make_area and not source) then
    ctx.warn(
      make_area and "error: usage: bootstrap <area> [--from-rules=<file|->] [--apply]"
        or "error: usage: import <area> --from-rules=<file|-> [--apply]"
    )
    return 2
  end
  if opt.apply and opt["dry-run"] then
    ctx.warn("error: --apply and --dry-run exclude each other")
    return 2
  end
  local lang = opt.lang or "de"
  if lang ~= "de" and lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  local apply = opt.apply == true
  local root, rerr = vault.root(eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  -- the work list is read and checked before anything is made
  local doc
  if source then
    local text, terr = read_work_list(ctx, source --[[@as string]])
    if not text then
      ctx.warn("error: " .. terr)
      return 1
    end
    local perr
    doc, perr = rules_import.parse(text)
    if not doc then
      ctx.warn("error: " .. tostring(perr))
      return 1
    end
  end

  if make_area then
    local missing, berr = rules_import.bootstrap_plan(root, area)
    if not missing then
      ctx.warn("error: " .. tostring(berr))
      return 1
    end
    if apply then
      local made, merr = rules_import.bootstrap(root, area)
      if not made then
        ctx.warn("error: " .. tostring(merr))
        return 1
      end
      for _, p in ipairs(made) do
        ctx.say("made\t" .. p)
      end
    else
      for _, p in ipairs(missing) do
        ctx.say("would-make\t" .. p)
      end
    end
  elseif not vault.has_area(root, area) then
    ctx.warn("error: " .. vault.not_an_area_message(area, vault.area_names(root)))
    return 1
  end
  if not doc then
    if not apply then
      ctx.say(("%s\tdry-run\tnothing written; --apply makes it"):format(verb))
    end
    return 0
  end
  local plan, plerr =
    rules_import.plan(doc, area, { root = root, today = eo.today or model.today(), lang = lang })
  if not plan then
    ctx.warn("error: " .. tostring(plerr))
    return 1
  end
  if plan.target ~= area then
    ctx.warn(
      ("note: the work list checked %s, its tasks go to the area %s"):format(plan.target, area)
    )
  end
  local failed = {}
  if apply then
    local res = rules_import.apply(plan, { root = root })
    for _, f in ipairs(res.failed) do
      failed[f.rule_id] = f.err
    end
    if res.index_err then
      ctx.warn("warn: index not updated: " .. res.index_err)
    end
  end
  for _, item in ipairs(plan.items) do
    local a = item.action
    if a == "create" then
      if failed[item.rule_id] then
        ctx.say(("failed\t-\t%s\t%s"):format(item.rule_id, failed[item.rule_id]))
      else
        ctx.say(
          ("%s\t%s\t%s\t%s"):format(
            apply and "created" or "would-create",
            item.id,
            item.rule_id,
            item.title
          )
        )
      end
    elseif a == "exists" then
      ctx.say(("exists\t%s\t%s"):format(item.id, item.rule_id))
    elseif a == "done" then
      ctx.say(("done\t%s\t%s\tfinished, not opened again"):format(item.id, item.rule_id))
    elseif a == "waived" then
      ctx.say(("waived\t-\t%s\t%s"):format(item.rule_id, item.note or ""))
    elseif a == "pass" and item.id then
      ctx.say(
        ("passes\t%s\t%s\tthe rule passes now: the task may be finished"):format(
          item.id,
          item.rule_id
        )
      )
    elseif a == "invalid" then
      ctx.say(("invalid\t-\t%s\t%s"):format(item.rule_id or "-", item.note or ""))
    end
  end
  local c = plan.counts
  local nfailed = vim.tbl_count(failed)
  ctx.say(
    ("%s\t%s\t%d %s, %d exist, %d finished, %d waived, %d pass, %d invalid%s"):format(
      verb,
      apply and "applied" or "dry-run",
      c.create - nfailed,
      apply and "created" or "to create",
      c.exists,
      c.done,
      c.waived,
      c.pass,
      c.invalid,
      nfailed > 0 and (", " .. nfailed .. " failed") or ""
    )
  )
  if not apply and c.create > 0 then
    ctx.say(("%s\tdry-run\tnothing written; --apply creates the tasks"):format(verb))
  end
  return nfailed > 0 and 1 or 0
end

function commands.import(ctx)
  return import_command(ctx, false)
end

function commands.bootstrap(ctx)
  return import_command(ctx, true)
end

---The example task of `init-vault`, by language.
local FIRST_TASK = {
  de = {
    title = "Erste Task: anlegen, bearbeiten, erledigen",
    summary = "Eine Beispiel-Task: ändere sie, setze status=doing und schließe sie mit done ab.",
  },
  en = {
    title = "First task: create, edit, finish",
    summary = "An example task: change it, set status=doing and finish it with done.",
  },
}

---Whether `area` of the vault `root` holds a task (a file or a folder task).
---@param root string
---@param area string
---@return boolean
local function has_tasks(root, area)
  if not fsio.is_dir(root .. "/" .. area .. "/ROADMAP/tasks") then
    return false
  end
  local tasks = require("tasks_nvim.scan").area(area, { root = root })
  return tasks ~= nil and #tasks > 0
end

---Whether `root` is a folder with things in it that do not look like a vault: no `README.md` and no folder with a
---`ROADMAP/` or `Backlog/` in it. A home or project folder must not become a vault by a typo. Hidden entries
---(`.git`, `.obsidian`) do not count: `git init` first and the vault after is the usual order.
---@param root string
---@return boolean
local function is_foreign_folder(root)
  if not fsio.is_dir(root) or fsio.is_file(root .. "/README.md") then
    return false
  end
  local any = false
  for name, kind in vim.fs.dir(root) do
    any = any or name:sub(1, 1) ~= "."
    if kind == "directory" then
      local sub = root .. "/" .. name
      if fsio.is_dir(sub .. "/ROADMAP") or fsio.is_dir(sub .. "/Backlog") then
        return false
      end
    end
  end
  return any
end

---`init-vault <dir>`: a new vault in `dir` with a first area and an example task; nothing overwritten, a dry run
---unless `--apply`. The vault is the positional folder, not `--vault`.
---@param ctx Tasks.CliCtx
---@return integer
commands["init-vault"] = function(ctx)
  local args = ctx.args
  local opt = args.opt
  local dir = args.pos[1]
  if not dir or #args.pos > 1 then
    ctx.warn("error: usage: init-vault <dir> [--area=<name>] [--lang=de|en] [--force] [--apply]")
    return 2
  end
  if opt.vault then
    ctx.warn("warn: init-vault takes the folder as its argument; --vault is ignored")
  end
  if opt.apply and opt["dry-run"] then
    ctx.warn("error: --apply and --dry-run exclude each other")
    return 2
  end
  local lang = opt.lang or "de"
  if lang ~= "de" and lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  -- Checked before anything is made: a bad date would otherwise fail the example task after the vault exists.
  if ctx.eo.today ~= nil and not model.is_date(ctx.eo.today) then
    ctx.warn("error: --today must be YYYY-MM-DD, got '" .. tostring(ctx.eo.today) .. "'")
    return 2
  end
  local area = type(opt.area) == "string" and opt.area or "Inbox"
  local vault_ops = require("tasks_nvim.vault_ops")
  local rules_import = require("tasks_nvim.rules_import")
  local root, terr = vault_ops.check_vault_target(dir, { area })
  if not root then
    ctx.warn("error: " .. tostring(terr))
    return 1
  end
  if is_foreign_folder(root) and not opt.force then
    ctx.warn(
      ("error: %s has files and is no vault (no README.md, no area); --force makes the vault there anyway"):format(
        root
      )
    )
    return 1
  end

  if not opt.apply then
    if not fsio.is_file(root .. "/README.md") then
      ctx.say("would-make\tREADME.md")
    end
    local missing, berr = rules_import.bootstrap_plan(root, area)
    if not missing then
      ctx.warn("error: " .. tostring(berr))
      return 1
    end
    for _, p in ipairs(missing) do
      ctx.say("would-make\t" .. p)
    end
    if not has_tasks(root, area) then
      ctx.say(("would-make\t%s/ROADMAP/tasks/ (an example task)"):format(area))
    end
    ctx.say(("init-vault\tdry-run\tnothing written to %s; --apply makes it"):format(root))
    return 0
  end

  local res, cerr = vault_ops.create_vault(root, { area })
  if not res then
    ctx.warn("error: " .. tostring(cerr))
    return 1
  end
  for _, p in ipairs(res.created) do
    -- folders end in `/`, as `bootstrap` prints them
    ctx.say("made\t" .. p .. (p:match("%.md$") and "" or "/"))
  end
  local made, merr = rules_import.bootstrap(res.root, area)
  if not made then
    ctx.warn("error: " .. tostring(merr))
    return 1
  end
  for _, p in ipairs(made) do
    ctx.say("made\t" .. p)
  end
  if not has_tasks(res.root, area) then
    local first = FIRST_TASK[lang]
    local task, nerr = require("tasks_nvim.mutate").new(area, {
      root = res.root,
      title = first.title,
      summary = first.summary,
      lang = lang,
      today = ctx.eo.today,
    })
    if not task then
      ctx.warn("error: the vault is made, the example task is not: " .. tostring(nerr))
      return 1
    end
    ctx.say(("created\t%s\t%s"):format(task.id, task.path))
  end
  ctx.say(("init-vault\t%s\tuse it with --vault=%s or $TASKS_VAULT"):format(res.root, res.root))
  return 0
end

---The options of every CLI verb (`value`: needs `=value`; `flag`: none), a copy of the table the parser reads. The
---drift spec compares it with the routes of `:Tasks` (`tasks_verbs_drift_spec.lua`).
---@return table<string, Tasks.CliSpec>
function M.specs()
  return vim.deepcopy(SPECS)
end

---Run one command line. `argv[1]` is the subcommand.
---@param argv string[]
---@param io? Tasks.CliIO  defaults to stdout/stderr
---@return integer exit_code
contract_helpers.area_arg = area_arg
contract_helpers.filter_from = filter_from
contract_helpers.to_int = to_int
contract_helpers.cellv = cellv
contract_cli.register(commands, SPECS, contract_helpers)

function M.run(argv, io)
  io = io or M.stdio
  local function say(line)
    io.out(clean(line) .. "\n")
  end
  local function warn(line)
    io.err(clean(line) .. "\n")
  end
  local function out(text)
    io.out(clean(text))
  end

  -- Global options may come before the command (`--vault=x list`): move them behind it.
  local lead = 0
  while
    argv[lead + 1] and (argv[lead + 1]:match("^%-%-vault=") or argv[lead + 1]:match("^%-%-today="))
  do
    lead = lead + 1
  end
  if lead > 0 and argv[lead + 1] then
    -- right behind the command name, NOT at the end: after a bare `--` everything is text (`new area -- --title`), and
    -- an option that landed there would be read as part of the title
    local moved = { argv[lead + 1] }
    for i = 1, lead do
      moved[#moved + 1] = argv[i]
    end
    for i = lead + 2, #argv do
      moved[#moved + 1] = argv[i]
    end
    argv = moved
  end

  if argv[1] == "--capabilities" then
    -- the handshake: `call hello` under a name that needs no method word
    local moved = { "call", "hello" }
    for i = 2, #argv do
      moved[#moved + 1] = argv[i]
    end
    argv = moved
  end

  local name = argv[1]
  if name == nil or name == "help" or name == "--help" or name == "-h" then
    io.out(USAGE)
    return name == nil and 2 or 0
  end
  local spec, handler = SPECS[name], commands[name]
  if not spec or not handler then
    warn("error: unknown command: " .. tostring(name))
    io.err(USAGE)
    return 2
  end

  local rest = {}
  for i = 2, #argv do
    rest[#rest + 1] = argv[i]
  end
  local args, perr = parse_args(rest, spec)
  if not args then
    warn("error: " .. perr)
    return 2
  end
  if args.opt.help then
    io.out(USAGE)
    return 0
  end

  if
    (name == "list" or name == "plan" or name == "estimate")
    and args.pos[1]
    and args.pos[1]:sub(1, 1) == "@"
  then
    local lerr = apply_list(args, args.pos[1]:sub(2), name)
    if lerr then
      warn("error: " .. lerr)
      return 2
    end
  end

  ---@type Tasks.CliCtx
  local ctx =
    { io = io, args = args, say = say, warn = warn, out = out, eo = engine_opts(args.opt) }
  local ok, code = pcall(handler, ctx)
  if not ok then
    warn("error: " .. tostring(code))
    return 1
  end
  -- A handler that forgot its exit code must not read as success (`os.exit(nil)` is 0).
  return type(code) == "number" and code or 1
end

return M
