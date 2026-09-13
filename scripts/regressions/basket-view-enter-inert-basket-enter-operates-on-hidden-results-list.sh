#!/usr/bin/env bash
# Regression: Enter in the Search-tab basket view must not act on the results
# list hidden behind it.
#
# The bug: Enter was not gated on the active view. In the basket view it still
# resolved the results-list cursor, then either closed an info pane that was
# not painted or fetched `mt info` for a results row the user could not see;
# the pane stayed hidden until the user toggled back to the results view.
#
# No CLI surface drives the tab's key handler without a pty and a live
# `mt search`, so the guard is the colocated inline tests in lib_tests
# (~60s, over the usual budget; the same exception the service-label guard
# takes - there is no per-file binary that includes inline tests).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SRC="src/tui/search_tab.zig"
TEST_NAME="enter is inert in the basket view"
# Guard against a vacuous green: the test and the view gate must both exist.
rg -Fq -- "$TEST_NAME" "$SRC" || {
  echo "FAIL: basket-view Enter gate test missing from $SRC" >&2
  exit 1
}
rg -Fq -- "s.view != .results or" "$SRC" || {
  echo "FAIL: the active row is not gated on the results view in $SRC" >&2
  exit 1
}
zig build test-bin >/dev/null 2>&1 || {
  echo "FAIL: could not build lib_tests" >&2
  exit 1
}
OUT=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: basket-view Enter acts on the hidden results list (inline suite red)" >&2
  printf '%s\n' "$OUT" | rg -iE "failed|leaked|panic" >&2 || true
  exit 1
fi
echo "PASS: Enter in the basket view leaves the hidden results list alone"
