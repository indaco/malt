#!/usr/bin/env bash
# Regression: `Database.open` must release the sqlite handle when a startup
# PRAGMA fails after `sqlite3_open_v2` succeeded.
#
# The bug: the open-failure arm closed the raw handle, but the three PRAGMA
# arms each returned `OpenFailed` with the freshly constructed `Database`
# abandoned - connection and file descriptor stayed open for the life of the
# process. `sqlite3_open_v2` never reads the database header, so a non-database
# file at the path reaches that arm deterministically: the first PRAGMA is the
# first read and fails with `SQLITE_NOTADB`.
#
# The guard is a colocated `test {}` in `src/db/sqlite.zig` that probes the
# lowest free fd before and after a failed open. `sqlite.zig` depends only on
# std + c_sqlite, so it compiles as a standalone `zig test` harness outside the
# build graph; the sqlite3.c flags mirror build.zig so the harness matches
# production.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present
# or when the guard test is missing. No network required; ~5 s cold.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/db/sqlite.zig"
TEST_NAME="Database.open closes the handle when a PRAGMA fails after a successful open"

if ! grep -Fq -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: guard test missing from $SRC" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/malt-pragma-leak.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

zig translate-c c/sqlite.h -Ivendor -lc >"$TMP/c_sqlite.zig"

# The C source must follow -Mroot: zig attaches it to the preceding module.
OUT=$(zig test --dep c_sqlite "-Mroot=$SRC" -lc -Ivendor \
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 vendor/sqlite3.c \
  "-Mc_sqlite=$TMP/c_sqlite.zig" --test-filter "$TEST_NAME" 2>&1) || true

if grep -Fq "All 1 tests passed" <<<"$OUT"; then
  echo "PASS: failing PRAGMA closes the sqlite handle"
  exit 0
fi

echo "FAIL: Database.open leaked the sqlite handle on a failing PRAGMA" >&2
printf '%s\n' "$OUT" >&2
exit 1
