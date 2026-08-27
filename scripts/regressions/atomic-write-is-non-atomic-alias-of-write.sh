#!/usr/bin/env bash
# Regression: `atomic_write` must actually be atomic.
#
# The bug: `atomicWrite` forwarded straight to `write`, which opens the target
# with create+truncate and streams into it. Truncate-in-place means an
# interrupted write - and the process-global SIGINT cancel makes interruption a
# normal event - leaves the formula author with a truncated file, when the name
# `atomic_write` entitles them to assume they get either the old content or the
# new one. Ruby's `Pathname#atomic_write` is atomic; this was an alias.
#
# The fix writes to a temp file and renames over the target, so the original
# stays readable until the rename lands. Two properties have to hold together:
# atomicity, and the no-follow rule `write` already enforced - replacing by
# rename must not become a way to write over a keg-confined symlink leaf.
#
# No CLI subcommand exposes `atomic_write` in isolation, so the guard is
# exercised by colocated `test {}` blocks. This script builds the colocated test
# binary and judges those tests' lines; it exits non-zero if a property
# regresses or a test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes in about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/dsl/builtins/pathname.zig"

FILTERS=(
  "atomic_write leaves the original readable until the new content lands"
  "atomic_write refuses to follow a symlink out of the keg"
  "atomic_write keeps the target's existing mode instead of widening it"
  "atomic_write keeps the mode of a target it cannot open for reading"
)

# If a guard test is ever deleted the name filter would match nothing and
# silently pass. Fail loudly instead.
for F in "${FILTERS[@]}"; do
  if ! grep -qs -- "$F" "$SRC"; then
    echo "FAIL: atomic-write guard test missing: $F" >&2
    exit 1
  fi
done

# Always rebuild: a stale binary from an earlier run cannot contain the guards.
BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# A hung test blocks forever otherwise; fail in a bounded window instead.
set +e
OUT=$(timeout 600 "$BIN" 2>&1)
RC=$?
set -e
if [[ $RC -eq 124 ]]; then
  echo "FAIL: the test binary did not finish" >&2
  exit 1
fi
for F in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$F" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: atomic-write guard test did not run: $F" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: atomic_write regressed: $F" >&2
    exit 1
  fi
done

echo "PASS: atomic_write is atomic, confined, and mode-preserving"
