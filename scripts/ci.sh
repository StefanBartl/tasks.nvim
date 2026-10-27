#!/usr/bin/env bash
#
# The local CI entry point of this repo: `:MyPlugins ci tasks.nvim` (Neovim) runs exactly this. The repository is
# private and has no paid GitHub plan; .github/workflows/ci.yml runs the same gates on a self-hosted runner.
#
#   scripts/ci.sh            stylua --check, luacheck, test suite, conformance gate
#                            (the schema contract check needs Node and runs in the CI job `contract` only)
#   scripts/ci.sh --fast     only stylua --check and luacheck (what the pre-push hook runs)
#
# Exit code 0: green. 1: a step failed OR a tool was not found (a gate that did not run must never look green).
# The result is written to .ci-last.json (commit, time, green/red; gitignored) for `:MyPlugins ci status`.
# What each gate checks lives in stylua.toml / .luacheckrc / scripts/test.sh; this script only wires them up.
# Dependencies (lib.nvim, testing.nvim) are found by scripts/test.sh itself:
# $<NAME>_DIR, <repo>/.deps/<name>, <repo>/../<name>, the plugin manager's folder.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

write_result() {
  local state="$1" note="${2:-}" commit dirty=false
  commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  # A result for uncommitted files is no proof for the commit.
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && dirty=true
  note="${note//\"/\'}"
  printf '{"repo":"tasks.nvim","commit":"%s","dirty":%s,"time":"%s","state":"%s","note":"%s"}\n' \
    "$commit" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$note" >"$ROOT/.ci-last.json"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '\033[31merror: %s is not on PATH.\033[0m\n' "$1" >&2
    write_result red "$1 missing"
    exit 1
  }
}

step() {
  local name="$1"
  shift
  echo "== $name"
  if ! "$@"; then
    write_result red "$name"
    printf '\033[31mci: RED at "%s"\033[0m\n' "$name" >&2
    exit 1
  fi
}

export TASKS_REQUIRE_SNACKS="${TASKS_REQUIRE_SNACKS:-1}"

need stylua
need luacheck
[[ $FAST -eq 0 ]] && need nvim

step "stylua --check" stylua --check .
step "luacheck" luacheck lua TESTS scripts

if [[ $FAST -eq 0 ]]; then
  nvim --version | sed -n 1p
  step "test suite" scripts/test.sh
  step "conformance gate" scripts/test.sh conformance
fi

write_result green
echo "ci: green"
