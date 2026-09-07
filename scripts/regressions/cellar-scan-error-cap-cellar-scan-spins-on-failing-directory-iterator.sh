#!/usr/bin/env bash
# Regression: a Cellar scan that hits a wedged directory read must stop.
#
# `std.Io.Dir.Iterator` gives no forward-progress guarantee when `next`
# fails, so an errno that reproduces on every call used to turn the scan
# into an unbounded retry loop. No `malt` subcommand can present that
# fault, so the guard judges the colocated integration tests instead.
#
# A reintroduced spin does not fail the suite, it stops returning — so
# the timeout arm (rc 124) is itself a regression signal.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/tests/migrate_smoke_test.zig"

FILTERS=(
  "scanCellarKegs aborts instead of spinning on a non-advancing iterator error"
  "scanCellarKegs tolerates consecutive errors below the cap"
  "scanCellarKegs resets its error budget after a successful read"
  "scanCellarKegs keeps the names gathered before the abort"
)

for F in "${FILTERS[@]}"; do
  grep -qs -- "$F" "$SRC" || {
    echo "FAIL: guard test missing: $F" >&2
    exit 1
  }
done

# Build fresh: a stale binary from an earlier run cannot carry the guard.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  {
    echo "FAIL: could not build test binaries (zig build test-bin)" >&2
    exit 1
  }

set +e
OUT=$(timeout 120 "$ROOT/zig-out/test-bin/migrate_smoke_test" 2>&1)
RC=$?
set -e
[[ $RC -eq 124 ]] && {
  echo "FAIL: migrate_smoke_test did not finish - the Cellar scan spins on iterator error again" >&2
  exit 1
}
# Any other failure in this binary is a regression too - the per-test
# checks below only see the guards, not a break elsewhere in the suite.
[[ $RC -ne 0 ]] && {
  echo "FAIL: migrate_smoke_test exited $RC" >&2
  printf '%s\n' "$OUT" | grep -E "FAIL|error:" | head -5 >&2
  exit 1
}

for F in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$F" || true)
  [[ -z "$LINE" ]] && {
    echo "FAIL: guard test did not run: $F" >&2
    exit 1
  }
  [[ "$LINE" != *OK ]] && {
    echo "FAIL: Cellar scan error handling regressed: $F" >&2
    exit 1
  }
done

echo "PASS: Cellar scan aborts on a non-advancing iterator error"
exit 0
