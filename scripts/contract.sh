#!/usr/bin/env bash
#
# The `contract` step of the pipeline (.testing.lua): the contract tasks-export/1 seen from outside -- the golden
# documents against the JSON Schema (Ajv, strict), the documents that must be refused, the rules for a reader, and the
# generated TypeScript types (contract/check.mjs).
#
#   scripts/contract.sh            check
#   scripts/contract.sh --write    regenerate contract/tasks-export.d.ts (what `node check.mjs --write` does)
#
# The dev dependencies of contract/ (package-lock.json) are installed with `npm ci` when contract/node_modules is
# missing or older than the lockfile, so a fresh checkout and a hosted runner need no extra step.
#
# Exit code 0: green. 1: a check failed, or node/npm is missing or the install failed (a check that did not run must
# never look green).

set -euo pipefail

cd "$(dirname "$0")/../contract"

command -v node >/dev/null 2>&1 || {
  echo "error: node is not on PATH (the contract check needs Node >= 22)." >&2
  exit 1
}

# Also when package-lock.json is newer than the installed tree (npm records it in node_modules/.package-lock.json).
if [[ ! -d node_modules || package-lock.json -nt node_modules/.package-lock.json ]]; then
  command -v npm >/dev/null 2>&1 || {
    echo "error: npm is not on PATH (needed once to install the dev dependencies of contract/)." >&2
    exit 1
  }
  echo "contract/node_modules is missing or older than package-lock.json: npm ci"
  # --ignore-scripts: none of the dev dependencies needs an install script, and this runs on the maintainer's machine.
  npm ci --ignore-scripts --no-audit --no-fund
fi

node --version
exec node check.mjs "$@"
