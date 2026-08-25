#!/usr/bin/env bash
# Regression: in `migrate --parallel` every worker shares one SQLite
# connection. The store-refcount bump (`Store.incrementRef`) runs an
# autocommit `INSERT INTO store_refs` guarded only by the store's own
# mutex, NOT the migrate DB lock (`db_mu`) that serialises the keg
# transactions. Because `last_insert_rowid()` is connection-global, a
# peer worker's refcount insert can land between this worker's
# `INSERT INTO kegs` and its `last_insert_rowid()` read, handing the
# worker a foreign rowid. Links and deps then attach to the wrong keg,
# and a rollback deletes an unrelated keg row.
#
# The fix serialises the refcount bump under `db_mu` so no connection
# write escapes the lock. No CLI subcommand drives two record-path
# workers against one connection in isolation, so the guard is a
# colocated `test {}` that hammers `incrementRef` from peer threads
# while one worker records kegs, asserting each worker's keg_id still
# resolves to its own `kegs` row. This script builds the test binary
# and judges that test by name; it exits non-zero if the guard
# regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in about a minute once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="incrementRef under db_mu keeps each worker's keg_id bound to its own kegs row"

# The guard lives in a colocated `test {}`; if it is ever deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/cli/migrate/keg.zig"; then
  echo "FAIL: the last_insert_rowid race guard test is missing from keg.zig" >&2
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
  echo "FAIL: the last_insert_rowid race guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a peer worker's refcount insert corrupted last_insert_rowid" >&2
  exit 1
fi

echo "PASS: keg_id isolation holds under concurrent incrementRef"
