#!/usr/bin/env bash
# Regression: the `outdated.json` snapshot TTL is a *refresh* trigger, not just
# a warning threshold — and it is short enough (5 min default) that `mt outdated`
# tracks the same freshness as the always-live `mt upgrade`.
#
# The bug: `mt outdated` served any present snapshot for up to 24 h, only adding
# a stderr warning past the threshold. So an upgrade that landed after the
# snapshot was written stayed invisible to `mt outdated` (and the TUI Outdated
# tab, which consumes it) while `mt upgrade --dry-run` reported it live.
#
# Three behaviours pinned, all hermetic (no kegs => no API calls => no network):
#   1. Online + snapshot older than the TTL  -> recompute (snapshot overwritten).
#   2. Online + snapshot younger than the TTL -> served (window still exists; we
#      do not recompute on every call).
#   3. Offline + snapshot older than the TTL  -> served, NOT overwritten (a
#      complete cached read beats a recompute that would under-report offline).
#
# Pre-fix, (1) fails: a ~10 min-old snapshot was "fresh" under the 24 h TTL and
# was served, so the bogus entry survived.
#
# Usage: scripts/regressions/outdated_snapshot_ttl.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_outdated_ttl.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE NO_COLOR CI

SNAP="$MALT_CACHE/outdated.json"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Initialise the schema with zero kegs: `mt list` migrates only when db/ exists.
mkdir -p "$PREFIX/db" "$MALT_CACHE"
"$BIN" list >/dev/null 2>&1 || true

# Write a snapshot generated `$1` seconds ago carrying a bogus outdated entry.
# The entry never survives the live-DB filter (no kegs), so it is only ever a
# marker for "was this snapshot served or recomputed?".
seed_snapshot() {
  local age_secs="$1" gen_ms
  gen_ms=$((($(date +%s) - age_secs) * 1000))
  printf '{"version":1,"generated_at_ms":%s,"formulas":[{"name":"alpha","installed":"1.0","latest":"9.9"}],"casks":[]}' \
    "$gen_ms" >"$SNAP"
}

# (1) Online + stale (10 min > 5 min TTL) -> recompute overwrites the snapshot.
seed_snapshot 600
"$BIN" outdated >/dev/null 2>&1 || true
if grep -q '9.9' "$SNAP"; then
  fail "online stale snapshot was served, not recomputed — TTL acted as a warning only (the bug)"
fi
pass "online stale snapshot is recomputed (bogus entry gone)"

# (2) Online + fresh (1 min < 5 min TTL) -> snapshot served, left intact.
seed_snapshot 60
"$BIN" outdated >/dev/null 2>&1 || true
if ! grep -q '9.9' "$SNAP"; then
  fail "online fresh snapshot was recomputed — the cache window is gone (over-recompute)"
fi
pass "online fresh snapshot is served (cache window preserved)"

# (3) Offline + stale -> served and NOT overwritten (no under-reporting offline).
seed_snapshot 600
MALT_OFFLINE=1 "$BIN" outdated >/dev/null 2>&1 || true
if ! grep -q '9.9' "$SNAP"; then
  fail "offline stale snapshot was overwritten — would under-report when it cannot refresh"
fi
pass "offline stale snapshot is served and preserved"

printf '\n\xe2\x9c\x94 outdated snapshot TTL regression passed\n'
