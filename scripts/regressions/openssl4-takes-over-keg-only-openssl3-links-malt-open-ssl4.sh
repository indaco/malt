#!/usr/bin/env bash
# Regression: a formula that declares `link_overwrite` must take over the
# prefix links a keg-only predecessor left behind. malt ignored the field,
# so every slot owned by the old keg counted as a conflict and the install
# was rolled back.
#
# Seeds a throwaway prefix with an `openssl@3` keg linked the old way, then
# runs a live `malt install openssl@4`. Needs the real API JSON and bottle.
#
# Exits 0 when the bug is absent, non-zero when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 required" >&2
  exit 2
}

SB=$(mktemp -d)
export MALT_PREFIX="$SB/p" MALT_CACHE="$SB/c"
trap 'rm -rf "$SB"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$MALT_PREFIX/db/malt.db"
mkdir -p "$MALT_PREFIX/db"
: >"$DB"
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT 1 FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table"

K="$MALT_PREFIX/Cellar/openssl@3/3.6.5"
SLOTS="bin/openssl lib/libssl.dylib include/openssl/ssl.h"
mkdir -p "$K"/{bin,lib,include/openssl} "$MALT_PREFIX"/{bin,lib,include/openssl}
sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) \
   VALUES('openssl@3','openssl@3','3.6.5','sha','$K');"
for f in $SLOTS; do
  : >"$K/$f"
  ln -s "$K/$f" "$MALT_PREFIX/$f"
  sqlite3 "$DB" \
    "INSERT INTO links(keg_id,link_path,target) \
     SELECT id,'$MALT_PREFIX/$f','$K/$f' FROM kegs WHERE name='openssl@3';"
done

"$BIN" install openssl@4 >"$SB/log" 2>&1 || {
  cat "$SB/log" >&2
  fail "openssl@4 refused the slots openssl@3 left linked"
}
pass "install succeeded"

for f in $SLOTS; do
  readlink "$MALT_PREFIX/$f" | grep -q 'Cellar/openssl@4/' ||
    fail "$f not taken over by openssl@4"
done
pass "slots point into openssl@4"

[[ -d "$K" ]] || fail "openssl@3 keg was removed"
pass "openssl@3 keg left in place"

owner=$(sqlite3 "$DB" "SELECT k.name FROM links l JOIN kegs k ON k.id=l.keg_id \
  WHERE l.link_path='$MALT_PREFIX/lib/libssl.dylib';")
[[ "$owner" == "openssl@4" ]] ||
  fail "links row still owned by '$owner'; uninstalling openssl@3 would drop the new symlink"
pass "links row moved to openssl@4"
