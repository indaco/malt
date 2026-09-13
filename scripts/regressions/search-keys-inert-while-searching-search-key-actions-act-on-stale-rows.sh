#!/usr/bin/env bash
# Regression: Search-tab key actions must be inert while a re-query is searching.
#
# The bug: during a re-query the body paints only "searching…", but `items`
# still holds the previous query's rows. `hitTest` refused them for the mouse,
# yet the keyboard had no phase gate: Enter fetched info for a hidden row,
# space latched a hidden row into the basket, and `i` installed the previous
# query's active row.
#
# No CLI surface drives the tab's key handler without a pty and a live
# `mt search`, so the guard is the colocated inline tests in lib_tests
# (~60s, over the usual budget; the same exception the service-label guard
# takes - there is no per-file binary that includes inline tests).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SRC="src/tui/search_tab.zig"
TEST_NAME="enter, space and i are inert while a re-query is searching"
# Guard against a vacuous green: the test and the phase gate must both exist.
rg -Fq -- "$TEST_NAME" "$SRC" || {
  echo "FAIL: searching-phase key gate test missing from $SRC" >&2
  exit 1
}
rg -Fq -- "s.phase != .loaded or s.items.len == 0" "$SRC" || {
  echo "FAIL: the active row is not gated on the loaded phase in $SRC" >&2
  exit 1
}
zig build test-bin >/dev/null 2>&1 || {
  echo "FAIL: could not build lib_tests" >&2
  exit 1
}
OUT=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: search keys act on stale rows while searching (inline suite red)" >&2
  printf '%s\n' "$OUT" | rg -iE "failed|leaked|panic" >&2 || true
  exit 1
fi
echo "PASS: enter, space and i are inert while a re-query is searching"
