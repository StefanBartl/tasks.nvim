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
# missing, so a fresh checkout and a hosted runner need no extra step.
#
# Exit code 0: green. 1: a check failed, or node/npm is missing or the install failed (a check that did not run must
# never look green).

set -euo pipefail

cd "$(dirname "$0")/../contract"

command -v node >/dev/null 2>&1 || {
  echo "error: node is not on PATH (the contract check needs Node >= 22)." >&2
  exit 1
}

if [[ ! -d node_modules ]]; then
  echo "contract/node_modules is missing: npm ci"
  npm ci --no-audit --no-fund
fi

node --version
exec node check.mjs "$@"
