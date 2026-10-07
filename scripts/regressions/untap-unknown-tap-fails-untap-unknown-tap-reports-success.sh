#!/usr/bin/env bash
# Regression: `mt untap` on a slug that is not registered must fail. The
# DELETE matched zero rows and still reported "Untapped" with exit 0, so a
# typo looked like a removal while the real tap stayed registered.
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

tmp=$(mktemp -d /tmp/mt_untap_unknown.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1
export MALT_PREFIX="$tmp/prefix" MALT_CACHE="$tmp/cache"
mkdir -p "$MALT_PREFIX/db" "$MALT_PREFIX/tmp" "$MALT_CACHE"
db="$MALT_PREFIX/db/malt.db"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# With db/ already in place, a bare listing creates the schema offline.
"$BIN" --offline tap >/dev/null 2>&1
sqlite3 "$db" "INSERT INTO taps(name,url,github_owner,github_repo)
  VALUES('real/tap','https://github.com/real/homebrew-tap','real','homebrew-tap');"

if "$BIN" untap real/tpa >"$tmp/out" 2>&1; then
  fail "untap of an unknown slug exited 0: $(cat "$tmp/out")"
fi
grep -q 'No available tap' "$tmp/out" || fail "no 'No available tap' message: $(cat "$tmp/out")"
[[ $(sqlite3 "$db" "SELECT count(*) FROM taps WHERE name='real/tap'") == 1 ]] ||
  fail "untap of a typo removed the real tap"

if "$BIN" --dry-run untap nosuch/tap >/dev/null 2>&1; then
  fail "dry-run untap of an unknown slug exited 0"
fi

"$BIN" untap real/tap >/dev/null 2>&1 || fail "untap of a registered tap failed"
if "$BIN" untap real/tap >/dev/null 2>&1; then
  fail "second untap of the same tap exited 0"
fi

echo "ok: untap refuses a tap that is not registered"
