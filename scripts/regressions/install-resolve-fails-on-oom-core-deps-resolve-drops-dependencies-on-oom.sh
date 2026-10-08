#!/usr/bin/env bash
# Regression: the install-path dependency resolve must fail when an
# allocation fails, never return success with a truncated graph. Swallowing
# OOM on the queue, result, visited set or the dep-name dupes dropped deps,
# emptied the closure, or listed the root as its own dependency, so
# `mt install` linked a formula without its runtime deps and exited 0.
#
# The defect only shows under an injected allocator, so the guard is the
# colocated `test {}` blocks in src/core/deps.zig: one-shot sweeps that fail
# a single allocation index (the only harness that reaches a drop after an
# isolated failure) and a sticky checkAllAllocationFailures leak sweep.
# This script refuses a reintroduced allocation swallow on the resolve path,
# builds the test binary, and judges each test by name, leaks included; a
# missing test fails.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in about a minute once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/deps.zig"
FILTERS=(
  "resolve fails instead of returning a truncated graph when any allocation fails"
  "resolve survives every allocation failure without leaking"
  "resolve fails instead of dropping a wide fan-out when the queue cannot grow"
  "resolve reports a parse-time allocation failure instead of falling back"
)

# Only the resolve path; findOrphans has its own allocation-failure tests.
BODY=$(awk '/^pub fn resolve\(/ || /^fn (dupeDepNames|getDepsFromValue)\(/ { on = 1 } on { print } on && /^}/ { on = 0 }' "$SRC")
if printf '%s\n' "$BODY" | grep -nE '(pushBack|append|put|dupe|toOwnedSlice)\(.*\)[[:space:]]*catch[[:space:]]*(\{|blk:|continue)'; then
  echo "FAIL: resolve swallows an allocation failure instead of failing" >&2
  exit 1
fi

for f in "${FILTERS[@]}"; do
  if ! grep -qF -- "$f" "$SRC"; then
    echo "FAIL: guard test is missing from core/deps.zig: $f" >&2
    exit 1
  fi
done

# Always rebuild: a stale binary would judge the tree it was built from.
# Debug keeps the leak and double-free checks and stays inside the runner's cap.
(cd "$ROOT" && env -u MALT_PREFIX zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# Same throwaway prefix build.zig gives the test run, never the live install.
OUT=$(MALT_PREFIX=/tmp/malt-test-prefix "$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
for f in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$f" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: guard test did not run: $f" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: resolve mishandles an allocation failure: $f" >&2
    exit 1
  fi
  # The runner checks for leaks after printing OK, so scan this test's own
  # output up to the next test line; another test's leak is not ours.
  # Capture before matching: in a pipe, awk's early exit SIGPIPEs printf and
  # pipefail turns a real match into a false negative.
  SEG=$(awk -v f="$f" 'index($0, f) { on = 1; next } on && /^[0-9]+\/[0-9]+ / { exit } on' <<<"$OUT")
  if [[ "$SEG" == *leaked* ]]; then
    echo "FAIL: resolve leaks on an allocation failure: $f" >&2
    exit 1
  fi
done

echo "PASS: resolve fails on allocation failure instead of returning a truncated graph"
