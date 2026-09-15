#!/usr/bin/env bash
# Regression: `mt upgrade` resolves the outdated snapshot at the same cache dir
# `mt outdated` reads from, so `MALT_CACHE` is honoured on both sides.
#
# `mt outdated` (and the TUI) read `$MALT_CACHE/outdated.json` when the
# override is set. Pre-fix, `mt upgrade` hard-coded `{prefix}/cache`, so with
# `MALT_CACHE` pointing elsewhere its dry-run warm and its post-upgrade prune
# both targeted a file nobody reads: the warm was invisible to `mt outdated`,
# and the prune left a just-upgraded keg listed as outdated until the TTL.
#
# Hermetic: the fake upstream is a cached `formula_<name>.json` under the API
# cache dir, and `MALT_OFFLINE=1` refuses any fallback to the network. Only a
# `mt upgrade` that looks in `$MALT_CACHE/api` can see the cached formula and
# report a would-upgrade at all, so the assertion exercises the one cache-dir
# resolution that warm and prune share.
#
# Usage: scripts/regressions/upgrade-honours-malt-cache-for-outdated-snapshot.sh
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

PREFIX="/tmp/mt_up_cache_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/altcache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OUTDATED_MAX_AGE CI

DB="$PREFIX/db/malt.db"
SNAP="$MALT_CACHE/outdated.json"
WRONG_SNAP="$PREFIX/cache/outdated.json"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# One keg a version behind a cached formula document: the only would-upgrade
# a fully offline dry-run can find, and only if it looks under $MALT_CACHE.
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
  VALUES ('regfoo', 'regfoo', '1.0', 0, 'seedsha', '/tmp/c/regfoo/1.0');"
printf '{"name":"regfoo","versions":{"stable":"2.0"},"revision":0}' >"$MALT_CACHE/api/formula_regfoo.json"

OUT=$("$BIN" upgrade --dry-run 2>&1 || true)
echo "$OUT" | grep -q "would upgrade regfoo 1.0 -> 2.0" ||
  fail "dry-run did not see the formula cached under MALT_CACHE; got: $OUT"
pass "upgrade reads the API cache under MALT_CACHE"

[[ -f "$SNAP" ]] || fail "dry-run warmed no snapshot under MALT_CACHE — the file mt outdated reads"
[[ ! -e "$WRONG_SNAP" ]] || fail "dry-run wrote {prefix}/cache/outdated.json, which nothing reads when MALT_CACHE is set"
pass "snapshot lands under MALT_CACHE, not {prefix}/cache"

JSON=$("$BIN" outdated --json 2>/dev/null || true)
echo "$JSON" | grep -q 'regfoo' ||
  fail "mt outdated --json did not serve the snapshot upgrade just warmed; got: $JSON"
pass "mt outdated serves what mt upgrade wrote"

echo "upgrade honours MALT_CACHE for the outdated snapshot: OK"
