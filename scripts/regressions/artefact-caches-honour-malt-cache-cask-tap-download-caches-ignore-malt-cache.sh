#!/usr/bin/env bash
# Regression: the cask artefact and tap archive caches live under
# `MALT_CACHE`, the directory `mt purge --cache` prunes and `mt doctor` sizes.
# Pre-fix `core/cask.zig` and `core/tap_cache.zig` composed them from
# `{prefix}/cache`, so with the override set doctor reported bytes the purge
# it pointed at could never reach and `--stale-casks` swept the wrong tree.
#
# Hermetic: seeded files stand in for the writers (which need network); the
# assertions only compare which directory each reader/sweeper resolves.
#
# Usage: scripts/regressions/artefact-caches-honour-malt-cache-cask-tap-download-caches-ignore-malt-cache.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="/tmp/mt_artefact_cache_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/alt"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

tap_bytes() {
  # doctor exits non-zero on an empty prefix; only the figure matters here.
  { "$BIN" doctor --json 2>/dev/null || true; } | grep -o '"tap_cache":{"bytes":[0-9]*' | grep -o '[0-9]*$'
}

mkdir -p "$PREFIX/db" "$PREFIX/cache/Cask" "$PREFIX/cache/Tap" "$MALT_CACHE/Cask" "$MALT_CACHE/Tap"
"$BIN" list >/dev/null 2>&1 || true

sha=$(printf 'ab%.0s' {1..32})
printf xx >"$MALT_CACHE/Tap/$sha.tar.gz"  # 2 B under the override
printf x >"$PREFIX/cache/Tap/$sha.tar.gz" # 1 B legacy, must be ignored
touch -t 202501010000 "$MALT_CACHE/Tap/$sha.tar.gz" "$PREFIX/cache/Tap/$sha.tar.gz"

bytes=$(tap_bytes)
[[ "$bytes" == 2 ]] || fail "doctor tap_cache.bytes=$bytes, want 2 (from \$MALT_CACHE/Tap)"
pass "doctor sizes the tap cache under MALT_CACHE"

: >"$MALT_CACHE/Cask/ghost.dmg"
: >"$PREFIX/cache/Cask/legacy.dmg"
"$BIN" purge --stale-casks --yes >/dev/null 2>&1 || true
[[ ! -e "$MALT_CACHE/Cask/ghost.dmg" ]] || fail "--stale-casks left \$MALT_CACHE/Cask/ghost.dmg"
# A pre-override leftover is adopted into the override first, then judged
# like any other entry: an orphan is gone from both locations.
[[ ! -e "$PREFIX/cache/Cask/legacy.dmg" && ! -e "$MALT_CACHE/Cask/legacy.dmg" ]] ||
  fail "--stale-casks did not adopt-and-sweep {prefix}/cache/Cask/legacy.dmg"
pass "--stale-casks sweeps the cask cache under MALT_CACHE"

"$BIN" purge --cache=0 --yes >/dev/null 2>&1 || true
[[ ! -e "$MALT_CACHE/Tap/$sha.tar.gz" ]] || fail "purge --cache left \$MALT_CACHE/Tap/$sha.tar.gz"
bytes=$(tap_bytes)
[[ "$bytes" == 0 ]] || fail "doctor still reports $bytes B after purge --cache"
pass "purge --cache reclaims what doctor reported"

echo "cask/tap artefact caches honour MALT_CACHE: OK"
