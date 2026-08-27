#!/usr/bin/env bash
# Regression: brace expansion in the glob builtin must stay bounded.
#
# The reported bug was a stack overflow from deeply nested braces. That is not
# reachable: the 1024-byte expansion buffer drops any pattern whose expansion
# does not fit, so nesting tops out near 513 frames (~632 KB against an 8 MB
# stack). A depth counter would be dead code.
#
# The reachable defect is the other axis. Each `{a,b}` group doubles the work,
# so cost is exponential in the number of groups while the recursion stays
# shallow - a hang rather than a crash, which is why a depth cap cannot see it.
# Measured on the unbounded walk: a 150-byte pattern of 30 groups costs
# 2,147,483,647 expansions and does not finish in a minute of ReleaseSafe. The
# pattern is formula code, so it needs a ceiling. The fix caps total expansions
# and degrades to "no match", matching how every other failure here returns.
#
# No CLI subcommand exposes the matcher in isolation, so the guard is exercised
# by colocated `test {}` blocks: one pins the shapes real formula globs use, one
# drives the exponential axis, one pins the give-up behaviour. This script
# builds the colocated test binary and judges those tests' lines.
#
# Exits 0 when the bound holds, non-zero (with a clear message) when it does
# not. No network required; finishes in about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/dsl/builtins/pathname.zig"

FILTERS=(
  "glob matches wildcards and brace alternation"
  "glob alternation cannot be driven into an unbounded expansion"
  "glob expansion budget refuses instead of exploring"
)

# If a guard test is ever deleted the name filter would match nothing and
# silently pass. Fail loudly instead.
for F in "${FILTERS[@]}"; do
  if ! grep -qs -- "$F" "$SRC"; then
    echo "FAIL: glob expansion guard test missing: $F" >&2
    exit 1
  fi
done

# Always rebuild: a stale binary from an earlier run cannot contain the guards.
BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# An unbounded matcher does not fail, it stops returning - so cap the run and
# treat exhausting the cap as the regression it is.
set +e
OUT=$(timeout 600 "$BIN" 2>&1)
RC=$?
set -e
if [[ $RC -eq 124 ]]; then
  echo "FAIL: the test binary did not finish - brace expansion is unbounded again" >&2
  exit 1
fi

for F in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$F" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: glob expansion guard test did not run: $F" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: glob brace expansion is no longer bounded: $F" >&2
    exit 1
  fi
done

echo "PASS: glob brace expansion stays bounded on formula-controlled patterns"
