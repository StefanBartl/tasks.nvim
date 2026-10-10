/* Generated from schemas/tasks-export/1/tasks-export.schema.json by contract/check.mjs. Do not edit. */

/**
 * tasks-export/1: every document tasks.nvim hands to a machine. One of the kinds below, told apart by `kind`. The engine writes exactly these fields (a field that is not listed fails the contract tests); a reader ignores fields it does not know, because inside one version the contract only grows.
 */
export type TasksExport = Hello | Snapshot | List | TaskDocument | Next | Areas | Error;
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
/**
 * A calendar day, YYYY-MM-DD.
 */
export type Date = string;
export type Category = "bug" | "security" | "performance" | "docs" | "ruleset";
/**
 * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
 */
export type Etag = string;
/**
 * tasks.list: one page of tasks in plan order.
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
 * tasks.error: what went wrong, in a code that is stable. `message` carries no path of the machine.
 */
export type Error = Head & {
  kind: "tasks.error";
  code: "invalid_argument" | "not_found" | "unsupported_schema" | "payload_too_large" | "locked" | "io" | "internal";
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
export interface TaskBrief {
  id: string;
  title: string;
  status?: Status;
  prio?: number;
  effort?: string;
  reason?: "freed" | "area" | "vault";
}
