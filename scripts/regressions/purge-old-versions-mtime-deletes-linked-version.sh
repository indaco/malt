#!/usr/bin/env bash
# Regression: `purge --old-versions` chose which Cellar/<formula>/<version>
# dir to keep by highest directory mtime, never consulting the `kegs`
# table. When a stale sibling's mtime exceeds the live keg's (a touch, a
# backup restore that rewrites mtimes, an in-place rebuild), the sweep
# deleted the DB-linked version and left dangling symlinks behind.
#
# This script seeds Cellar/foo/{1,2} with bin/foo -> v2, a kegs row for
# version 2, then inverts mtimes so v1 looks newer. After the fix the
# DB-linked v2 must survive, the stale v1 must be swept, and bin/foo must
# still resolve.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s once built.

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

PREFIX="$(mktemp -d)/malt-prefix"
export MALT_PREFIX="$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/bin"

# Init the schema by running the sweep once on a Cellar-free prefix: the
# empty DB file makes the cask pass open + initSchema, and with no Cellar
# dirs nothing is touched.
: >"$DB"
"$BIN" purge --old-versions -y >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT 1 FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table"

# Stand up the bug shape: two version dirs, bin/foo linked into v2, kegs
# row pins version 2 as live.
mkdir -p "$PREFIX/Cellar/foo/1" "$PREFIX/Cellar/foo/2/bin"
: >"$PREFIX/Cellar/foo/2/bin/foo"
ln -s "../Cellar/foo/2/bin/foo" "$PREFIX/bin/foo"
sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) \
   VALUES('foo','foo','2','sha','$PREFIX/Cellar/foo/2');"

# Invert mtimes so the stale v1 looks newer than the live v2.
touch "$PREFIX/Cellar/foo/2"
sleep 1
touch "$PREFIX/Cellar/foo/1"

"$BIN" purge --old-versions -y >/dev/null 2>&1 || fail "purge --old-versions errored"

[[ -d "$PREFIX/Cellar/foo/2" ]] || fail "linked v2 was deleted"
pass "DB-linked v2 survived the sweep"
[[ ! -d "$PREFIX/Cellar/foo/1" ]] || fail "stale v1 not swept"
pass "stale v1 swept"
[[ -e "$PREFIX/bin/foo" ]] || fail "bin/foo dangles after sweep"
pass "bin/foo still resolves"

printf '\n✔ purge-old-versions keep-linked-keg regression passed\n'
