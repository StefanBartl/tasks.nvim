#!/usr/bin/env bash
#
# Runs the spec suite of this project with testing.nvim:
#
#   scripts/test.sh                  every spec under TESTS/
#   scripts/test.sh --file config    only spec files whose name contains "config"
#   scripts/test.sh --json ir.json   also write the machine-readable result (the IR)
#
# Everything after the script name is handed to `testing run .` unchanged.
#
# Exit code 0: all specs passed. 1: a spec failed, OR nvim / the runner / a dependency was not
# found (the harness not running must never look like a green run). Never waits silently.
# A dependency <name> is looked up in, in this order:
#   1. $<NAME>_DIR                  (testing.nvim -> $TESTING_NVIM_DIR, lib.nvim -> $LIB_NVIM_DIR)
#   2. <repo>/.deps/<name>          (what CI checks out)
#   3. <repo>/../<name>             (a sibling checkout)
#   4. stdpath('data')/lazy/<name>  (what a plugin manager installed)
# snacks.nvim (override $SNACKS_DIR) is optional: the dashboard specs drive its picker. It is looked up the
# same way and handed to the specs; when it is not found the run goes on and says so first.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# The runner first, then what the project needs (this list is the `deps` of .testing.lua).
DEPS=('testing.nvim' 'lib.nvim')
# What the specs use when it is there. Not a `deps` entry: the runner would fail the whole run without it.
OPTIONAL_DEPS=('snacks.nvim')

fail() {
  printf '\033[31m%s\033[0m\n' "$1" >&2
  exit 1
}

command -v nvim >/dev/null 2>&1 || fail "error: nvim is not on PATH."

# stdpath('data') of the default app name, computed before NVIM_APPNAME is changed below.
data_dir() {
  local app="${NVIM_APPNAME:-nvim}"
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s' "$LOCALAPPDATA/$app-data"
  else
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/$app"
  fi
}
DATA="$(data_dir)"

marker_of() {
  case "$1" in
    lib.nvim) printf 'lua/lib/nvim' ;;
    snacks.nvim) printf 'lua/snacks/picker' ;;
    testing.nvim) printf 'lua/testing' ;;
    *) printf 'lua' ;;
  esac
}

env_name_of() {
  case "$1" in
    # the name the dashboard specs read (and .testing.lua lets through)
    snacks.nvim) printf 'SNACKS_DIR' ;;
    *) printf '%s_DIR' "$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_')" ;;
  esac
}

# A path as shown in an error message: one separator style on every platform (Git Bash would
# otherwise print /e/repos/x next to C:\Users\x\AppData\Local).
show_path() {
  if command -v cygpath >/dev/null 2>&1 && cygpath -m -- "$1" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${1//\\//}"
}

# resolve <name> [optional]: sets RESOLVED, or exits 1 naming all four places. With `optional`, a dependency
# that is not found returns 1 instead; an override that is set but not valid still exits 1.
resolve() {
  local name="$1" optional="${2:-}" marker envname override
  marker="$(marker_of "$name")"
  envname="$(env_name_of "$name")"
  override="${!envname:-}"

  if [[ -n "$override" ]]; then
    # An override that is set decides alone: it is never skipped for another checkout.
    if [[ -d "$override/$marker" ]]; then
      RESOLVED="$override"
      return 0
    fi
  else
    local dir
    for dir in "$ROOT/.deps/$name" "$ROOT/../$name" "$DATA/lazy/$name"; do
      if [[ -d "$dir/$marker" ]]; then
        RESOLVED="$dir"
        return 0
      fi
    done
  fi

  if [[ "$optional" == "optional" && -z "$override" ]]; then
    RESOLVED=""
    return 1
  fi

  # The paths as text are for the message only: showing one can start a process (cygpath), so not before.
  local p1="unset" p2 p3 p4
  [[ -n "$override" ]] && p1="$(show_path "$override")"
  p2="$(show_path "$ROOT/.deps/$name")"
  p3="$(show_path "$ROOT/../$name")"
  p4="$(show_path "$DATA/lazy/$name")"
  fail "error: dependency '$name' not found. Searched, in this order:
  1. \$$envname ($p1)
  2. .deps/$name ($p2)
  3. ../$name ($p3)
  4. stdpath('data')/lazy/$name ($p4)
Set \$$envname, or clone it to .deps/$name, or place it beside this repo."
}

DRIVER=""
for name in "${DEPS[@]}"; do
  resolve "$name"
  # The runner resolves the same dependencies itself; hand it exactly what was found here.
  export "$(env_name_of "$name")=$RESOLVED"
  if [[ "$name" == "testing.nvim" ]]; then
    DRIVER="$RESOLVED/scripts/testing.lua"
  fi
done
[[ -f "$DRIVER" ]] || fail "error: the runner entry is missing: $DRIVER"

# The runner gives every child editor a sandbox stdpath('data'), so a spec cannot look into the plugin
# manager's folder itself: it gets the directory found here (.testing.lua lists the variable in `env_allow`).
for name in "${OPTIONAL_DEPS[@]}"; do
  if resolve "$name" optional; then
    export "$(env_name_of "$name")=$RESOLVED"
  else
    printf '\033[33mnote: optional dependency %s not found; the picker part of the dashboard specs cannot run.\n  Set $%s, or clone it to .deps/%s, or place it beside this repo.\033[0m\n' \
      "$name" "$(env_name_of "$name")" "$name" >&2
  fi
done

# Throwaway app name: the run gets its own stdpath("config"/"data"/"state"), never the developer's.
export NVIM_APPNAME="${NVIM_APPNAME:-tasks_nvim-tests}"
# A run with `isolated = "none"` writes the plugin's state where Neovim keeps it: point state and
# cache at a scratch directory, removed afterwards (a child editor has a sandbox of its own).
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
if command -v cygpath >/dev/null 2>&1; then
  scratch="$(cygpath -m "$scratch")"
fi
export XDG_STATE_HOME="$scratch/state"
export XDG_CACHE_HOME="$scratch/cache"

# No `exec`: the trap must remove the scratch directory afterwards (`set -e` keeps the exit code).
nvim -n -i NONE --headless -u NONE -l "$DRIVER" run . --sentinel 'TASKS_TESTS_OK' "$@"
