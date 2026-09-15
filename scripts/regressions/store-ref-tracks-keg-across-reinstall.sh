#!/usr/bin/env bash
# Regression guard for the store refcount losing track of a live keg.
#
# The install path used to claim a store ref only when the bottle download
# was cold, so materializing from a warm store wrote a `kegs` row without
# taking one. After install -> uninstall -> install of the same version the
# entry sat at refcount 0 while a live keg held the bytes, and the orphan
# sweep reclaimed them.
#
# The offline sibling (store-refcount-moment-does-not-match-a-reference.sh)
# pins the sweep half against seeded DB state. This one drives the real
# install path end to end, so it is the guard that fails if the ref is ever
# claimed on the download again instead of on the keg.
#
# Usage: scripts/regressions/store-ref-tracks-keg-across-reinstall.sh
# Requirements: built `malt` binary, network access to formulae.brew.sh +
# ghcr.io, sqlite3.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PKG=tree

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

db() { sqlite3 "$PREFIX/db/malt.db" "$1"; }

# "row" when the store entry is claimed, "none" when no row exists.
claim() {
  local v
  v=$(db "SELECT 'row' FROM store_refs WHERE store_sha256 = '$1';")
  printf '%s' "${v:-none}"
}

"$BIN" install "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "cold install of $PKG failed"

SHA=$(db "SELECT store_sha256 FROM kegs WHERE name = '$PKG';")
[[ -n "$SHA" ]] || fail 'cold install recorded no keg'
[[ "$(claim "$SHA")" == row ]] ||
  fail "cold install left no store_refs row"
pass "cold install claims the bytes"

"$BIN" uninstall "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "uninstall of $PKG failed"
[[ "$(claim "$SHA")" == row ]] ||
  fail "uninstall dropped the store_refs row; the orphan sweep can no longer see the bytes"
[[ -d "$PREFIX/store/$SHA" ]] ||
  fail 'uninstall removed the store entry; the warm-reinstall path is gone'
pass 'uninstall releases the bytes but keeps them warm'

# The bug: this install materializes from the warm store, so the old
# download-gated claim never fired.
"$BIN" install "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "warm reinstall of $PKG failed"
[[ "$(claim "$SHA")" == row ]] ||
  fail "warm reinstall left no store_refs row"
pass 'warm reinstall keeps the bytes claimed for the new keg'

"$BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
[[ -d "$PREFIX/store/$SHA" ]] ||
  fail 'the orphan sweep reclaimed bytes a live keg holds'
pass 'the orphan sweep leaves a referenced entry alone'

# --force replaces the keg row rather than adding one; the claim must
# still be there and the sweep must still leave the entry alone.
"$BIN" install --force "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "forced reinstall of $PKG failed"
[[ "$(claim "$SHA")" == row ]] ||
  fail "forced reinstall left no store_refs row"
"$BIN" purge --store-orphans --dry-run </dev/null 2>&1 | grep -q "$SHA" &&
  fail 'the orphan sweep lists an entry a forced reinstall still holds'
pass 'a forced reinstall keeps the entry claimed'

printf 'PASS: the store ref tracks the keg across the reinstall lifecycle\n'
