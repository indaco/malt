#!/usr/bin/env bash
# Regression: End must jump the cursor to the last visible (filtered) row in
# every TUI tab. Home works; End must not be a dead affordance.
#
# The bug: the shell routes .end to the active tab because only the tab knows
# its row count, but no tab's step had a .end arm — the key fell into the
# else => {} of all five tabs.
#
# The logic is pure-core, so this leans on the always-rebuilt unit tests plus
# source-level guards that fail on a pre-fix tree (Zig has no --test-filter,
# per the repo's established pattern).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "REGRESSION: $1" >&2
  exit 1
}

# 1. Every tab's step must have a .end arm; else => {} swallowing it is the bug.
for tab in installed_tab outdated_tab services_tab doctor_tab search_tab; do
  rg -q '^\s*\.end\s*=>' "src/tui/${tab}.zig" ||
    fail "${tab}.zig step does not handle .end"
done

# 2. The shell must still defer .end to the tab (the row count lives there).
rg -q '\.space, \.end, \.esc => routeToTab' src/tui/app.zig ||
  fail "app.zig no longer routes .end to the active tab"

# 3. The last-row unit tests must exist and pass.
rg -qi 'end.*last' src/tui/installed_tab.zig ||
  fail "End-key last-row test missing from installed_tab.zig"
zig build test || fail "unit tests failed"

echo "OK: End jumps to the last row in every tab"
