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

# refcount for the one store entry, or "none" when no row exists.
refcount() {
  local v
  v=$(db "SELECT refcount FROM store_refs WHERE store_sha256 = '$1';")
  printf '%s' "${v:-none}"
}

"$BIN" install "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "cold install of $PKG failed"

SHA=$(db "SELECT store_sha256 FROM kegs WHERE name = '$PKG';")
[[ -n "$SHA" ]] || fail 'cold install recorded no keg'
[[ "$(refcount "$SHA")" == 1 ]] ||
  fail "cold install left refcount $(refcount "$SHA"), want 1"
pass "cold install claims the bytes"

"$BIN" uninstall "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "uninstall of $PKG failed"
[[ "$(refcount "$SHA")" == 0 ]] ||
  fail "uninstall left refcount $(refcount "$SHA"), want 0"
[[ -d "$PREFIX/store/$SHA" ]] ||
  fail 'uninstall removed the store entry; the warm-reinstall path is gone'
pass 'uninstall releases the bytes but keeps them warm'

# The bug: this install materializes from the warm store, so the old
# download-gated bump never fired and the entry stayed at 0.
"$BIN" install "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "warm reinstall of $PKG failed"
[[ "$(refcount "$SHA")" == 1 ]] ||
  fail "warm reinstall left refcount $(refcount "$SHA"), want 1"
pass 'warm reinstall re-claims the bytes for the new keg'

"$BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
[[ -d "$PREFIX/store/$SHA" ]] ||
  fail 'the orphan sweep reclaimed bytes a live keg holds'
pass 'the orphan sweep leaves a referenced entry alone'

# The opposite drift: --force replaces the keg row rather than adding one,
# so a plain increment here would climb past the single keg that exists.
"$BIN" install --force "$PKG" </dev/null >/dev/null 2>&1 ||
  fail "forced reinstall of $PKG failed"
[[ "$(refcount "$SHA")" == 1 ]] ||
  fail "forced reinstall left refcount $(refcount "$SHA"), want 1"
pass 'a forced reinstall does not inflate the count'

printf 'PASS: the store ref tracks the keg across the reinstall lifecycle\n'
