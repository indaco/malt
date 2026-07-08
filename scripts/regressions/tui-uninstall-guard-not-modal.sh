#!/usr/bin/env bash
# Regression: the Installed tab's [y/N] uninstall guard must latch its
# target when armed. Confirming with `y` after the selection moved (or
# after a background reload shifted the rows) must uninstall the package
# the guard was armed on, never the live selection.
#
# The bug: the guard was a bare bool, navigation keys bypassed it, and
# both the banner and the uninstall spawn read the selection live at
# confirmation time — so `x` on pkgA, `down`, `y` uninstalled pkgB.
#
# The logic is pure-core, so this leans on the always-rebuilt unit tests
# plus source-level guards that fail on a pre-fix tree (Zig has no
# --test-filter, per the repo's established pattern).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "REGRESSION: $1" >&2
  exit 1
}

# 1. The latch must exist: a bare bool guard is the bug.
if rg -q 'confirm_uninstall: bool' src/tui/installed_tab.zig; then
  fail "uninstall guard is still a target-less bool"
fi

# 2. The shell must not resolve the target live at confirmation time.
if rg -A2 'fn doUninstall' src/tui/app.zig | rg -q 'selectedPkg'; then
  fail "doUninstall still reads the live selection"
fi

# 3. The latch/modality unit tests must exist and pass.
rg -q 'latches' src/tui/installed_tab.zig ||
  fail "guard-latch tests missing from installed_tab.zig"
zig build test || fail "unit tests failed"

echo "OK: uninstall guard latches its target"
