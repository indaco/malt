#!/usr/bin/env bash
# Regression: a resize (SIGWINCH, installed without SA_RESTART) that lands
# during a blocked tty or sandbox-pump write must not end the session.
#
# The raw write loops used to treat EINTR as a hard failure. The runtime
# checks are inline tests (lib_tests, over the 30 s budget), so this guard
# pins the source shape instead: every raw write loop retries EINTR, and installWinch
# keeps flags = 0 so the blocking tty read still wakes on resize.
# No build, no network, no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0

for f in src/tui/term.zig src/tui/app.zig src/ui/term_restore.zig src/core/sandbox/macos.zig; do
  [[ -f "$ROOT/$f" ]] || {
    echo "FAIL: $f: missing" >&2
    fail=1
    continue
  }
  # Each `const n = std.c.write(` must be followed by the retry, before the
  # bail-out. Test code writes with `_ =`, so it is not counted.
  if ! awk '/const n = std\.c\.write\(/ { loops++; w = NR; next }
    w && NR == w + 1 && /if \(n < 0 and std\.posix\.errno\(n\) == \.INTR\) continue;/ { ok++ }
    END { exit !(loops > 0 && loops == ok) }' "$ROOT/$f"; then
    echo "FAIL: $f: a raw write loop has no EINTR retry" >&2
    fail=1
  fi
done

# installWinch must keep flags = 0, so SIGWINCH still interrupts the blocking
# read. installWinchFlagOnly (CLI progress) is a different handler.
f=src/ui/termsize.zig
if ! awk '/^pub fn installWinch\(/ { in_fn = 1 }
  in_fn && /\.flags = 0,/ { ok = 1 }
  in_fn && /^}/ { in_fn = 0 }
  END { exit !ok }' "$ROOT/$f" 2>/dev/null; then
  echo "FAIL: $f: installWinch must set flags = 0 (no SA_RESTART)" >&2
  fail=1
fi

exit "$fail"
