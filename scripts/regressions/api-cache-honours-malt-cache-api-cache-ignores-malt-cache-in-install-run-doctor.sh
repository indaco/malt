#!/usr/bin/env bash
# Regression: `mt install`, `mt run` and the doctor post-install probe resolve
# the API cache through `MALT_CACHE`, the directory `mt update` wipes. Pre-fix
# they hard-coded `{prefix}/cache`, so with the override set update could
# never refresh the formula document install resolves against.
#
# Hermetic: the formula documents live under `$MALT_CACHE/api` only and
# `MALT_OFFLINE=1` refuses any network fallback, so a command reaches its
# post-fetch branch (`No bottle available` / `1 with post_install`) only by
# reading there; a miss stops earlier.
#
# Usage: scripts/regressions/api-cache-honours-malt-cache-api-cache-ignores-malt-cache-in-install-run-doctor.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

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

PREFIX="/tmp/mt_api_cache_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/altcache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

DB="$PREFIX/db/malt.db"
WRONG_API="$PREFIX/cache/api"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Two formula documents cached under $MALT_CACHE only. `regfoo` is not
# installed, so install and run fetch it; its empty bottle map stops them at
# "No bottle available" after the fetch instead of exec'ing. `regbar` is an
# installed keg the doctor probe looks up.
printf '%s' '{"name":"regfoo","full_name":"regfoo","versions":{"stable":"2.0"},"revision":0,"dependencies":[],"bottle":{"stable":{"files":{}}}}' \
  >"$MALT_CACHE/api/formula_regfoo.json"
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
  VALUES ('regbar', 'regbar', '1.0', 0, 'seedsha', '/tmp/c/regbar/1.0');"
printf '%s' '{"name":"regbar","full_name":"regbar","versions":{"stable":"1.0"},"revision":0,"dependencies":[],"post_install_steps":[{"type":"mkdir_p","path":"var/regbar"}]}' \
  >"$MALT_CACHE/api/formula_regbar.json"

OUT=$("$BIN" install --dry-run regfoo 2>&1 || true)
echo "$OUT" | grep -q 'No bottle available for regfoo' ||
  fail "install read {prefix}/cache, not MALT_CACHE; got: $OUT"
pass "install resolves the formula cached under MALT_CACHE"

OUT=$("$BIN" run regfoo -- true 2>&1 || true)
echo "$OUT" | grep -q 'No bottle available for regfoo' ||
  fail "run read {prefix}/cache, not MALT_CACHE; got: $OUT"
pass "run resolves the formula cached under MALT_CACHE"

OUT=$("$BIN" doctor --post-install-status 2>&1 || true)
echo "$OUT" | grep -q '1 with post_install' ||
  fail "doctor probe read {prefix}/cache, not MALT_CACHE; got: $OUT"
pass "doctor probe resolves the formula cached under MALT_CACHE"

[[ ! -e "$WRONG_API" ]] || fail "a {prefix}/cache/api was created while MALT_CACHE is set"
pass "no {prefix}/cache/api created while MALT_CACHE is set"

"$BIN" update >/dev/null 2>&1 || true
OUT=$("$BIN" install --dry-run regfoo 2>&1 || true)
echo "$OUT" | grep -q 'not cached' ||
  fail "mt update did not clear the formula install resolves against; got: $OUT"
pass "mt update clears what install resolves against"

echo "install/run/doctor honour MALT_CACHE for the API cache: OK"
