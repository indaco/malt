#!/usr/bin/env bash
# Regression: recursive copy must stay bounded on a source tree deeper than a
# path can address.
#
# `copyDirRecursive` recurses with no explicit depth counter. It is safe today
# only because every level re-joins an absolute path and opens it with
# `openDirAbsolute`, so the walk self-terminates once the joined path passes
# PATH_MAX - roughly 470 frames, well inside the 8 MB main-thread stack. That
# bound is incidental, not designed: the moment the walk is converted to
# handle-relative descent (`openat`-style, the natural fix for the silent
# truncation at the ceiling) the bound disappears and an explicit cap becomes
# mandatory. This guard exists to fail loudly at that moment.
#
# No CLI subcommand exposes `cp_r` in isolation, so the invariant is exercised
# by a colocated `test {}` block that builds a tree deeper than PATH_MAX can
# address and asserts the copy terminates. This script builds the colocated
# test binary and judges that test's line; it exits non-zero if the guard
# regresses or the test goes missing.
#
# Exits 0 when the recursion is bounded, non-zero (with a clear message) when
# it is not. No network required; finishes in about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/dsl/builtins/fileutils.zig"

TEST_NAME='cp_r on a tree deeper than PATH_MAX terminates instead of overflowing'

# If the guard test is ever deleted the name filter below would match nothing
# and silently pass. Fail loudly instead.
if ! grep -qs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: recursion-bound guard test missing: $TEST_NAME" >&2
  exit 1
fi

# Always rebuild: a stale binary from an earlier run cannot contain the guard.
BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# A stack overflow kills the test process instead of reporting a failure, so
# judge the guard's own line and reject a crash signature anywhere in the run.
OUT=$("$BIN" 2>&1 || true)

if printf '%s\n' "$OUT" | grep -Eqi -- 'stack overflow|segmentation fault|SIGSEGV'; then
  echo "FAIL: the deep-tree copy crashed - the path-length bound went away without a depth cap" >&2
  exit 1
fi

LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: recursion-bound guard test did not run: $TEST_NAME" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: recursive copy is no longer bounded on a tree deeper than PATH_MAX" >&2
  exit 1
fi

echo "PASS: cp_r recursion stays bounded on a tree deeper than PATH_MAX"
