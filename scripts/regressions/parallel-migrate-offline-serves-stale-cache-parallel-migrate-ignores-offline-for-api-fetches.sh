#!/usr/bin/env bash
# Regression: `mt migrate --parallel` offline serves a stale API cache entry
# the same way the serial path does. Pre-fix the worker's API client ignored
# offline mode, missed the fresh-only cache and dialed an offline HTTP client,
# so every keg with a cache entry older than the TTL landed in `failed`.
#
# Hermetic: `MALT_OFFLINE=1` refuses any dial before it happens. The cached
# formula has no bottle, so a served entry stops at `skipped_no_bottle`.
#
# Usage: scripts/regressions/parallel-migrate-offline-serves-stale-cache-parallel-migrate-ignores-offline-for-api-fetches.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

WORK=$(mktemp -d)
PREFIX="$WORK/prefix"
trap 'rm -rf "$WORK"' EXIT
unset MALT_CACHE MALT_API_DOMAIN MALT_BOTTLE_DOMAIN
export HOMEBREW_PREFIX="$WORK/brew"
export MALT_PREFIX="$PREFIX"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$HOMEBREW_PREFIX/Cellar/regfoo/1.0" "$PREFIX/tmp" "$PREFIX/cache/api"
CACHED="$PREFIX/cache/api/formula_regfoo.json"
printf '%s' '{"name":"regfoo","full_name":"regfoo","tap":"homebrew/core","versions":{"stable":"1.0"}}' >"$CACHED"
# Older than the fresh-only TTL: only the offline branch may serve it.
touch -t 202001010000 "$CACHED"

for flag in "" --parallel; do
  mode=${flag:-serial}
  OUT=$("$BIN" migrate ${flag:+"$flag"} --json 2>&1 || true)
  if grep -q 'Homebrew API fetch failed' <<<"$OUT"; then
    fail "$mode migrate offline ignored the stale API cache entry; got: $OUT"
  fi
  grep -q '"skipped_no_bottle":\["regfoo"\]' <<<"$OUT" ||
    fail "$mode migrate did not reach the no-bottle outcome; got: $OUT"
  pass "$mode migrate offline serves the stale API cache entry"
done

echo "parallel migrate honours offline for API fetches: OK"
