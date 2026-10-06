#!/usr/bin/env bash
# Run the specs: scripts/test.sh [name-fragment ...]
# lib.nvim is looked up like TESTS/run.lua does (LIB_NVIM_DIR, LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, .deps/lib.nvim, a sibling
# checkout, lazy's data folder). Exit 0: all pass, 1: a spec failed, 2: lib.nvim not found / no spec matched.
set -euo pipefail

command -v nvim >/dev/null 2>&1 || {
  echo "error: nvim not found on PATH" >&2
  exit 2
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec nvim -n -i NONE --headless -u NONE -l TESTS/run.lua "$@"
