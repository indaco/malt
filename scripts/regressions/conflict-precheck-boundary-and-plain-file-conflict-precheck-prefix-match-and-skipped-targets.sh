#!/usr/bin/env bash
# Regression: the link pre-check accepted any existing symlink whose target
# merely started with the keg path, so a link into a sibling version
# (Cellar/foo/1.0_1 vs Cellar/foo/1.0) passed as "same keg". Independently,
# a regular file occupying a leaf slot made readLink fail and the failure
# was swallowed, so the slot looked free. `malt link` then replaced both
# entries: the sibling's live symlink was retargeted and the user's file
# was lost, with exit 0.
#
# This script seeds a throwaway prefix with a kegs row for Cellar/foo/1.0,
# a prefix symlink into sibling Cellar/foo/1.0_1, and a regular file in a
# second leaf slot, then runs `malt link foo` without --overwrite. After
# the fix the pre-check must refuse both and leave the prefix untouched.
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

# Init the schema with a benign command against the empty DB file.
: >"$DB"
"$BIN" link __absent__ >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT 1 FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table"

# Keg under test plus a sibling version dir whose path continues the
# version string without a separator.
KEG="$PREFIX/Cellar/foo/1.0"
SIBLING="$PREFIX/Cellar/foo/1.0_1"
mkdir -p "$KEG/bin" "$SIBLING/bin"
printf '#!/bin/sh\n' >"$KEG/bin/foo"
printf '#!/bin/sh\n' >"$KEG/bin/plain"
printf '#!/bin/sh\n' >"$SIBLING/bin/foo"

sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) \
   VALUES('foo','foo','1.0','sha','$KEG');"

ln -s "$SIBLING/bin/foo" "$PREFIX/bin/foo" # live link into the sibling version
printf 'USER DATA\n' >"$PREFIX/bin/plain"  # non-malt regular file in a leaf slot

OUT="$(dirname "$PREFIX")/out"
if "$BIN" link foo >"$OUT" 2>&1; then
  fail "malt link exited 0 with two conflicting leaves in place"
fi
pass "malt link refused"

grep -q 'Cellar/foo/1.0_1' "$OUT" ||
  fail "sibling-version symlink not reported as a conflict"
pass "sibling-version symlink reported"
grep -q 'bin/plain' "$OUT" ||
  fail "regular file in leaf slot not reported as a conflict"
pass "regular file in leaf slot reported"

[[ "$(readlink "$PREFIX/bin/foo")" == "$SIBLING/bin/foo" ]] ||
  fail "sibling-version symlink was retargeted"
pass "sibling-version symlink untouched"
[[ ! -L "$PREFIX/bin/plain" && "$(cat "$PREFIX/bin/plain")" == "USER DATA" ]] ||
  fail "regular file was clobbered"
pass "regular file untouched"

[[ -z "$(sqlite3 "$DB" 'SELECT 1 FROM links LIMIT 1;')" ]] ||
  fail "links rows written despite refused pre-check"
pass "no links rows written"

printf '\n✔ conflict pre-check boundary and plain-file regression passed\n'
