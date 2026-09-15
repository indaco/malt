#!/usr/bin/env bash
# Regression: `mt rollback` re-checks the keg row after it holds malt.lock.
#
# Pre-fix, the row (id, version, revision, cellar path) and the store scan
# were read before the lock and trusted afterwards. A concurrent upgrade or
# install that committed while rollback waited invalidated all of them; the
# only thing that stopped the stale swap was an accidental SQLite snapshot
# error from the read statement left open across the wait, which aborted
# silently after materializing the target under Cellar/.
#
# The race window is not reachable from the outside without instrumentation,
# so this pins the two properties that make it safe:
#   1. source order: inside `execute`, no statement is kept open across
#      `LockFile.acquire`, and a keg re-check sits between the acquire and
#      `materializeWithCellar`;
#   2. behaviour: the colocated two-connection test sees a commit made by
#      another connection and can still open a write transaction.
#
# Usage: scripts/regressions/rollback-revalidates-keg-row-under-lock-rollback-reads-state-before-acquiring-lock.sh
# Requirements: zig on PATH. No network, creates no state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/cli/rollback.zig"
TEST_NAME="rollback re-validates the keg row under the lock after a concurrent commit"

body=$(awk '/^pub fn execute\(/,/^}/' "$SRC")
line() { printf '%s\n' "$body" | grep -n -- "$1" | head -1 | cut -d: -f1 || true; }

acquire=$(line 'LockFile.acquire')
materialize=$(line 'materializeWithCellar(')
recheck=$(line 'kegRowStillCurrent(')
open_stmt=$(line 'defer .*\.finalize()')

[[ -n "$acquire" && -n "$materialize" ]] || {
  echo "FAIL: could not locate the lock acquire / materialize calls in execute" >&2
  exit 1
}
if [[ -n "$open_stmt" && "$open_stmt" -lt "$acquire" ]]; then
  echo "FAIL: a read statement stays open across the lock wait (line $open_stmt of execute)" >&2
  exit 1
fi
if [[ -z "$recheck" || "$recheck" -lt "$acquire" || "$recheck" -gt "$materialize" ]]; then
  echo "FAIL: no keg row re-check between LockFile.acquire and materializeWithCellar" >&2
  exit 1
fi

# The behavioural half lives in a colocated `test {}` block; a deleted test
# would otherwise match nothing below and pass. Fail loudly instead.
if ! grep -qF -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: re-validation test missing from rollback.zig" >&2
  exit 1
fi

if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"

# The runner has no per-test filter, so run the colocated suite and judge only
# this test's line: a pass ends in "OK".
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: re-validation test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: re-validation test red: $LINE" >&2
  exit 1
fi

echo "PASS: rollback re-validates the keg row under malt.lock"
