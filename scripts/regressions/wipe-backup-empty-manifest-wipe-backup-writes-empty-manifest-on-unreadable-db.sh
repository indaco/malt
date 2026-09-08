#!/usr/bin/env bash
# Regression: a database that cannot be read must never be reported as "no
# packages installed". `purge --wipe --backup` used to write a header-only
# manifest, announce success, and then delete the prefix — destroying the only
# record of what was installed. `mt backup` did the same over unreadable
# tables. A prefix with no database at all is still an honest empty backup.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network; all state lives under a throwaway prefix removed on EXIT.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The shell harness runs the built binary; `zig build test` does not refresh
# it, so a stale binary would mask the fix.
zig build >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# 1. unreadable DB must abort before deleting anything
P="$tmp/corrupt"
mkdir -p "$P/db" "$P/Cellar"
printf 'not a sqlite file\n' >"$P/db/malt.db"
: >"$P/Cellar/marker"
man="$tmp/m1.txt"
if MALT_PREFIX="$P" "$BIN" purge --wipe --backup="$man" --yes >"$tmp/out" 2>&1; then
  fail "wipe succeeded with an unreadable database"
fi
[ -e "$man" ] && fail "manifest written despite unreadable DB"
[ -e "$P/Cellar/marker" ] || fail "prefix destroyed after failed backup"
[ -e "$P/db/malt.db" ] || fail "database removed after failed backup"
grep -qi 'database' "$tmp/out" || fail "abort message does not name the database"
grep -qi 'refusing to wipe' "$tmp/out" || fail "abort did not explain why the wipe stopped"

# 2. absent DB is an honest empty manifest, not a failure
P2="$tmp/fresh"
mkdir -p "$P2/db" "$P2/Cellar"
: >"$P2/Cellar/marker"
man2="$tmp/m2.txt"
MALT_PREFIX="$P2" "$BIN" purge --wipe --backup="$man2" --yes >/dev/null 2>&1 ||
  fail "wipe on a DB-less prefix should still succeed"
[ -s "$man2" ] || fail "manifest missing for the absent-DB case"

# 3. mt backup must not report success over an unreadable table
P3="$tmp/badtable"
mkdir -p "$P3/db"
sqlite3 "$P3/db/malt.db" "CREATE TABLE kegs(x);"
if MALT_PREFIX="$P3" "$BIN" backup -o "$tmp/b.txt" >"$tmp/bout" 2>&1; then
  fail "backup reported success over an unreadable kegs table"
fi
grep -q 'packages)' "$tmp/bout" && fail "backup printed a success summary over an unreadable table"

printf '  ✓ unreadable database aborts the wipe with the prefix intact\n'
