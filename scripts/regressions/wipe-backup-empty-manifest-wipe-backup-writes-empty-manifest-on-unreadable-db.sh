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
trap 'chmod -R u+rwx "$tmp"; rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1
# A wipe deletes MALT_CACHE too; an inherited one would be the developer's.
export MALT_CACHE="$tmp/cache"

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

# 1b. a db/ it cannot look into, a `db` file where the directory should
# be, or a db/ symlink whose target is gone (an unmounted volume) hides
# whether malt.db exists: none is a fresh prefix
for shape in walled notdir dangling; do
  P="$tmp/$shape"
  mkdir -p "$P/Cellar"
  : >"$P/Cellar/marker"
  case $shape in
  walled)
    mkdir "$P/db"
    chmod 000 "$P/db"
    ;;
  notdir) : >"$P/db" ;;
  dangling) ln -s "$tmp/unmounted/malt-db" "$P/db" ;;
  esac
  man="$tmp/m-$shape.txt"
  if MALT_PREFIX="$P" "$BIN" purge --wipe --backup="$man" --yes >"$tmp/out" 2>&1; then
    fail "wipe succeeded with a $shape db/"
  fi
  [ -e "$man" ] && fail "manifest written despite a $shape db/"
  [ -e "$P/Cellar/marker" ] || fail "prefix destroyed after a failed backup ($shape db/)"
  grep -qi 'refusing to wipe' "$tmp/out" || fail "abort did not explain why the wipe stopped ($shape db/)"
done

# 1c. a prefix symlinked to an unmounted volume must not wipe the cache
P="$tmp/dangling-prefix"
ln -s "$tmp/unmounted/malt" "$P"
mkdir -p "$MALT_CACHE"
: >"$MALT_CACHE/marker"
man="$tmp/m-dangling-prefix.txt"
if MALT_PREFIX="$P" "$BIN" purge --wipe --backup="$man" --yes >"$tmp/out" 2>&1; then
  fail "wipe succeeded with a dangling prefix"
fi
[ -e "$man" ] && fail "manifest written despite a dangling prefix"
[ -e "$MALT_CACHE/marker" ] || fail "cache wiped after a failed backup (dangling prefix)"

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
