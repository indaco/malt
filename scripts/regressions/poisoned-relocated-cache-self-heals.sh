#!/usr/bin/env bash
# Regression: malt must not install a keg it knows the loader would reject,
# and a bad relocated-cache entry must not survive a second install.
#
# The bug: nothing verified the keg after materialization. A relocation defect
# put a binary with a duplicate LC_RPATH in the Cellar, malt printed
# "installed", and dyld aborted every launch. Worse, the broken keg was then
# snapshotted into `store-relocated/<sha>`, and the warm-reinstall
# short-circuit serves that snapshot before extraction or patching run - so the
# shipped patcher fix could never reach an already-cached package.
#
# The fix walks the materialized keg on both paths and checks the invariants
# malt owns: no duplicate LC_RPATH within an arch slice, no `@@HOMEBREW_*@@`
# token left in a load-command path. A cold-path violation fails the install
# (the caller's errdefer wipes the partial keg); a warm-path violation evicts
# the cache entry and falls through to a full re-relocation, so a poisoned
# entry heals itself instead of persisting.
#
# This script asserts the wiring is present statically, then runs the
# integration test binary and judges the two guard tests' lines. No network;
# finishes well under 30s once the test binaries are built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

PATCHER="$ROOT/src/macho/patcher.zig"
CELLAR="$ROOT/src/core/cellar.zig"
FACADE="$ROOT/src/core/patch.zig"

# 1. The check itself must exist behind the relocation facade, so the ELF
#    backend has to supply its own rather than silently skipping verification.
if ! grep -q 'pub fn verifyFile' "$PATCHER"; then
  echo "FAIL: patcher no longer exposes a post-relocation verify entry point" >&2
  exit 1
fi
if ! grep -q 'backend.verifyFile' "$FACADE"; then
  echo "FAIL: relocation facade no longer re-exports verifyFile" >&2
  exit 1
fi

# 2. Both materialize paths must run it. One call site means the other path
#    ships unverified - which is exactly how the cached keg escaped the fix.
sites=$(grep -c 'walkMachOAndVerify(' "$CELLAR" || true)
if [ "$sites" -lt 3 ]; then
  echo "FAIL: expected the verify walk plus a cold- and warm-path call site in cellar.zig (found $sites)" >&2
  exit 1
fi

# 3. A failed warm-path check must evict the entry, or the next install serves
#    the same broken keg again.
if ! grep -q 'relocated_store.remove' "$CELLAR"; then
  echo "FAIL: a cached keg that fails verification is no longer evicted" >&2
  exit 1
fi

# 4. The warm path skips the walk for entries this malt already checked. Losing
#    the `isVerified` gate costs ~50% of a warm reinstall; losing `markVerified`
#    means no entry is ever trusted and the walk runs forever.
for token in 'isVerified' 'markVerified'; do
  if ! grep -q "relocated_store.$token" "$CELLAR"; then
    echo "FAIL: cellar no longer uses relocated_store.$token; warm reinstalls pay the full keg walk" >&2
    exit 1
  fi
done

# 5. The behavioural guards live in tests/cellar_test.zig; if either is deleted
#    the run below would silently pass. Fail loudly instead.
HEAL_TEST="materializeWithCellar rebuilds a cached keg whose binary would abort dyld"
REFUSE_TEST="materializeWithCellar refuses a keg whose binary kept an unsubstituted placeholder"
for t in "$HEAL_TEST" "$REFUSE_TEST"; do
  if ! grep -Rqs -- "$t" "$ROOT/tests/cellar_test.zig"; then
    echo "FAIL: guard test missing from cellar_test.zig: $t" >&2
    exit 1
  fi
done

# Rebuild the test binaries so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the suite and judge only the two
# guard lines: a pass ends in "OK".
out=$("$ROOT/zig-out/test-bin/cellar_test" 2>&1 || true)
for t in "$HEAL_TEST" "$REFUSE_TEST"; do
  line=$(printf '%s\n' "$out" | grep -F -- "$t" || true)
  if [ -z "$line" ]; then
    echo "FAIL: guard test did not run in cellar_test: $t" >&2
    exit 1
  fi
  if [ "${line##*OK}" != "" ]; then
    echo "FAIL: $line" >&2
    exit 1
  fi
done

echo "OK: a keg that would not load is refused, and a poisoned cache entry heals"
