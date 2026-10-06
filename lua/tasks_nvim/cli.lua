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
local fsio = require("tasks_nvim.fsio")
local mutate = require("tasks_nvim.mutate")
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
       [--stale=<days>|refs] [--stale-refs] [--blocked] [--ready|--waiting] [--unestimated]
       [--sort=default|prio-effort|severity|frecency|roi] [--format=tsv|ids]   open tasks, sorted; one line each
       (categories: bug security performance docs ruleset; --category=bug also finds kind=bug;
        --sort=prio-effort: small first within a prio; --sort=severity: critical first;
        --sort=roi: most value per effort first, tasks without value or effort last;
        --actor=me also finds status=decision and the tag needs-user; none = nobody classified it;
        --sort=frecency: what the dashboard opened or changed most, from the frecency file)
       (--ready: nothing open blocks it; --waiting: an open blocker; --unestimated: no effort or no value)
  plan-new <area> <title> [--areas=a,b] [--target=<id>] [--phases=a,b,c] [--gate=hard] [--summary=text]
                                          create ROADMAP/plans/<slug>.md; tasks join it with plan=<id> phase=<word>
  plan [<area>] [--for=<id>|--plan=<id>] [filters as for list] [--ready] [--with-steps] [--format=md|tsv|ids]
       [--write=<file> [--scope=<name>] [--check] ]   replace only the generated block of a document
                                          stages, ready tasks, decisions by leverage, critical path
                                          (--for: the task and everything that has to be finished before it)
  next [<area>] [--n=3] [--actor=cdx|me|pair|none]   the best ready tasks, with the reason
  estimate [<area>] [--for=<id>] [filters as for list]   sums of effort and value, what is missing, quick wins
  index [<area>] [--check]                (re)write ROADMAP/TASKS.md; --check only reports
  migrate-actor [<area>] [--write]        propose actor=me for tasks that wait for you (status decision, tag
                                          needs-user) and leave every other task EMPTY; dry run unless --write
  new <area> <title> [--kind=k] [--prio=1..3] [--effort=XS..XL|0.5d] [--value=1..5] [--actor=cdx|me|pair] [--after=id,id] [--order=2.5] [--plan=id] [--phase=word] [--tags=a,b]
       [--category=c,d] [--severity=low|medium|high|critical] [--refs=path,repo@sha]
       [--summary=text] [--slug=slug] [--status=s]
       [--lang=de|en] [--folder]             create a task file (--lang: body headings;
                                               --folder: a folder task that can hold assets)
  set <area>/<slug> key=value ...         change frontmatter (empty value removes the key)
  done <area>/<slug> [--done-in=text] [--date=YYYY-MM-DD] [--no-next] [--unblock]
                                          finish: move to Backlog/; prints the tasks it freed and what to start
                                          next; --unblock sets the freed tasks that still say blocked to open
  attach <area>/<slug> <file> [--name=n]  copy a file to <slug>/assets/ (a plain task becomes a
                                          folder task) and print the Markdown link
  folderize <area>/<slug>                 turn a plain task file into a folder task
  check [<area>]                          rule check; exit 1 on any error
  template [--title=t] [--kind=k] [--prio=n] [--effort=e] [--tags=a,b] [--lang=de|en] [--with-plan]
  ci [--strict] [--no-lint] [--md-lint=<file>] [--trust-vault-lint]   CI gate: check + index --check + md_lint of the
                                          generated indexes; exit 0/1 (--strict: warnings fail too).
                                          md_lint is a script RUN from the vault (TOOLS/scripts/md_lint.lua): it runs only with
                                          --trust-vault-lint (or TASKS_TRUST_VAULT_LINT=1); else --md-lint=<own copy> or --no-lint
  areas                                  list the vault's areas
  export [--top=N] [--no-links]           all-areas overview as Markdown on stdout (never written)

global options: --vault=<dir> (default: $TASKS_VAULT; no built-in default path)
                --today=YYYY-MM-DD (for reproducible runs); --no-index on new/set/done
]]

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
      "sort",
      "format",
    },
    flag = { "blocked", "all", "stale-refs", "ready", "waiting", "unestimated" },
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
      "format",
    },
    flag = { "blocked", "stale-refs", "ready", "unestimated", "with-steps", "check" },
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
    },
    flag = { "blocked", "stale-refs", "unestimated" },
  },
  next = { value = { "n", "actor" }, flag = {} },
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
      "lang",
      "summary",
      "slug",
      "status",
      "title",
    },
    flag = { "no-index", "folder" },
  },
  set = { value = {}, flag = { "no-index" } },
  ["migrate-actor"] = { value = {}, flag = { "write", "no-index" } },
  done = { value = { "done-in", "date" }, flag = { "no-index", "no-next", "unblock" } },
  attach = { value = { "name" }, flag = { "no-index" } },
  folderize = { value = {}, flag = { "no-index" } },
  check = { value = {}, flag = { "all" } },
  ci = { value = { "md-lint" }, flag = { "strict", "no-lint", "trust-vault-lint" } },
  template = {
    value = { "title", "kind", "prio", "effort", "tags", "lang" },
    flag = { "with-plan" },
  },
  areas = { value = {}, flag = {} },
  export = { value = { "top", "link-prefix" }, flag = { "no-links" } },
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

---Turn the filter options into a `Tasks.Filter` (the parsing itself is shared
---with the editor commands: `filter_opts.parse`).
---@param opt table<string, string|boolean>
---@return Tasks.Filter|nil filter
---@return string|nil err
local function filter_from(opt)
  return filter_opts.parse({
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
    blocked = opt.blocked == true,
    unestimated = opt.unestimated == true,
    today = opt.today --[[@as string|nil]],
  })
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
  if format ~= "tsv" and format ~= "ids" then
    ctx.warn("error: --format must be tsv or ids")
    return 2
  end
  if #args.pos > 1 then
    ctx.warn("error: list takes at most one area")
    return 2
  end

  local area
  if args.pos[1] and not args.opt.all then
    local root, rerr = vault.root(eo)
    if not root then
      ctx.warn("error: " .. tostring(rerr))
      return 1
    end
    if not vault.has_area(root, args.pos[1]) then
      ctx.warn("error: unknown area: " .. args.pos[1])
      return 1
    end
    area = args.pos[1]
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
      ctx.say(t.id)
    else
      local cells = {
        t.id,
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

---The area argument shared by `plan`, `next` and `estimate`.
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
  if not vault.has_area(root, given) then
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
  local text, rerr = fsio.read(path)
  if not text then
    ctx.warn("error: cannot read " .. path .. ": " .. tostring(rerr))
    return 1
  end
  local body = plan_view.markdown(scope.plan, {
    title = scope.title,
    done = scope.done,
    ready_only = opt.ready == true,
    with_steps = opt["with-steps"] == true,
    plan_file = scope.plan_file,
    block = true,
  })
  local fresh, err, changed = plan_view.replace_block(text, key, body)
  if not fresh then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if opt.check then
    ctx.say(("%s\t%s"):format(changed and "stale" or "current", path))
    return changed and 1 or 0
  end
  if not changed then
    ctx.say(("unchanged\t%s"):format(path))
    return 0
  end
  local ok, werr = fsio.write_atomic(path, fresh, { follow_symlinks = true })
  if not ok then
    ctx.warn("error: cannot write " .. path .. ": " .. tostring(werr))
    return 1
  end
  ctx.say(("written\t%s"):format(path))
  return 0
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
      ctx.say(id)
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
  local pick, err = next_pick.pick_from_vault({
    root = ctx.eo.root,
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
  local res, err = mutate.new(area, {
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
    lang = opt.lang --[[@as "de"|"en"|nil]],
    summary = opt.summary --[[@as string|nil]],
    slug = opt.slug --[[@as string|nil]],
    status = opt.status --[[@as string|nil]],
    folder = opt.folder == true,
    index = not opt["no-index"],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("created\t%s\t%s"):format(res.id, res.path))
  report_index(ctx, res)
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

function commands.migrate_actor(ctx)
  local args, eo = ctx.args, ctx.eo
  if #args.pos > 1 then
    ctx.warn("error: migrate-actor takes at most one area")
    return 2
  end
  local open, skipped, errors = scan.open_tasks({ root = eo.root, area = args.pos[1] })
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
    local res = batch.set_many(batch.actor_steps(proposals), { root = eo.root, today = eo.today })
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
    ctx.warn("error: usage: done <area>/<slug> [--done-in=text] [--date=YYYY-MM-DD]")
    return 2
  end
  local flow, err = done_flow.run(id, {
    root = eo.root,
    today = eo.today,
    done_in = args.opt["done-in"] --[[@as string|nil]],
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
    local unblocked =
      require("tasks_nvim.batch").set_many(steps, { root = eo.root, today = eo.today })
    for _, changed in ipairs(unblocked.changed) do
      ctx.say(("unblocked\t%s"):format(changed.id))
    end
    for _, f in ipairs(unblocked.failed) do
      ctx.warn(("warn: %s: %s"):format(f.id, f.err))
    end
  end
  if flow.next and not args.opt["no-next"] then
    for _, line in ipairs(plan_view.next_lines(flow.next)) do
      ctx.say(line)
    end
  end
  report_index(ctx, res)
  return 0
end

function commands.attach(ctx)
  local args, eo = ctx.args, ctx.eo
  local id, file = args.pos[1], args.pos[2]
  if not id or not file or #args.pos > 2 then
    ctx.warn("error: usage: attach <area>/<slug> <file> [--name=n]")
    return 2
  end
  local res, err = mutate.attach(id, file, {
    root = eo.root,
    today = eo.today,
    name = args.opt.name --[[@as string|nil]],
    index = not args.opt["no-index"],
  })
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

---Run one command line. `argv[1]` is the subcommand.
---@param argv string[]
---@param io? Tasks.CliIO  defaults to stdout/stderr
---@return integer exit_code
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
    local moved = { argv[lead + 1] }
    for i = lead + 2, #argv do
      moved[#moved + 1] = argv[i]
    end
    for i = 1, lead do
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
