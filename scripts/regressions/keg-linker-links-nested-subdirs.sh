#!/usr/bin/env bash
# Regression: the keg linker iterated only the top level of each linkable
# dir and dropped every directory entry, so nested keg content —
# lib/pkgconfig/*.pc, share/tessdata/*, share/man/man1/* — was never
# symlinked into the prefix. The keg was intact; the prefix links were
# absent, so pkg-config/tesseract could not find their data.
#
# This script seeds a synthetic keg with both depth-1 (bin/fixture) and
# nested (share/tessdata, lib/pkgconfig) content, registers it with a
# kegs row, then runs `malt link`. After the fix every leaf — nested
# included — must resolve under the prefix.
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
mkdir -p "$PREFIX/db"

# Init the schema with a benign command against the empty DB file.
: >"$DB"
"$BIN" link __absent__ >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT 1 FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table"

# Synthetic keg: one depth-1 leaf plus nested leaves under several linkable
# dirs, including two sibling subdirs under share/ (tessdata and man) so a
# sibling-skipping walk is caught too.
KEG="$PREFIX/Cellar/fixture/1.0"
mkdir -p "$KEG/bin" "$KEG/share/tessdata" "$KEG/share/man/man1" "$KEG/lib/pkgconfig"
printf '#!/bin/sh\n' >"$KEG/bin/fixture"
chmod +x "$KEG/bin/fixture"
echo data >"$KEG/share/tessdata/eng.traineddata"
echo '.TH FIXTURE 1' >"$KEG/share/man/man1/fixture.1"
echo 'Name: fixture' >"$KEG/lib/pkgconfig/fixture.pc"

sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) \
   VALUES('fixture','fixture','1.0','sha','$KEG');"

"$BIN" link fixture >/dev/null 2>&1 || fail "malt link errored"

[[ -e "$PREFIX/bin/fixture" ]] ||
  fail "depth-1 bin/fixture not linked"
pass "depth-1 bin/fixture linked"
[[ -e "$PREFIX/share/tessdata/eng.traineddata" ]] ||
  fail "nested share/tessdata/eng.traineddata not linked"
pass "nested share/tessdata linked"
[[ -e "$PREFIX/share/man/man1/fixture.1" ]] ||
  fail "sibling nested share/man/man1/fixture.1 not linked"
pass "sibling nested share/man linked"
[[ -e "$PREFIX/lib/pkgconfig/fixture.pc" ]] ||
  fail "nested lib/pkgconfig/fixture.pc not linked"
pass "nested lib/pkgconfig linked"

# The recorded link_path must be the full nested path so unlink removes it.
sqlite3 "$DB" "SELECT link_path FROM links;" | grep -q "share/tessdata/eng.traineddata" ||
  fail "nested leaf missing a links row"
pass "nested leaf recorded in links table"

printf '\n✔ keg-linker nested-subdir regression passed\n'
