/* Generated from schemas/tasks-export/1/tasks-export.schema.json by contract/check.mjs. Do not edit. */

/**
 * tasks-export/1: every document tasks.nvim hands to a machine. One of the kinds below, told apart by `kind`. The engine writes exactly these fields (a field that is not listed fails the contract tests); a reader ignores fields it does not know, because inside one version the contract only grows.
 */
export type TasksExport =
  | Hello
  | Snapshot
  | List
  | Order
  | NamedLists
  | Bodies
  | Estimate
  | PlanFor
  | Check
  | TaskDocument
  | Next
  | Areas
  | Finished
  | Links
  | Groupings
  | DonePreview
  | Result
  | Error;
/**
 * tasks.hello: what this engine is and can do. Reads no task.
 */
export type Hello = Head & {
  kind: "tasks.hello";
  /**
   * The versions of the contract this engine speaks.
   */
  schemas: number[];
  /**
   * What it can answer; show only what is listed.
   */
  capabilities: string[];
  limits: {
    title: number;
    summary: number;
    body_bytes: number;
    list_items: number;
    batch_ops: number;
  };
  /**
   * The ranges of the fields, from the engine, so that nobody hard-codes them.
   */
  enums: {
    status: string[];
    kind: string[];
    prio: number[];
    value: number[];
    effort: string[];
    actor: string[];
    category: string[];
    severity: string[];
  };
};
/**
 * What the vault looked like: `rev:` and 6 hex digits, from every task by id and etag.
 */
export type Rev = string;
/**
 * The hash of the document's content (without `generated_at` and `engine`): the same vault gives the same digest.
 */
export type Digest = string;
/**
 * tasks.snapshot: one scan, one `rev`: counts, areas, the plan's head, the plan files and every open task with its readiness.
 */
export type Snapshot = Head & {
  kind: "tasks.snapshot";
  rev: Rev;
  digest: Digest;
  counts: {
    listed: number;
    unlisted: number;
    by_status: StatusCounts;
  };
  areas: Area[];
  /**
   * Finished tasks that carry a reminder (`remind`), the oldest date first, at most 100. An open task's reminder is on its entry; a finished task is not in `tasks`, and a reminder is most often set when a task is finished.
   */
  reminders?: {
    id: string;
    area: string;
    title: string;
    remind: Date;
    etag?: Etag;
    done_in?: string;
  }[];
  /**
   * Task files in `ROADMAP/tasks` that are not open work: a finished task left there, a status nobody knows.
   */
  unlisted: {
    id: string;
    status: string;
    code: "done-in-roadmap" | "unknown-status" | "no-status";
  }[];
  plan: {
    summary: {
      tasks: number;
      ready: number;
      decision: number;
      waiting: number;
      stuck: number;
      freed: number;
      parked: number;
    };
    critical_path: {
      days: number;
      path: string[];
      /**
       * Tasks on the path without an effort (counted as one day each).
       */
      unknown_effort: number;
    };
    stage_sizes: number[];
    cycles: string[][];
    /**
     * Tasks of one stage that name the same file: not parallel work. A list of objects (a tuple would not survive the TypeScript generator).
     */
    conflict_groups: {
      stage: number;
      file: string;
      ids: string[];
    }[];
    warnings: {
      code: string;
      id?: string;
      msg: string;
    }[];
  };
  plans: {
    id: string;
    title: string;
    status?: "planning" | "doing" | "parked" | "done";
    areas: string[];
    target?: string;
    phase_order: string[];
    gate?: "hard";
    valid: boolean;
  }[];
  /**
   * In plan order.
   */
  tasks: TaskEntry[];
  /**
   * Folders that could not be read: the answer may be incomplete.
   */
  incomplete: string[];
  estimate: {
    tasks: number;
    days: number;
    n_with_effort: number;
    n_without_effort: number;
    value: number;
    n_with_value: number;
    roi?: number;
    quick_wins: string[];
    unestimated: string[];
  };
};
/**
 * A calendar day, YYYY-MM-DD.
 */
export type Date = string;
/**
 * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
 */
export type Etag = string;
/**
 * The statuses of a task in `ROADMAP/tasks`. `done` is only seen on a task that was left there after it was finished (listed under `unlisted`).
 */
export type Status = "doing" | "decision" | "blocked" | "open" | "parked" | "done";
export type Kind = "feature" | "task" | "bug" | "idea" | "research";
/**
 * A size (XS to XL) or a duration in days (`3d`, `0.5d`). `effort_days` is always the figure.
 */
export type Effort = string;
export type Actor = "cdx" | "me" | "pair";
export type Severity = "low" | "medium" | "high" | "critical";
export type Category =
  "bug" | "security" | "performance" | "docs" | "ruleset" | "ux" | "bindings" | "refactor" | "tests" | "ci";
/**
 * tasks.list: one page of tasks in plan order, or in the order the request named (`sort`).
 */
export type List = Head & {
  kind: "tasks.list";
  rev: Rev;
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: TaskEntry[];
  /**
   * Absent on the last page.
   */
  next_offset?: number;
  incomplete: string[];
};
/**
 * tasks.order: the ids of the open tasks in the order the request named (`sort`; "default" is the plan's order), all in one document.
 */
export type Order = Head & {
  kind: "tasks.order";
  digest: Digest;
  sort: "default" | "prio-effort" | "severity" | "frecency" | "roi";
  total: number;
  ids: string[];
  incomplete: string[];
};
/**
 * tasks.lists: the named lists of the engine, read only: the built-in ones, the ones saved with the editor and the ones of the configuration (the later source wins by name), by name. `notes` tell what had to be left out (a rejected definition, a shadowed list, a state file that cannot be read), in the engine's words and without a path of this machine.
 */
export type NamedLists = Head & {
  kind: "tasks.lists";
  digest: Digest;
  lists: NamedList[];
  notes: string[];
};
/**
 * tasks.bodies: the text of many tasks, a page at a time, for a reader that searches it. Its `rev` is that of the snapshot of the same vault.
 */
export type Bodies = Head & {
  kind: "tasks.bodies";
  rev: Rev;
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: {
    id: string;
    etag: Etag;
    /**
     * The file after the frontmatter, untrusted text.
     */
    body: string;
    body_truncated: boolean;
  }[];
  /**
   * Absent on the last page; where to go on when a page ended early (it holds as many bytes as a page may).
   */
  next_offset?: number;
  incomplete: string[];
};
/**
 * tasks.estimate: the figures of an estimate for some open tasks, also as they would be with other efforts and values (`assume`; nothing is written). The same figures as `estimate` in the snapshot, with the range of the sizes.
 */
export type Estimate = Head & {
  kind: "tasks.estimate";
  rev: Rev;
  digest: Digest;
  tasks: number;
  days: number;
  /**
   * The sum with every size at its low and at its high end: without it the sum looks more exact than it is.
   */
  range: {
    low: number;
    high: number;
  };
  n_with_effort: number;
  n_without_effort: number;
  value: number;
  n_with_value: number;
  n_without_value: number;
  roi?: number;
  quick_wins: string[];
  unestimated: string[];
  /**
   * How many of the tasks were taken with assumed values.
   */
  assumed: number;
  incomplete: string[];
};
/**
 * tasks.planfor: the tasks one task needs before it can start (`needs`) or the tasks that wait for it (`unlocks`), with the hard edges between them, in the order of their distance from the task. The same tasks as `plan --for`.
 */
export type PlanFor = Head & {
  kind: "tasks.planfor";
  rev: Rev;
  digest: Digest;
  id: string;
  direction: "needs" | "unlocks";
  /**
   * All the tasks in the graph; `nodes` holds at most 500 of them.
   */
  total: number;
  truncated: boolean;
  nodes: {
    id: string;
    title: string;
    status: string;
    state?: string;
    stage?: number;
    /**
     * Steps from the task itself (0).
     */
    distance: number;
    on_critical_path?: true;
  }[];
  edges: {
    /**
     * The task that has to be finished first.
     */
    from: string;
    /**
     * The task that waits.
     */
    to: string;
    kind: "blocked_by" | "gate";
  }[];
  /**
   * The cycles whose members are all among `nodes`.
   */
  cycles: string[][];
  incomplete: string[];
};
/**
 * tasks.check: the rule check of the vault (`tasks check`), with `stale: refs` also the open tasks that name a file which changed after the task was updated. It reads every task file: a client runs it as a job.
 */
export type Check = Head & {
  kind: "tasks.check";
  rev: Rev;
  digest: Digest;
  /**
   * No finding of severity error.
   */
  ok: boolean;
  errors: number;
  warnings: number;
  /**
   * Areas checked.
   */
  areas: number;
  /**
   * Task files read, open and finished.
   */
  tasks: number;
  stale?: "refs";
  /**
   * All the findings; `findings` holds at most 1000 of them.
   */
  total: number;
  truncated: boolean;
  findings: {
    /**
     * A stable rule code, e.g. `unknown-status`.
     */
    code: string;
    severity: "error" | "warn";
    area: string;
    /**
     * The task the finding is about, when there is one.
     */
    id?: string;
    /**
     * Relative to the vault.
     */
    file: string;
    /**
     * The engine's words; untrusted text.
     */
    message: string;
  }[];
  /**
   * What could not be checked (git missing, a budget used up).
   */
  notes: string[];
  incomplete: string[];
};
/**
 * tasks.task: one task with its body and steps.
 */
export type TaskDocument = Head & {
  kind: "tasks.task";
  rev: Rev;
  digest: Digest;
  task: TaskEntry;
  /**
   * The file after the frontmatter, untrusted text.
   */
  body: string;
  body_truncated: boolean;
  steps: {
    n: number;
    text: string;
    ticked: boolean;
    dropped: boolean;
  }[];
};
/**
 * tasks.next: what to start, with the reason; or why there is nothing.
 */
export type Next = Head & {
  kind: "tasks.next";
  digest: Digest;
  task?: TaskBrief;
  alternatives: TaskBrief[];
  /**
   * Ready tasks an AI session could take, apart from yours.
   */
  cdx: TaskBrief[];
  freed: string[];
  ready: {
    area: number;
    vault: number;
  };
  open: {
    area: number;
    vault: number;
  };
  /**
   * Present when there is no task to start: which kind of nothing it is. `all_done` is only said when nothing is open at all.
   */
  empty?: {
    kind: "all_done" | "nothing_startable" | "only_cdx";
    waiting: number;
    for_me: number;
    blocked_status: number;
    parked: number;
    unlisted: number;
    unreadable: number;
  };
  incomplete: string[];
};
/**
 * tasks.areas: the areas of the vault with their open counts.
 */
export type Areas = Head & {
  kind: "tasks.areas";
  digest: Digest;
  areas: Area[];
};
/**
 * tasks.finished: the finished tasks of the Backlogs, newest first, one page, and what ALL that match add up to. Asked with `since` and `until` (days, both included) it covers the tasks `done` ran for in that window; the area is the one the file is in now.
 */
export type Finished = Head & {
  kind: "tasks.finished";
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: FinishedItem[];
  /**
   * Absent on the last page.
   */
  next_offset?: number;
  /**
   * Finished files (of the area asked for) without a `YYYY-MM-DD_` in the name: they are in the figures only when no window is asked for.
   */
  undated: number;
  stats: FinishedStats;
  incomplete: string[];
};
/**
 * tasks.links: where the areas hang together. A link is a `blocked_by` or `after` to an open task of another area, a ref that names another area (`lib.nvim@803de65`, `lib.nvim:anchor`; a path says nothing about the repo), or a plan whose open tasks lie in several areas. `pairs` groups the edges by the two areas (`a` sorts before `b`, the busiest pair first); `tasks` lists, for every open task that touches two or more areas, the areas it touches (its own and those of every link it is part of, in both directions). The edges of the pairs are cut at 2000 (`truncated`); `edge_count`, the counts and `tasks` cover all of them.
 */
export type Links = Head & {
  kind: "tasks.links";
  rev: Rev;
  digest: Digest;
  edge_count: number;
  truncated: boolean;
  pairs: {
    a: string;
    b: string;
    count: number;
    kinds: {
      [k: string]: number;
    };
    edges: LinkEdge[];
  }[];
  tasks: {
    id: string;
    /**
     * @minItems 2
     */
    areas: [string, string, ...string[]];
  }[];
  incomplete: string[];
};
/**
 * tasks.groupings: the fields the open tasks can be grouped by, with the values each can have and how a reader writes it. `status`, `prio`, `actor`, `kind`, `effort` and `value` are the model's; `tags`, `plan` and `phase` are the ones the open tasks name (at most 200, `truncated` says the rest); `area` is the areas of the vault; `state` is derived. `mode` says which operation writes the field: `set` (a field of the file), `tags` (the list of tags: leaving one and taking another is one `set` of the whole list) or `move_area`; a field without `mode` is read only. The same `rev` as the snapshot of the same vault.
 */
export type Groupings = Head & {
  kind: "tasks.groupings";
  rev: Rev;
  digest: Digest;
  fields: {
    field: "status" | "prio" | "actor" | "kind" | "effort" | "value" | "tags" | "plan" | "phase" | "area" | "state";
    values: string[];
    truncated: boolean;
    writable: boolean;
    value_type: "string" | "number";
    mode?: "set" | "tags" | "move_area";
    multi?: boolean;
  }[];
};
/**
 * tasks.donepreview: what finishing a task would do, with nothing written, and the `confirm` token that `done` needs for exactly this version of the file.
 */
export type DonePreview = Head & {
  kind: "tasks.donepreview";
  digest: Digest;
  id: string;
  /**
   * The task is finished already: nothing to confirm.
   */
  already?: true;
  area?: string;
  bucket?: "FEATURES" | "TASKS";
  from?: string;
  to: string;
  resumed?: boolean;
  steps_ticked?: number;
  readme?: {
    state: "missing" | "updated" | "unchanged";
    row?: string;
  };
  plan?: string;
  /**
   * The plan this finish closes: the task is its last open member.
   */
  closes_plan?: string;
  /**
   * Open tasks that wait on nothing but this one.
   */
  freed?: string[];
  etag?: Etag;
  confirm?: string;
};
/**
 * tasks.result: the answer to a request of `tasks-ops/1`, one entry per operation. `ok` is true only when every operation was.
 */
export type Result = Head & {
  kind: "tasks.result";
  digest: Digest;
  client_op_id?: string;
  dry_run: boolean;
  ok: boolean;
  results: ResultEntry[];
};
/**
 * Why something failed, in a word that is stable. A reader treats a word it does not know as `internal`.
 */
export type ErrorCode =
  | "invalid_argument"
  | "not_found"
  | "conflict"
  | "exists"
  | "forbidden"
  | "locked"
  | "lock_stuck"
  | "unsupported_schema"
  | "payload_too_large"
  | "rollback_incomplete"
  | "io"
  | "internal";
/**
 * tasks.error: what went wrong, in a code that is stable. `message` carries no path of the machine.
 */
export type Error = Head & {
  kind: "tasks.error";
  code: ErrorCode;
  message: string;
  retryable: boolean;
  details?: {};
};

/**
 * What every document starts with.
 */
export interface Head {
  schema: 1;
  plugin: "tasks.nvim";
  kind: string;
  generated_at: string;
  vault: {
    id: string;
  };
  engine: {
    version: string;
    git: string;
    nvim: string;
  };
  rev?: Rev;
  digest?: Digest;
}
export interface StatusCounts {
  [k: string]: number;
}
export interface Area {
  name: string;
  open: number;
  by_status: StatusCounts;
}
/**
 * One task. A broken task is still here (`valid: false`, `problems`); a field that is missing is unknown, never 0 (no `effort` means no `effort_days` and no `roi`).
 */
export interface TaskEntry {
  id: string;
  area: string;
  slug: string;
  title: string;
  status?: Status;
  kind?: Kind;
  prio?: number;
  /**
   * A tie-breaker inside a stage; a fraction slots a task in between.
   */
  order?: number;
  effort?: Effort;
  effort_days?: number;
  value?: number;
  /**
   * Value per effort day (never less than a quarter of a day), rounded to two places.
   */
  roi?: number;
  actor?: Actor;
  /**
   * True when `actor` is what the file says, absent when it was derived.
   */
  actor_written?: boolean;
  severity?: Severity;
  created?: Date;
  updated?: Date;
  /**
   * A calendar day, YYYY-MM-DD.
   */
  remind?: string;
  plan?: string;
  phase?: string;
  done_in?: string;
  tags: string[];
  category: Category[];
  blocked_by: string[];
  after: string[];
  /**
   * As written, but a path of the machine shows as `<external>/<name>`.
   */
  refs: string[];
  summary: string;
  folder: boolean;
  /**
   * Relative to the vault, with `/`.
   */
  file: string;
  valid: boolean;
  problems: Problem[];
  steps?: Steps;
  etag?: Etag;
  readiness?: Readiness;
  /**
   * `status|eff_prio`: inside one group `order` decides.
   */
  group?: string;
}
export interface Problem {
  code: string;
  msg: string;
}
/**
 * The steps of the optional `## Plan` section; a dropped one is not counted.
 */
export interface Steps {
  total: number;
  ticked: number;
  dropped: number;
}
/**
 * Where a task stands in the plan, from `blocked_by` alone.
 */
export interface Readiness {
  state: "ready" | "decision" | "waiting" | "stuck" | "freed" | "parked" | "unknown";
  /**
   * Absent for a task in a cycle.
   */
  stage?: number;
  /**
   * Position in plan order, 1 is first.
   */
  rank: number;
  eff_prio?: number;
  leverage: number;
  open_blockers: string[];
  inversion?: {
    from?: number;
    to: number;
    because: string;
  };
  in_cycle?: true;
  same_file?: string[];
}
/**
 * A named list: a filter and an order under a name. `options` are the option words of the command line (`tasks list --effort=<=S --sort=roi`), a switch is present as `true` and absent when off; a list the engine rejects is not here but in `notes` of the document. `summary` is the one line the engine shows for it (its description, else the words).
 */
export interface NamedList {
  name: string;
  source: "builtin" | "saved" | "config";
  desc?: string;
  summary: string;
  options: {
    area?: string;
    sort?: string;
    status?: string;
    prio?: string;
    effort?: string;
    kind?: string;
    category?: string;
    severity?: string;
    value?: string;
    actor?: string;
    tag?: string;
    stale?: string;
    plan?: string;
    phase?: string;
    blocked?: true;
    reminders?: true;
    unestimated?: true;
    stale_refs?: true;
    quick_win?: true;
    readiness?: "ready" | "waiting";
  };
}
export interface TaskBrief {
  id: string;
  title: string;
  status?: Status;
  prio?: number;
  effort?: string;
  reason?: "freed" | "area" | "vault";
}
/**
 * A finished task of `Backlog/`: what the engine knows without the plan (a finished task has no readiness). `done` is the day in the file's name; absent for a file without one.
 */
export interface FinishedItem {
  id: string;
  area: string;
  slug: string;
  title: string;
  done?: Date;
  kind?: Kind;
  prio?: number;
  effort?: Effort;
  effort_days?: number;
  value?: number;
  tags: string[];
  plan?: string;
  phase?: string;
  done_in?: string;
  file: string;
}
/**
 * What the finished tasks add up to, over ALL that match the window (not the page). A task that does not carry the field has a row without the key (missing means unknown). The rows of `by_month` and `by_week` are oldest first, the others the biggest first.
 */
export interface FinishedStats {
  /**
   * The sum of the efforts that are written down.
   */
  effort_days: number;
  /**
   * Tasks without an effort (not counted in `effort_days`).
   */
  without_effort: number;
  by_area: {
    area: string;
    count: number;
    effort_days: number;
  }[];
  by_kind: {
    kind?: Kind;
    count: number;
    effort_days: number;
  }[];
  by_prio: {
    prio?: number;
    count: number;
    effort_days: number;
  }[];
  by_month: {
    month?: string;
    count: number;
    effort_days: number;
  }[];
  by_week: {
    /**
     * A calendar day, YYYY-MM-DD.
     */
    week?: string;
    count: number;
    effort_days: number;
  }[];
}
/**
 * One link between the open tasks of two areas, seen from the task it starts at. `to` is the other task (`blocked_by`, `after`) or the plan (`plan`); `ref` is the ref as written (`refs`).
 */
export interface LinkEdge {
  from: string;
  from_area: string;
  to_area: string;
  kind: "blocked_by" | "after" | "refs" | "plan";
  to?: string;
  ref?: string;
}
/**
 * What happened to one operation of a request, in the order they were sent. A failed operation does not stop the others.
 */
export interface ResultEntry {
  n: number;
  op:
    "set" | "new" | "reorder" | "done" | "move_area" | "plan_new" | "tick_step" | "append_note" | "reopen" | "set_body";
  id?: string;
  ok: boolean;
  /**
   * `would_*` is what a dry run says; `blocked` is a move that cannot be made.
   */
  outcome:
    | "changed"
    | "unchanged"
    | "created"
    | "done"
    | "would_change"
    | "would_create"
    | "would_done"
    | "would_move"
    | "moved"
    | "blocked"
    | "failed";
  etag_before?: Etag;
  etag_after?: Etag;
  inverse?: Inverse;
  /**
   * What a reorder wrote: these `set` operations give every file it wrote its old `order` back (send them all instead of `inverse`, which only restores the place: a task that had no `order` would keep one, and the neighbours the move numbered stay numbered).
   */
  restore?: Inverse[];
  /**
   * Ids whose files this operation wrote (a dry run: none).
   */
  changed_ids: string[];
  /**
   * What happened to the generated index of the area, once for the whole request.
   */
  index?: {
    action: "written" | "removed" | "unchanged" | "stale" | "error";
    error?: string;
  };
  error?: OperationError;
  file?: string;
  group?: string;
  renumbered?: boolean;
  /**
   * `plan_new`: the file name (without `.md`) the plan got or would get.
   */
  slug?: string;
  /**
   * `plan_new`: the slug asked for was taken, so another one was chosen.
   */
  renamed?: boolean;
  writes?: number;
  to?: string;
  steps_ticked?: number;
  plans_closed?: string[];
  notes?: string[];
  move?: MovePlan;
  /**
   * `move_area`: the id the task has after the move.
   */
  new_id?: string;
  /**
   * `move_area`: the places that named the old id and now name the new one.
   */
  rewritten?: {
    kind: "blocked_by" | "after" | "refs" | "plan_target";
    id: string;
  }[];
}
/**
 * The operation that undoes a change: send it as a new operation (its `if_match` is the version the change left). A key the change added is `null` in the patch of a `set`.
 */
export interface Inverse {
  op: "set" | "reorder" | "tick_step" | "set_body" | "move_area";
  id: string;
  /**
   * `tick_step`: the number of the step.
   */
  n?: number;
  /**
   * `tick_step`: whether the step is to be ticked (true) or open (false).
   */
  done?: boolean;
  /**
   * `set_body`: the text below the frontmatter that the task had.
   */
  body?: string;
  /**
   * `move_area`: the area the task came from (`id` is the id it has now).
   */
  to_area?: string;
  patch?: {};
  after?: string;
  before?: string;
  if_match?: Etag;
}
/**
 * Why an operation did not happen. `details` names ids, keys and values (`expected` and `actual` of a conflict, the `problems` of a refused relation), never a path.
 */
export interface OperationError {
  code: ErrorCode;
  message: string;
  retryable: boolean;
  details?: {};
}
/**
 * What moving a task to another area would do and break (stage 1 of `move_area`: a report, nothing is written).
 */
export interface MovePlan {
  new_id: string;
  to_area: string;
  from: string;
  to: string;
  folder: boolean;
  conflicts: {
    code: string;
    message: string;
  }[];
  /**
   * Places that name the old id and would dangle.
   */
  references: {
    kind: "blocked_by" | "after" | "plan_target" | "refs" | "document";
    id?: string;
    path?: string;
  }[];
  notes: string[];
}
