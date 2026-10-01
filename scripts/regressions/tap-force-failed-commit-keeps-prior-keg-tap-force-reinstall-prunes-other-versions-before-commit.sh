#!/usr/bin/env bash
# Regression: a failed tap `--force` COMMIT must keep the prior keg installed.
# No CLI way to fail a COMMIT, so this runs the integration test that injects one.

set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# An exported MALT_* leaks into unrelated tests.
env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >"$log" 2>&1 || {
  cat "$log"
  echo "FAIL: build"
  exit 1
}

rc=0
MALT_PREFIX=/tmp/malt-test-prefix zig-out/test-bin/install_record_rollback_test >"$log" 2>&1 || rc=$?
grep -q "failed commit keeps the other-version keg" "$log" || {
  cat "$log"
  echo "FAIL: guard test did not run"
  exit 1
}
if [ "$rc" -ne 0 ]; then
  cat "$log"
  echo "FAIL: tap --force deletes other-version kegs before db.commit(); a failed commit strands their rows"
  exit 1
fi
# The test drives the seam, not the caller: guard that the caller still
# routes the sweep and the opt link through it, and that inside it the opt
# link follows the commit and precedes the sweep.
src=src/cli/install/local.zig
seam=$(grep -n '^pub fn commitAndSweep' "$src" | cut -d: -f1 || true)
call=$(grep -n 'try commitAndSweep(' "$src" | cut -d: -f1 || true)
commit=$(grep -n 'db.commit() catch' "$src" | cut -d: -f1 | awk -v s="$seam" '$1 > s' | head -1 || true)
opt=$(grep -n 'linker.linkOpt(name' "$src" | cut -d: -f1 | awk -v s="$seam" '$1 > s' | head -1 || true)
sweep=$(grep -n 'dropStaleKegRows(' "$src" | cut -d: -f1 | awk -v s="$seam" '$1 > s' | head -1 || true)
early=$(grep -nE 'dropStaleKegRows\(|pruneOtherCellarVersionsForReinstall\(|linkOpt\(' "$src" | cut -d: -f1 | awk -v s="$seam" '$1 < s' || true)
if [ -z "$seam" ] || [ -z "$call" ] || [ -z "$commit" ] || [ -z "$opt" ] || [ -z "$sweep" ] ||
  [ "$opt" -lt "$commit" ] || [ "$sweep" -lt "$opt" ] || [ -n "$early" ]; then
  echo "FAIL: $src must commit, then repoint opt, then sweep, all inside commitAndSweep"
  exit 1
fi

echo "OK: failed tap --force commit leaves the prior keg installed"
