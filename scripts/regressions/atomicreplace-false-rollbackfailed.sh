#!/usr/bin/env bash
# Regression: a self-update swap whose staged -> target rename fails but whose
# .old -> target restore succeeds must be reported as SwapFailed, not
# RollbackFailed.
#
# The bug: the second rename's failure was mapped unconditionally to
# RollbackFailed while an errdefer quietly restored target from .old. The tree
# ended up consistent (original binary back in place, .old consumed) but the
# caller printed "rollback also failed" plus a `mv <self>.old <self>` hint that
# errors because .old no longer exists. The genuine inconsistent state (the
# restore itself failing) was unreachable.
#
# The failure needs the second rename to fail after the first succeeds, which
# is not reachable from the malt CLI. A colocated `test {}` block injects that
# rename failure through a file-private seam and asserts the returned error is
# SwapFailed, target holds the original bytes, and no <target>.old remains.
# This script builds the colocated test binary and runs that test by name; it
# exits non-zero if the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes in about a minute once the test binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/update/swap.zig"

TEST_NAME="atomicReplace reports a successful restore as SwapFailed, not RollbackFailed"

# The guard lives in a colocated `test {}` block; if it is ever deleted the
# name match below would find nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: rollback-reporting guard test missing from swap.zig" >&2
  exit 1
fi

# Rebuild the colocated test binary so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", the bug prints the returned code.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: rollback-reporting guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: successful rollback still reported as RollbackFailed: $LINE" >&2
  exit 1
fi

echo "PASS: rollback after rename-#2 failure reports SwapFailed, target restored, no .old"
