#!/usr/bin/env bash
# Regression: the tap cask upgrade route took its PKG sudo confirmation only on
# the install pass, which runs after `installer.uninstall(token)`. A refusal —
# deterministic off a TTY — then left the Caskroom entry and every cached
# artifact for the token deleted while the DB rollback restored the row.
#
# Two halves, neither of which needs network or a build:
#   1. Ordering (static): the gate must no longer be skipped on the pass that
#      precedes the destructive step, and it must decide via the prefetch slot.
#   2. Coverage anchors: the predicate's inline test and the tap-upgrade
#      refusal test both run under `zig build test`; deleting either would drop
#      the guard while the static half kept passing, so assert they exist.
#
# Exits 0 when the bug is absent, non-zero naming the broken invariant when
# present. Static only: no network, no build, runs in milliseconds.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOCAL="$ROOT/src/cli/install/local.zig"
TESTS="$ROOT/tests/install_download_only_test.zig"
FILTER="a tap PKG cask upgrade refuses before its prefetch fills the slot"
fail=0

# 1. The PKG gate must not skip the upgrade's prefetch pass.
if grep -Fqs -- 'if (!download_only and !install_mod.confirmPkgSudo(' "$LOCAL"; then
  echo "FAIL: tap PKG confirmation still lands after installer.uninstall(token)" >&2
  fail=1
fi

# 2. The gate must consult the prefetch slot via the predicate.
if ! grep -Fqs -- 'pkgConfirmationDue(' "$LOCAL"; then
  echo "FAIL: PKG confirmation no longer consults the prefetch slot" >&2
  fail=1
fi

# 3. Coverage anchors.
if ! grep -Fqs -- 'test "pkgConfirmationDue' "$LOCAL"; then
  echo "FAIL: the predicate's inline test is missing" >&2
  fail=1
fi
if ! grep -Fqs -- "$FILTER" "$TESTS"; then
  echo "FAIL: the tap PKG-upgrade refusal test is missing" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "PASS: a tap PKG cask upgrade confirms sudo before anything is removed"
fi
exit $fail
