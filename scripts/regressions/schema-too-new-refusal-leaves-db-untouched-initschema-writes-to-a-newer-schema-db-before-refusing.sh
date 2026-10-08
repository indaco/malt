#!/usr/bin/env bash
# Regression: refusing a DB written by a newer malt must not write to it.
# `initSchema` used to commit the base DDL and the v1 seed before the
# version gate, so a refusal (a) added tables and a `1` version row,
# (b) re-created tables the newer malt dropped, and (c) hit `ExecFailed`
# (exit 1) instead of `SchemaTooNew` (exit 4) when the newer malt had
# reshaped a column that a base index names.
#
# Three seeds, each run through `mt tap user/repo` (refusal fires before
# any fetch):
#   min     one-table v99 DB: exit 4, schema and version rows unchanged
#   reshape renamed an indexed column: exit 4, stderr names v99, no ExecFailed
#   drop    dropped `casks`: exit 4, `casks` is not re-created
#
# Usage: scripts/regressions/schema-too-new-refusal-leaves-db-untouched-initschema-writes-to-a-newer-schema-db-before-refusing.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3.
# No network access required.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

TMP=$(mktemp -d /tmp/mt_schema_untouched.XXXXXX) || exit 2
trap 'rm -rf "$TMP"' EXIT
export MALT_OFFLINE=1 NO_COLOR=1 MALT_NO_EMOJI=1

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

snapshot() {
  sqlite3 "$1" "select type,name from sqlite_master order by 1,2; select group_concat(version) from schema_version;"
}

# Fresh prefix P=$TMP/<name>; sets DB.
new_prefix() {
  P="$TMP/$1"
  DB="$P/db/malt.db"
  mkdir -p "$P/db" "$P/cache"
}

# Let the binary create a head-version DB.
seed_head() {
  new_prefix "$1"
  MALT_PREFIX=$P MALT_CACHE=$P/cache "$BIN" list >/dev/null 2>&1 || true
  [[ -s "$DB" ]] || fail "$1: head seed did not create the DB"
}

# Runs `mt tap`, leaves stderr in $P/err, sets RC.
run_tap() {
  MALT_PREFIX=$P MALT_CACHE=$P/cache "$BIN" tap user/repo >/dev/null 2>"$P/err"
  RC=$?
}

# case 1: minimal v99
new_prefix min
sqlite3 "$DB" "CREATE TABLE schema_version(version INTEGER PRIMARY KEY); INSERT INTO schema_version VALUES(99);"
before=$(snapshot "$DB")
run_tap
[[ $RC == 4 ]] || fail "min: exit $RC, want 4"
[[ $(snapshot "$DB") == "$before" ]] || fail "min: the refusal wrote to the DB"
pass "min: refused, DB untouched"

# case 2: newer malt renamed a column that a base index names
seed_head reshape
sqlite3 "$DB" "DROP INDEX idx_kegs_store; ALTER TABLE kegs RENAME COLUMN store_sha256 TO store_digest; INSERT INTO schema_version(version) VALUES(99);"
run_tap
[[ $RC == 4 ]] || fail "reshape: exit $RC, want 4 (refusal masked)"
grep -q 'v99' "$P/err" || fail "reshape: stderr does not name v99"
! grep -q ExecFailed "$P/err" || fail "reshape: ExecFailed masks the refusal"
pass "reshape: refused with the version message"

# case 3: newer malt dropped a base table
seed_head drop
sqlite3 "$DB" "PRAGMA foreign_keys=OFF; DROP TABLE casks; INSERT INTO schema_version(version) VALUES(99);"
run_tap
[[ $RC == 4 ]] || fail "drop: exit $RC, want 4"
[[ $(sqlite3 "$DB" "select count(*) from sqlite_master where name='casks'") == 0 ]] ||
  fail "drop: the refusal re-created casks"
pass "drop: refused, casks not re-created"

printf '\n✔ a refused newer-schema DB is left untouched\n'
