#!/usr/bin/env bash
# Regression: `mt --dry-run update` previews the cache wipe and keeps the
# API cache. Pre-fix the global --dry-run flag was never consulted, so the
# preview wiped it, along with the outdated snapshot, and exited 0.
#
# Control: a real `mt update` of the same fixture clears the cache, so the
# survival above is not vacuous.
#
# Usage: scripts/regressions/update-dry-run-keeps-cache-dry-run-update-wipes-the-api-cache.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mt() {
  env -u MALT_PREFIX -u MALT_CACHE NO_COLOR=1 MALT_PREFIX="$T/p" MALT_CACHE="$T/cache" \
    "$BIN" --offline "$@" </dev/null 2>&1
}

mkdir -p "$T/cache/api"
printf '{"name":"alpha"}' >"$T/cache/api/formula_alpha.json"

out=$(mt --dry-run update) || fail "mt --dry-run update failed:"$'\n'"$out"
grep -q "would clear" <<<"$out" || fail "the preview did not say what it would clear:"$'\n'"$out"
[[ -f "$T/cache/api/formula_alpha.json" ]] || fail "mt --dry-run update wiped the API cache"

out=$(mt update) || fail "mt update failed:"$'\n'"$out"
[[ ! -e "$T/cache/api/formula_alpha.json" ]] || fail "control: mt update did not clear the API cache"

echo "PASS: mt --dry-run update keeps the API cache"
