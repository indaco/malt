#!/usr/bin/env bash
# Regression: `upgradeDbAtomic` records the new keg row and deletes the
# old one, but never re-records the upgraded keg's runtime dependencies.
# `deleteKeg` drops the old keg's `dependencies` rows as part of removing
# it, so after `upgrade <keg>` the keg has zero dependency edges. The next
# `cleanup` runs `findOrphans` over the (now incomplete) `dependencies`
# table, classifies the still-linked dependency keg as an orphan, and
# deletes it — silently breaking a working binary.
#
# The fix re-records the edges on the new keg id inside upgradeDbAtomic's
# transaction. No CLI subcommand drives the upgrade DB transaction in
# isolation against a seeded edge, so the guard is a colocated `test {}`
# that runs the transaction and asserts both the surviving edge and that
# `findOrphans` excludes the dependency. This script builds the test
# binary and judges that test by name; it exits non-zero if the guard
# regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="upgradeDbAtomic re-records dependency edges so cleanup keeps live runtime deps"

# The guard lives in a colocated `test {}`; if it is ever deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/cli/upgrade.zig"; then
  echo "FAIL: the upgrade dependency-rows guard test is missing from upgrade.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin -Doptimize=ReleaseSafe >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the upgrade dependency-rows guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: upgrade dropped the keg's dependency edges; cleanup would reap a live dep" >&2
  exit 1
fi

echo "PASS: upgrade re-records dependency edges; live deps survive cleanup"
