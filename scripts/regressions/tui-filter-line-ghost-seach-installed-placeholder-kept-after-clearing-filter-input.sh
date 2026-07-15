#!/usr/bin/env bash
# Regression: the `/`-filter line in `mt tui` is shared shell chrome whose width
# shrinks as the query is backspaced. Once the per-frame whole-screen clear was
# dropped (the flicker fix), every region self-erases via moveClear — but the
# filter line kept a moveTo-only paint, so the old caret at the now-vacant
# rightmost column was never overwritten and ghosted one column to the right.
#
# app.zig is not a leaf module (it imports the whole tui graph), so the
# copy-and-append pattern used by tui-wrap-rune-boundary-*.sh does not apply and
# a full `zig build test` here would both duplicate `just test` and blow the
# time budget. The behavioural assertion (a focused, non-empty filter frame must
# emit `\x1b[K` on the filter row) rides `just test`; this script is the fast
# structural backstop guarding that the fix and its guard test stay in place.
#
# Exits 0 when the filter row self-erases (moveClear) and the guard test is
# present; non-zero with a clear message otherwise. No build, no network, <1s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The fix: the filter line must be painted with moveClear, not a moveTo-only
# paint that leaves last frame's caret un-erased on a shrinking query.
rg -q 'moveClear\(r\.filter\.row' "$ROOT/src/tui/app.zig" ||
  {
    echo "FAIL: filter line no longer painted with moveClear — caret can ghost" >&2
    exit 1
  }

# The behavioural guard: the inline frame test that asserts the filter row emits
# `\x1b[K` must survive, or the fix could be reverted without a test noticing.
rg -q 'self-erases the filter row' "$ROOT/src/tui/app.zig" ||
  {
    echo "FAIL: filter-row self-erase guard test is missing" >&2
    exit 1
  }

echo "OK: mt tui filter row self-erases; no caret ghost on shrink"
