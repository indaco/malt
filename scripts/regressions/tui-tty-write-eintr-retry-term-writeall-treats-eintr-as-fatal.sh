#!/usr/bin/env bash
# Regression: a resize (SIGWINCH, installed without SA_RESTART) that lands
# during a blocked tty write must not end the TUI session.
#
# The raw write loops used to treat EINTR as a hard failure. The runtime
# check is an inline test in src/tui/term.zig (lib_tests, over the 30 s
# budget), so this guard pins the source shape instead: each loop retries
# EINTR, and SIGWINCH keeps flags = 0 so the blocking tty read still wakes
# on resize. No build, no network, no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0

for f in src/tui/term.zig src/tui/app.zig src/ui/term_restore.zig; do
  # The retry must sit on the line right after the write, before the bail-out.
  if ! awk '/const n = std\.c\.write\(/ { w = NR; next }
    w && NR == w + 1 && /if \(n < 0 and std\.posix\.errno\(n\) == \.INTR\) continue;/ { ok = 1 }
    END { exit !ok }' "$ROOT/$f"; then
    echo "FAIL: $f: raw write loop has no EINTR retry" >&2
    fail=1
  fi
done

if grep -Eq 'flags = .*RESTART' "$ROOT/src/ui/termsize.zig"; then
  echo "FAIL: src/ui/termsize.zig: SIGWINCH must not use SA_RESTART" >&2
  fail=1
fi

exit "$fail"
