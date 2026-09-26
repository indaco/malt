#!/usr/bin/env bash
# Regression: `mt uninstall` fails loud when the package database fails,
# and never tears a keg down on a DB error.
#
# Pre-fix every DB error in the formula branch was a successful return:
# exit 0 with nothing removed, a dependents query that errored read as
# "no dependents", and a failed keg-row delete still removed the Cellar dir,
# leaving a row that points at nothing.
#
# Behaviours pinned (sabotage SQL is the deterministic stand-in for
# SQLITE_BUSY/FULL/IOERR):
#   1. prepare failure      -> rc != 0, row + Cellar intact
#   2. dependents step error -> rc != 0, row + Cellar intact (gate fails closed)
#   3. keg-row delete blocked -> rc != 0, row + Cellar intact, recovery named
#   4. links rows unreadable -> rc != 0, row + Cellar + tracked symlink intact
#   5. a legal 505-byte prefix gets an explicit error instead of a silent exit 0
#
# Usage: scripts/regressions/uninstall-aborts-on-db-failure-uninstall-swallows-db-failures-and-exits-zero.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, `sqlite3` on
# PATH. No network.

set -euo pipefail

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

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
export MALT_CACHE="$T/cache"
export MALT_PREFIX="$T/p"
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
DB="$MALT_PREFIX/db/malt.db"

# First run creates the DB through initSchema; "not installed" is expected.
"$BIN" uninstall x >/dev/null 2>&1 || true

sqlite3 "$DB" "INSERT INTO kegs (name,full_name,version,revision,store_sha256,cellar_path)
  VALUES ('jq','jq','1.0',0,'jq','Cellar/jq/1.0'), ('yq','yq','1.0',0,'yq','Cellar/yq/1.0');
  INSERT INTO links (keg_id, link_path, target) SELECT id, '$MALT_PREFIX/bin/jq',
    '$MALT_PREFIX/Cellar/jq/1.0' FROM kegs WHERE name='jq';"
command cp -f "$DB" "$T/seed.db"

fail() {
  echo "FAIL $1" >&2
  cat "$T/out" >&2 || true
  exit 1
}

run_case() { # $1=label $2=sabotage-sql
  command cp -f "$T/seed.db" "$DB"
  mkdir -p "$MALT_PREFIX/Cellar/jq/1.0" "$MALT_PREFIX/bin"
  ln -sfn "$MALT_PREFIX/Cellar/jq/1.0" "$MALT_PREFIX/bin/jq"
  sqlite3 "$DB" "$2"
  local rc=0
  "$BIN" uninstall jq >"$T/out" 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || fail "$1: exit 0"
  [[ "$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='jq'")" == 1 ]] || fail "$1: keg row gone"
  [[ -d "$MALT_PREFIX/Cellar/jq/1.0" ]] || fail "$1: Cellar entry removed"
  echo "ok: $1"
}

run_case prepare "ALTER TABLE kegs RENAME COLUMN revision TO rev;"
run_case depgate "INSERT INTO dependencies VALUES ((SELECT id FROM kegs WHERE name='yq'),'jq','runtime');
  PRAGMA foreign_keys=OFF; ALTER TABLE dependencies RENAME TO d2;
  CREATE VIEW dependencies AS SELECT keg_id,dep_name,dep_type FROM d2
    WHERE abs(-9223372036854775807-1) > 0;"
run_case finalize "CREATE TRIGGER b BEFORE DELETE ON kegs BEGIN SELECT RAISE(ABORT,'x'); END;"
grep -q 'mt link jq' "$T/out" || fail "finalize: recovery not named"
run_case links "ALTER TABLE links RENAME COLUMN link_path TO lp;"
[[ -L "$MALT_PREFIX/bin/jq" ]] || fail "links: tracked symlink removed"

# A legal prefix (limit 512) that overflowed the old 512-byte path buffers.
# No keg can be seeded there: SQLite's own pathname cap rejects the db first,
# so the fixed binary must say so rather than exit 0.
# Full 99-byte segments, then one of 1..100 bytes so no count goes <= 0.
long="$T"
for ((i = 0; i < (505 - ${#T} - 2) / 100; i++)); do long+="/$(printf '%099d' 0)"; done
long+="/$(printf "%0$((505 - ${#long} - 1))d" 0)"
((${#long} == 505)) || {
  echo "bad long prefix length ${#long}" >&2
  exit 2
}
mkdir -p "$long/db"
rc=0
MALT_PREFIX="$long" "$BIN" uninstall jq >"$T/out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "long-prefix: exit 0"
[[ -s "$T/out" ]] || fail "long-prefix: no message"
echo "ok: long-prefix"

echo "ok: uninstall fails loud on DB errors"
