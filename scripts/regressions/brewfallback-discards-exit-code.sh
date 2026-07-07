#!/usr/bin/env bash
# Regression: an unknown command forwarded to real brew via brewFallback must
# (a) not append a spurious `error: BrewFailed` line from Zig's root error
# handler and (b) forward brew's real exit code. The old path collapsed every
# non-zero brew termination to error.BrewFailed, which bubbled past the dispatch
# catch and forced exit 1, clobbering `mt <brewcmd> && …` and CI conditionals.
#
# Deterministic without pinning a code: it captures brew's own exit for the same
# args and compares. Skips cleanly (exit 0) when no brew is reachable, since the
# bug only manifests with a real brew binary. No network — `brew cellar
# --badflag` fails locally and fast.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MT="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# Locate real brew at one of the paths brewFallback probes.
brew=""
for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
  [ -x "$p" ] && {
    brew="$p"
    break
  }
done
[ -z "$brew" ] && {
  echo "SKIP: no brew at hardcoded fallback paths"
  exit 0
}

mt_err=$(mktemp)
trap 'rm -f "$mt_err"' EXIT
fail=0

# Assert malt's fallback matches brew's own exit code and never appends the
# root-handler's `error: BrewFailed` line. Covers both halves of the contract:
# a failing passthrough (the original bug) and a succeeding one (exit 0 must
# stay byte-identical).
check() {
  local label=$1
  shift
  set +e
  "$brew" "$@" >/dev/null 2>&1
  local brew_code=$?
  "$MT" "$@" >/dev/null 2>"$mt_err"
  local mt_code=$?
  set -e
  if grep -q "error: BrewFailed" "$mt_err"; then
    echo "FAIL[$label]: spurious 'error: BrewFailed' printed by root handler" >&2
    fail=1
  fi
  if [ "$mt_code" -ne "$brew_code" ]; then
    echo "FAIL[$label]: exit code not forwarded (mt=$mt_code brew=$brew_code)" >&2
    fail=1
  fi
}

check nonzero cellar --badflag # unknown-to-malt, fails fast in brew, offline
check zero commands            # unknown-to-malt, lists brew commands, exit 0, offline

[ "$fail" -eq 0 ] || exit 1
echo "PASS: exit code forwarded and no spurious error line on both paths"
