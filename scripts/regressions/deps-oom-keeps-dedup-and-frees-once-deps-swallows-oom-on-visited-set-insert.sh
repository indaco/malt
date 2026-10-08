#!/usr/bin/env bash
# Regression: `mt deps -r` must fail cleanly when an allocation fails while
# recording a formula. Swallowing the visited-set insert broke dedup (a
# diamond or cycle listed a formula twice), and a later failure freed the
# formula name twice because the entry list already owned it.
#
# The defect only shows under an injected allocator, so the guard is three
# colocated `test {}` blocks in src/cli/deps.zig: sticky sweeps over every
# allocation index and a one-shot sweep that fails a single index. This
# script refuses a reintroduced `visited.put(...) catch {}`, builds the test
# binary, and judges each test by name, leaks included; a missing test fails.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in about a minute once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/cli/deps.zig"
FILTERS=(
  "collectDeps --recursive survives every allocation failure without duplicates or double frees"
  "collectDeps --recursive survives allocation failure across the API fallback and a dropped miss"
  "collectDeps --recursive keeps one row per formula when any single allocation fails"
)

if grep -nE 'visited\.put\([^)]*\)[[:space:]]*catch[[:space:]]*\{\}' "$SRC"; then
  echo "FAIL: deps swallows an allocation failure on the visited-set insert" >&2
  exit 1
fi

for f in "${FILTERS[@]}"; do
  if ! grep -qF -- "$f" "$SRC"; then
    echo "FAIL: guard test is missing from deps.zig: $f" >&2
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
    echo "FAIL: deps mishandles an allocation failure: $f" >&2
    exit 1
  fi
  # The runner checks for leaks after printing OK, so scan this test's own
  # output up to the next test line; another test's leak is not ours.
  # Capture before matching: in a pipe, awk's early exit SIGPIPEs printf and
  # pipefail turns a real match into a false negative.
  SEG=$(awk -v f="$f" 'index($0, f) { on = 1; next } on && /^[0-9]+\/[0-9]+ / { exit } on' <<<"$OUT")
  if [[ "$SEG" == *leaked* ]]; then
    echo "FAIL: deps leaks on an allocation failure: $f" >&2
    exit 1
  fi
done

echo "PASS: deps fails cleanly on allocation failure without duplicate rows or double frees"
