#!/usr/bin/env bash
# Regression: a bottle's `.bottle/etc` / `.bottle/var` overlay was never
# poured into the prefix, so formulas like fontconfig could not load
# their default config; fontconfig then fell back to a compiled-in XML
# blob whose `/opt/homebrew` paths sit MID-string in one `__cstring`
# literal, which the head-anchored cstring patcher never rewrote. Net
# effect: unwritable brew-prefixed cache dirs and a font cache that was
# never built, behind an install that looked healthy.
#
# Both defects are pinned by colocated `test {}` blocks; this script
# asserts the fixes are present statically, then runs the two test
# binaries and judges those guards' lines.
#
# Exits 0 when the bugs are absent, non-zero (with a message naming
# the failing assertion) when present. No network required; finishes
# well under 30s once the test binaries are built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# 1. Static guard: the relocation pipeline must pour the overlay.
if ! grep -q 'installBottleEtcVar' "$ROOT/src/core/cellar.zig"; then
  echo "FAIL: relocateKegTree no longer pours the .bottle etc/var overlay" >&2
  exit 1
fi

# 2. Behavioural guards live in colocated `test {}` blocks; if either is
#    ever deleted the runs below would silently pass. Fail loudly instead.
MIDSTR_TEST="patchPathsCollecting relocates prefixes embedded mid-string in a cstring slot"
OVERLAY_TEST="installBottleEtcVar pours a missing overlay file into the prefix"
if ! grep -Rqs -- "$MIDSTR_TEST" "$ROOT/tests/patcher_test.zig"; then
  echo "FAIL: mid-string cstring guard test missing from patcher_test.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$OVERLAY_TEST" "$ROOT/tests/cellar_test.zig"; then
  echo "FAIL: bottle overlay guard test missing from cellar_test.zig" >&2
  exit 1
fi

# Rebuild the test binaries so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# The runners have no per-test filter, so run each suite and judge only
# its guard's line: a pass ends in "OK".
check() {
  local bin="$1" name="$2"
  local out line
  out=$("$ROOT/zig-out/test-bin/$bin" 2>&1 || true)
  line=$(printf '%s\n' "$out" | grep -F -- "$name" || true)
  if [[ -z "$line" ]]; then
    echo "FAIL: guard test did not run in $bin: $name" >&2
    exit 1
  fi
  if [[ "$line" != *OK ]]; then
    echo "FAIL: $name: $line" >&2
    exit 1
  fi
}

check patcher_test "$MIDSTR_TEST"
check cellar_test "$OVERLAY_TEST"

echo "OK: bottle etc/var overlay poured; embedded config paths relocated"
