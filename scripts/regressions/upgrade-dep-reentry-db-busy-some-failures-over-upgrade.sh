#!/usr/bin/env bash
# Regression: `upgradeFormula` reads the installed keg row with a stepped
# `SELECT … LIMIT 1` and used to keep that statement open until the function
# returned (its columns were borrowed slices needed far downstream). That
# open statement pins connection A's WAL read snapshot. When a formula gains
# a new dependency, the same function re-enters `installAll`, which opens a
# SECOND connection and commits dep writes — advancing the WAL past A's
# snapshot. The parent path's later writes (`incrementRef`, `BEGIN IMMEDIATE`)
# then cannot promote the stale snapshot to a writer and get an immediate
# SQLITE_BUSY (the busy handler is skipped for this self-deadlock), surfacing
# as `RefCountError` and "database is locked" and aborting the upgrade.
#
# The fix copies the row into owned storage and finalizes the lookup
# statement (`readOldKeg`) before any code opens another connection, so the
# parent connection holds no read snapshot when the WAL advances.
#
# Driving the real network upgrade is unnecessary (and would need bottles):
# the falsifiable invariant lives at the DB layer, guarded by a colocated
# `test {}` in upgrade.zig that reproduces the two-connection WAL race and
# asserts the parent stays writable. This script builds the test binary and
# judges that test by name; it exits non-zero if the guard regresses or the
# test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="readOldKeg releases the WAL read snapshot before a second connection advances the WAL"

# The guard is a colocated `test {}`; if it is ever deleted the name filter
# below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/cli/upgrade.zig"; then
  echo "FAIL: the keg-snapshot-release guard test is missing from upgrade.zig" >&2
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
  echo "FAIL: the keg-snapshot-release guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: the parent connection hit SQLITE_BUSY after a re-entrant dep install advanced the WAL" >&2
  exit 1
fi

echo "PASS: the keg lookup releases its WAL read snapshot before dep re-entry writes"
