#!/usr/bin/env bash
# Regression: in the Outdated tab, `a` (select all) armed every non-pinned row
# even when a filter was hiding most of them, so `u` upgraded packages the user
# never saw. The guard is a colocated `test {}` in outdated_tab.zig (nothing
# drives the tab's pure `step` from the CLI); this script rebuilds the test
# binary and judges that test by name. Exits 0 when the bug is absent, non-zero
# when it regresses or the test goes missing. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="a with an active filter checks only the visible rows"

# The guard lives in a colocated `test {}`; if it is ever deleted the name filter
# below would match nothing and silently pass. Fail loudly instead.
if ! grep -Fqs -- "$FILTER" "$ROOT/src/tui/outdated_tab.zig"; then
  echo "FAIL: filter-scoped select-all guard test missing from outdated_tab.zig" >&2
  exit 1
fi

# Always rebuild (Debug shares the cache with `zig build test`): a stale binary
# from another session must not produce a green.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$(MALT_PREFIX=/tmp/malt-test-prefix "$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the filter-scoped select-all guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: 'a' under a filter armed rows the filter hides - bulk upgrade of unseen packages" >&2
  exit 1
fi

echo "PASS: outdated 'a' only arms the rows the active filter shows"
