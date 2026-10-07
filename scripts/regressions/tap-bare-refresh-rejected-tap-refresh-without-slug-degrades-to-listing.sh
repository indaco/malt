#!/usr/bin/env bash
# Regression: a bare `mt tap --refresh` (or `--refresh=`) with no slug and no
# `--all` asks for a mutation, so it must fail. Once the empty target collapsed
# to null, the argv looked like a bare `mt tap`, so the command printed the tap
# list and exited 0 having refreshed nothing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network; all state lives under a throwaway prefix.

set -euo pipefail

unset MALT_OFFLINE MALT_CACHE MALT_API_DOMAIN MALT_BOTTLE_DOMAIN

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# `zig build test` does not refresh the binary; a stale one would mask the fix.
[[ -n "${MALT_BIN:-}" ]] || zig build >/dev/null

tmp=$(mktemp -d /tmp/mt_bare_refresh.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1
export MALT_PREFIX="$tmp/prefix" MALT_CACHE="$tmp/cache"
mkdir -p "$MALT_PREFIX"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

for flag in --refresh --refresh=; do
  if "$BIN" tap "$flag" >"$tmp/out" 2>&1; then
    fail "mt tap $flag exited 0 having refreshed nothing"
  fi
  grep -q -- '--all' "$tmp/out" || fail "mt tap $flag: no --refresh usage hint"
  if grep -q 'No taps registered' "$tmp/out"; then
    fail "mt tap $flag degraded to a tap listing"
  fi
done

echo "ok: a bare --refresh is rejected instead of listing taps"
