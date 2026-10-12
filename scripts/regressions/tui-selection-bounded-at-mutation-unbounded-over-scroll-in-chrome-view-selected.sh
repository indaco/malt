#!/usr/bin/env bash
# Regression: Up must move the cursor on the first press after Down overshoots.
#
# The shell used to add to `chrome.view.selected` without the list length;
# the render-time clamp worked on a copy, so the excess stayed in state and
# Up stayed inert until it was spent. The guard is an inline test in
# src/tui/app.zig, so this runs `lib_tests` and judges that one test.
#
# Runs over the 30 s target (minutes on a cold cache: it rebuilds and runs the
# whole `lib_tests` binary), like the other `lib_tests`-driven regressions.
# Creates no temp state; no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="Down past the last row then Up moves the cursor on the first press"

# A deleted guard would match nothing and pass silently; fail instead.
grep -Fqs -- "$FILTER" "$ROOT/src/tui/app.zig" || {
  echo "FAIL: overshoot guard test missing from src/tui/app.zig" >&2
  exit 1
}
# Always rebuild so the binary matches the current source.
# A caller's MALT_* must not point the tests at a real prefix or cache.
(cd "$ROOT" && env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: zig build test-bin" >&2
  exit 1
}
OUT=$(env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix "$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
[[ -n "$LINE" ]] || {
  echo "FAIL: overshoot guard test did not run" >&2
  exit 1
}
[[ "$LINE" == *OK ]] || {
  echo "FAIL: Up stays inert after a Down overshoot (selected grows past the list)" >&2
  exit 1
}
echo "PASS: the TUI selection stays inside the list at the mutation site"
