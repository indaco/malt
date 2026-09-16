#!/usr/bin/env bash
# Regression: `Database.close` must release the sqlite connection even when a
# prepared statement is still alive at close time and finalizes afterwards.
#
# The bug: `close` wrapped the legacy `sqlite3_close`, which refuses with
# SQLITE_BUSY while any statement is unfinalized, and the wrapper discarded the
# return. The caller believed the connection was gone while the `sqlite3`
# object and, for a WAL database, three file descriptors stayed open for the
# life of the process. `sqlite3_close_v2` never refuses: it marks the
# connection a zombie and the last `sqlite3_finalize` performs the real close.
#
# The guard is a colocated `test {}` in `src/db/sqlite.zig` that probes the
# lowest free fd before open and after close + finalize. `sqlite.zig` depends
# only on std + c_sqlite, so it compiles as a standalone `zig test` harness
# outside the build graph; the sqlite3.c flags mirror build.zig so the harness
# matches production.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present,
# when the guard test is missing, or when the v1 close call reappears in the
# module. No network required; ~5 s cold.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/db/sqlite.zig"
TEST_NAME="Database.close releases the connection once a straggling statement finalizes"

if ! grep -Fq -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: guard test missing from $SRC" >&2
  exit 1
fi

# v1 close refuses (SQLITE_BUSY) while a statement is alive; only the _v2 form may remain.
if grep -Eq 'sqlite3_close\(' "$SRC"; then
  echo "FAIL: $SRC calls sqlite3_close (use sqlite3_close_v2)" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/malt-close-leak.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

zig translate-c c/sqlite.h -Ivendor -lc >"$TMP/c_sqlite.zig"

# The C source must follow -Mroot: zig attaches it to the preceding module.
OUT=$(zig test --dep c_sqlite "-Mroot=$SRC" -lc -Ivendor \
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 vendor/sqlite3.c \
  "-Mc_sqlite=$TMP/c_sqlite.zig" --test-filter "$TEST_NAME" 2>&1) || true

if grep -Fq "All 1 tests passed" <<<"$OUT"; then
  echo "PASS: Database.close reaps a straggling statement's connection"
  exit 0
fi

echo "FAIL: Database.close leaked the sqlite connection while a statement was still alive" >&2
printf '%s\n' "$OUT" >&2
exit 1
