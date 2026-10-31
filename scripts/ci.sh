#!/usr/bin/env bash
#
# The CI entry point of this repo: `:MyPlugins ci tasks.nvim` (Neovim) runs exactly this, and so does
# .github/workflows/ci.yml (the self-hosted runner for pushes, GitHub-hosted runners for pull requests).
# It is a shim: the pipeline lives in the `ci` section of .testing.lua and runs with `testing ci` (testing.nvim,
# docs/CI.md); scripts/test.sh finds testing.nvim and its dependencies.
#
#   scripts/ci.sh            stylua --check, luacheck, test suite, conformance gate, contract check (Node)
#   scripts/ci.sh --fast     only stylua --check and luacheck (what the pre-push hook runs)
#   scripts/ci.sh <options>  anything else goes to `testing ci` (--step=a,b, --keep-going, --json=<file>, ...)
#
# Exit code 0: green. 1: a step failed. 2: configuration error. 3: a tool or dependency was not found (a gate that
# did not run must never look green).
# `testing ci` writes .ci-last.json (commit, time, green/red; gitignored) for `:MyPlugins ci status`.
# What each gate checks lives in stylua.toml / .luacheckrc / scripts/test.sh / scripts/contract.sh.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

export TASKS_REQUIRE_SNACKS="${TASKS_REQUIRE_SNACKS:-1}"

args=()
for a in "$@"; do
  if [[ "$a" == "--fast" ]]; then
    args+=("--profile=fast")
  else
    args+=("$a")
  fi
done

exec scripts/test.sh ci ${args[@]+"${args[@]}"}
