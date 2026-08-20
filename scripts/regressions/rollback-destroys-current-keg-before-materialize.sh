#!/usr/bin/env bash
# Regression: a `mt rollback` that cannot materialize its target leaves the
# currently installed version fully usable.
#
# Pre-fix, rollback ran `linker.unlink` and removed the current Cellar dir
# BEFORE calling `cellar.materializeWithCellar`. Store entries are on-disk
# input, so a corrupt or unreadable one made materialize fail after the
# destructive half had already landed:
#
#   ✗ Failed to materialize wget 1.20 from store
#
# leaving no Cellar tree, no `bin/` symlink, and a kegs row pointing at a
# path that no longer exists - a machine with no working version and no
# restore path. `upgrade` already materialized first and restored old links
# on failure; rollback now follows the same order.
#
# Usage: scripts/regressions/rollback-destroys-current-keg-before-materialize.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` on PATH. No network.

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
[[ "$(id -u)" -ne 0 ]] || {
  echo "skip: chmod 000 does not deny root" >&2
  exit 0
}

PREFIX="/tmp/mt_rb_materialize_fail_$$"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX/db"
cleanup() {
  chmod -R u+rwx "$PREFIX" 2>/dev/null || true
  rm -rf "$PREFIX"
}
trap cleanup EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Bootstrap the schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Seed a real installation of wget 1.22: Cellar tree, bin/ symlink, and
# the kegs + links rows that `unlink` walks.
KEG="$PREFIX/Cellar/wget/1.22"
mkdir -p "$KEG/bin" "$PREFIX/bin"
printf '#!/bin/sh\n' >"$KEG/bin/wget"
chmod +x "$KEG/bin/wget"
ln -s "$KEG/bin/wget" "$PREFIX/bin/wget"

sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.22', 0, 'sha_cur', '$KEG', 'direct');
INSERT INTO links (keg_id, link_path, target)
VALUES (last_insert_rowid(), '$PREFIX/bin/wget', '$KEG/bin/wget');
SQL

# Seed a rollback target that is discoverable but unreadable, so
# materialize fails the way a corrupt store entry does.
OLD="$PREFIX/store/sha_old/wget/1.20"
mkdir -p "$OLD"
touch "$OLD/INSTALL_RECEIPT.json"
chmod 000 "$OLD"

if "$BIN" rollback wget >/dev/null 2>&1; then
  fail "rollback succeeded against an unreadable store entry"
fi
pass "rollback refused and exited non-zero"

[[ -d "$KEG" ]] || fail "current Cellar dir was destroyed by the failed rollback"
pass "Cellar/wget/1.22 survived"

[[ -L "$PREFIX/bin/wget" && -e "$PREFIX/bin/wget" ]] ||
  fail "current bin/wget symlink was destroyed by the failed rollback"
pass "bin/wget still resolves"

[[ "$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='wget';")" == "1.22" ]] ||
  fail "kegs row no longer names the current version"
pass "kegs row still names 1.22"

[[ "$(sqlite3 "$DB" "SELECT count(*) FROM links WHERE link_path='$PREFIX/bin/wget';")" == "1" ]] ||
  fail "links row for the current version was dropped"
pass "links row survived"

echo "rollback keeps the current version on a failed materialize: OK"
