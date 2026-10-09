#!/usr/bin/env bash
# Regression: `mt tap` (listing) must fail loudly when malt.db exists but
# cannot be opened. Reporting "No taps registered" / `[]` with exit 0 makes a
# broken database look like an empty tap list.
#
# Seeds: a mode-000 database and a file that is not a database. Control: an
# absent db/ is still a fresh prefix and answers empty without creating it.
#
# Usage: scripts/regressions/tap-listing-refuses-unreadable-db-tap-listing-reads-an-unreadable-db-as-no-taps.sh
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

PREFIX=$(mktemp -d /tmp/mt_tap_list_open.XXXXXX) || exit 2
trap 'chmod -R u+rwx "$PREFIX" 2>/dev/null; rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db" "$PREFIX/cache"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

DB="$PREFIX/db/malt.db"
SHA=$(printf '0%.0s' {1..40})
NEEDLE="Cannot open the tap database"

reset() {
  chmod 755 "$PREFIX/db" 2>/dev/null
  chmod 600 "$DB" 2>/dev/null
  rm -f "$DB" "$DB-wal" "$DB-shm"
}
seed_unreadable() {
  reset
  sqlite3 "$DB" "CREATE TABLE t(x);"
  chmod 000 "$DB"
}
seed_unreadable_dir() {
  reset
  sqlite3 "$DB" "CREATE TABLE t(x);"
  chmod 000 "$PREFIX/db"
}
seed_not_a_db() {
  reset
  head -c 4096 /dev/urandom >"$DB"
}

failed=0
check() {
  local name=$1 seed=$2 argv out err rc
  for argv in "tap" "--json tap" "tap user/repo" "tap --refresh user/repo" "tap --refresh --all" "tap --pin user/repo $SHA"; do
    "$seed"
    read -ra args <<<"$argv"
    out=$("$BIN" "${args[@]}" 2>"$PREFIX/err")
    rc=$?
    err=$(<"$PREFIX/err")
    if [[ $rc == 1 && $err == *"$NEEDLE"* && $err != *"No taps registered"* && $out != "[]" ]]; then
      printf '  ✓ %s [%s]\n' "$name" "$argv"
    else
      printf '  ✗ %s [%s] exit=%s out=%q err=%q\n' "$name" "$argv" "$rc" "$out" "$err" >&2
      failed=1
    fi
  done
}

# Root ignores mode bits, so the chmod seeds would pass vacuously.
if [[ $(id -u) == 0 ]]; then
  echo "  - skipping mode-000 cases as root"
else
  check unreadable seed_unreadable
  check unreadable-dir seed_unreadable_dir
fi
check not-a-database seed_not_a_db

# Control: an absent db/ is a fresh prefix and stays unbuilt.
reset
rm -rf "$PREFIX/db"
if [[ $("$BIN" --json tap) == "[]" && ! -d "$PREFIX/db" ]]; then
  echo "  ✓ fresh prefix keeps its empty answer"
else
  echo "  ✗ fresh prefix lost its empty answer" >&2
  failed=1
fi

exit $failed
