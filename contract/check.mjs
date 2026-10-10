// Checks the machine contract tasks-export/1 from the outside, the way a client would meet it.
//
//   npm ci && node check.mjs            checks everything, writes nothing, exit 1 on any failure
//   node check.mjs --write              also regenerates schemas/tasks-export/1/tasks-export.d.ts
//
// What it proves:
//  1. every golden document (TESTS/golden/tasks-export-1/*.json, made by the Lua engine) is valid against the JSON
//     Schema (draft 2020-12, Ajv in strict mode: a mistake in the schema itself fails too);
//  2. documents that break the contract are refused (a field nobody listed, a status outside the enum, ...), so the
//     schema is not just "accepts everything";
//  3. the rules for a reader hold: a higher schema is refused, unknown fields are ignored, an unknown enum word is
//     "unknown", a missing field is unknown and never 0;
//  4. the TypeScript types generated from the schema are the committed ones, and none of them is `never[]` (what the
//     generator makes of a tuple).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { compile } from "json-schema-to-typescript";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const schemaPath = path.join(
  repo,
  "schemas/tasks-export/1/tasks-export.schema.json",
);
const typesPath = path.join(repo, "schemas/tasks-export/1/tasks-export.d.ts");
const goldenDir = path.join(repo, "TESTS/golden/tasks-export-1");
const write = process.argv.includes("--write");

let failures = 0;
const report = (ok, name, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ": " + detail : ""}`);
};

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

// ---- 1. the schema compiles (strict) and the goldens validate
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
let validate;
try {
  validate = ajv.compile(schema);
  report(true, "schema compiles in strict mode (draft 2020-12)");
} catch (e) {
  report(false, "schema compiles in strict mode", e.message);
  process.exit(1);
}

const goldens = fs
  .readdirSync(goldenDir)
  .filter((f) => f.endsWith(".json"))
  .sort();
report(
  goldens.length >= 8,
  "golden documents found",
  `${goldens.length} files`,
);
const docs = {};
for (const file of goldens) {
  const doc = JSON.parse(fs.readFileSync(path.join(goldenDir, file), "utf8"));
  docs[file.replace(/\.json$/, "")] = doc;
  const ok = validate(doc);
  report(
    ok,
    `golden ${file} (${doc.kind})`,
    ok
      ? ""
      : JSON.stringify(
          validate.errors
            .slice(0, 3)
            .map((e) => `${e.instancePath} ${e.message}`),
        ),
  );
}

// ---- 2. documents that break the contract are refused
const mutate = (name, base, fn) => {
  const copy = structuredClone(docs[base]);
  fn(copy);
  report(!validate(copy), `refused: ${name}`);
};
mutate("an unknown top-level field", "snapshot", (d) => (d.surprise = 1));
mutate("an unknown task field", "snapshot", (d) => (d.tasks[0].surprise = 1));
mutate(
  "a status outside the enum",
  "snapshot",
  (d) => (d.tasks[0].status = "someday"),
);
mutate(
  "a readiness state nobody defined",
  "snapshot",
  (d) => (d.tasks[0].readiness.state = "maybe"),
);
mutate("a prio of 4", "snapshot", (d) => (d.tasks[0].prio = 4));
mutate(
  "an effort that is no size or duration",
  "snapshot",
  (d) => (d.tasks[0].effort = "huge"),
);
mutate(
  "a task without its problems list",
  "snapshot",
  (d) => delete d.tasks[0].problems,
);
mutate("a vault id that is not a string", "snapshot", (d) => (d.vault.id = 7));
mutate("schema 2", "hello", (d) => (d.schema = 2));
mutate(
  "a conflict group as a tuple",
  "snapshot",
  (d) => (d.plan.conflict_groups = [[0, ["a/b"]]]),
);
mutate(
  "a digest that is not a digest",
  "areas",
  (d) => (d.digest = "sha256:XYZ"),
);
mutate(
  "an etag with the wrong length",
  "task-alpha",
  (d) => (d.task.etag = "sha256:abc"),
);
mutate(
  "an error code outside the list",
  "error-unsupported-schema",
  (d) => (d.code = "oops"),
);
mutate("a list page without its total", "list-page", (d) => delete d.total);
mutate(
  "an empty object where an array belongs",
  "areas",
  (d) => (d.areas = {}),
);
mutate(
  "an array where an object belongs",
  "snapshot",
  (d) => (d.counts.by_status = []),
);

// ---- 3. what a reader does with a document (the rules of the contract)
const SUPPORTED = 1;
const KNOWN_STATUS = new Set([
  "doing",
  "decision",
  "blocked",
  "open",
  "parked",
  "done",
]);

/** A minimal reader: refuses a newer schema, ignores unknown fields, never turns "missing" into 0. */
function readTask(entry) {
  return {
    id: String(entry.id),
    title: String(entry.title ?? ""),
    status: KNOWN_STATUS.has(entry.status) ? entry.status : "unknown",
    effortDays:
      typeof entry.effort_days === "number" ? entry.effort_days : undefined,
    roi: typeof entry.roi === "number" ? entry.roi : undefined,
    valid: entry.valid !== false,
  };
}
function readSnapshot(doc) {
  if (typeof doc.schema !== "number" || doc.schema > SUPPORTED) {
    throw new Error(
      `the engine speaks schema ${doc.schema}, this app speaks ${SUPPORTED}: update the app`,
    );
  }
  return { rev: doc.rev, tasks: doc.tasks.map(readTask) };
}

{
  const snap = structuredClone(docs.snapshot);
  const base = readSnapshot(snap);
  report(
    base.tasks.length === snap.tasks.length,
    "reader reads every task, broken ones included",
  );

  const withUnknown = structuredClone(snap);
  withUnknown.new_in_a_later_release = { a: 1 };
  withUnknown.tasks[0].new_field = "x";
  const read = readSnapshot(withUnknown);
  report(
    !("new_in_a_later_release" in read) && !("new_field" in read.tasks[0]),
    "reader ignores unknown fields",
  );

  const odd = structuredClone(snap);
  odd.tasks[0].status = "someday";
  report(
    readSnapshot(odd).tasks[0].status === "unknown",
    "reader shows an unknown enum word as unknown",
  );

  const gamma = read.tasks.find((t) => t.id === "lib.nvim/gamma");
  report(
    gamma.effortDays === undefined && gamma.roi === undefined,
    "missing means unknown, never 0 (no effort, no roi)",
  );

  const future = structuredClone(snap);
  future.schema = 2;
  let refused = false;
  try {
    readSnapshot(future);
  } catch (e) {
    refused = /update the app/.test(e.message);
  }
  report(refused, "reader refuses schema 2 and says what to do");

  const broken = read.tasks.find((t) => t.id === "lib.nvim/broken");
  report(
    broken && broken.valid === false,
    "a broken task is read, flagged valid=false",
  );
}

// ---- 4. the generated TypeScript
const types = await compile(schema, "TasksExport", {
  additionalProperties: false,
  bannerComment:
    "/* Generated from schemas/tasks-export/1/tasks-export.schema.json by contract/check.mjs. Do not edit. */",
});
report(
  !/never\[\]/.test(types),
  "generated types contain no never[] (the generator's answer to a tuple)",
);
report(
  /kind: "tasks\.snapshot"/.test(types) && /kind: "tasks\.error"/.test(types),
  "generated types carry the kinds",
);
if (write) {
  fs.writeFileSync(typesPath, types);
  console.log(`wrote ${path.relative(repo, typesPath)}`);
} else {
  const committed = fs.existsSync(typesPath)
    ? fs.readFileSync(typesPath, "utf8")
    : "";
  report(
    committed === types,
    "generated types equal the committed ones",
    committed === types
      ? ""
      : "run `node check.mjs --write` and commit schemas/tasks-export/1/tasks-export.d.ts",
  );
}

console.log(
  failures === 0
    ? "\nall contract checks passed"
    : `\n${failures} contract check(s) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
