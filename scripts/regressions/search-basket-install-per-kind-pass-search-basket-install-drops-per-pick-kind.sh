#!/usr/bin/env bash
# Regression: a Search-tab basket of two or more picks must install each pick as
# the kind the user checked.
#
# The bug: `installArgv` kept the `--formula`/`--cask` flag only for a single
# pick and emitted a batch as bare names, assuming `mt install` detects each
# name's kind. It does not - the kind flags are run-global and a bare name
# resolves formula-first - so a checked cask whose token also names a formula
# silently installed the formula while the TUI reported success.
#
# No CLI surface drives the tab's argv builder without a pty and a live
# `mt search`, so the guard is the colocated inline tests in lib_tests
# (~60s, over the usual budget; the same exception the service-label guard
# takes - there is no per-file binary that includes inline tests).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SRC="src/tui/search_tab.zig"
TEST_NAME="a mixed basket installs in a --formula pass then a --cask pass"
# Guard against a vacuous green: the test and the per-kind split must both exist.
rg -Fq -- "$TEST_NAME" "$SRC" || {
  echo "FAIL: per-kind basket install test missing from $SRC" >&2
  exit 1
}
rg -Fq -- "pending_kind" "$SRC" || {
  echo "FAIL: search tab has no per-kind install pass state" >&2
  exit 1
}
# The old bare-name batch branch must be gone (it is the bug).
if rg -Fq -- "installs the whole basket as bare names" "$SRC"; then
  echo "FAIL: bare-name batch install still pinned by a test in $SRC" >&2
  exit 1
fi
zig build test-bin >/dev/null 2>&1 || {
  echo "FAIL: could not build lib_tests" >&2
  exit 1
}
OUT=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: search basket install drops the per-pick kind (inline suite red)" >&2
  printf '%s\n' "$OUT" | rg -iE "failed|leaked|panic" >&2 || true
  exit 1
fi
echo "PASS: basket install splits by kind; a checked cask goes through --cask"
