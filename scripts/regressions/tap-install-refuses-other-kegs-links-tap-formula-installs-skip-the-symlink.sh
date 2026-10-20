#!/usr/bin/env bash
# Regression: `install --local` of a recipe that ships a leaf another keg
# already links must refuse, as the core path does.
#
# The bug: the tap/local link step never ran the conflict pre-check, so
# `linker.link` replaced the other keg's symlink and moved its `links`
# row. Uninstalling the recipe then left the original keg unlinked.
#
# Offline: the keg is seeded by hand and a one-file tarball is planted at
# the sha-keyed tap-cache path so the install skips the download.

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "schema init did not create the db"

K="$PREFIX/Cellar/core/1.0"
mkdir -p "$K/bin" "$PREFIX/bin"
: >"$K/bin/foo"
sqlite3 "$DB" "INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path) VALUES('core','core','1.0','x','$K');"
KID=$(sqlite3 "$DB" "SELECT id FROM kegs WHERE name='core';")
ln -s "$K/bin/foo" "$PREFIX/bin/foo"
sqlite3 "$DB" "INSERT INTO links(keg_id, link_path, target) VALUES($KID,'$PREFIX/bin/foo','$K/bin/foo');"
pass "core keg seeded with bin/foo linked"

mkdir -p "$PREFIX/stage/bin"
printf '#!/bin/sh\nexit 0\n' >"$PREFIX/stage/bin/foo"
chmod +x "$PREFIX/stage/bin/foo"
tar -czf "$PREFIX/other-1.0.tar.gz" -C "$PREFIX/stage" bin
SHA=$(shasum -a 256 "$PREFIX/other-1.0.tar.gz" | cut -d' ' -f1)
cp "$PREFIX/other-1.0.tar.gz" "$MALT_CACHE/Tap/$SHA.tar.gz"
cat >"$PREFIX/other.rb" <<RB
class Other < Formula
  url "https://example.invalid/other-1.0.tar.gz"
  version "1.0"
  sha256 "$SHA"
end
RB

if "$BIN" install --local "$PREFIX/other.rb" >"$PREFIX/install.log" 2>&1; then
  fail "install took core's bin/foo"
fi
grep -q 'already linked by Cellar/core/1.0' "$PREFIX/install.log" ||
  fail "no conflict report"
pass "install refused with a conflict report"

[[ $(readlink "$PREFIX/bin/foo") == "$K/bin/foo" ]] || fail "link changed"
OWNER=$(sqlite3 "$DB" "SELECT k.name FROM links l JOIN kegs k ON k.id=l.keg_id WHERE l.link_path='$PREFIX/bin/foo';")
[[ "$OWNER" == core ]] || fail "links row moved to '$OWNER'"
[[ ! -d "$PREFIX/Cellar/other/1.0" ]] || fail "refused keg left on disk"
[[ -z $(sqlite3 "$DB" "SELECT 1 FROM kegs WHERE name='other';") ]] ||
  fail "refused keg left a kegs row"
pass "core's link, row and cellar untouched; refused keg left no trace"

echo "PASS: a local formula cannot take over another keg's links"
