#!/usr/bin/env bash
# Regression: `mt outdated`'s live recompute warms the shared `outdated.json`
# snapshot from the entries it just audited, instead of re-auditing the full
# keg set a second time inside `refreshSnapshot`.
#
# The redundant second audit is only observable as extra network traffic (a
# duplicate tap-HEAD GET per tap), and the mirror layer is HTTPS-only with no
# local injection seam — so the *count* of audits cannot be asserted
# hermetically. What this pins hermetically is the observable contract the
# warm must preserve, with zero kegs => no API calls => no network:
#
#   1. Full recompute (no scope flags) writes the snapshot: a pre-seeded bogus
#      snapshot is overwritten by the recompute's own (empty) result.
#   2. Narrowed recompute (`--pinned-only`) writes NO snapshot: warming from a
#      partial audit would make the next reader under-report, so the bogus
#      snapshot is left untouched.
#
# If the warm were dropped, (1) fails (bogus entry survives); if the
# full-keg-only gate were lost, (2) fails (bogus entry overwritten).
#
# Usage: scripts/regressions/outdated-recompute-warms-snapshot-not-reaudit.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_outdated_warm.XXXXXX)
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

# Zero kegs: `mt list` migrates the schema only when db/ exists.
mkdir -p "$PREFIX/db" "$MALT_CACHE"
"$BIN" list >/dev/null 2>&1 || true

# Seed a snapshot generated `$1` seconds ago carrying a bogus entry. With no
# kegs the entry never survives a recompute, so it is purely a marker for
# "was this snapshot overwritten by the recompute, or left alone?".
seed_snapshot() {
  local age_secs="$1" gen_ms
  gen_ms=$((($(date +%s) - age_secs) * 1000))
  printf '{"version":2,"generated_at_ms":%s,"formulas":[{"name":"alpha","installed":"1.0","latest":"9.9"}],"casks":[]}' \
    "$gen_ms" >"$SNAP"
}

# (1) Full recompute (stale snapshot => recompute) warms the snapshot from its
# own audit, overwriting the bogus marker.
seed_snapshot 600
"$BIN" outdated >/dev/null 2>&1 || true
if grep -q '9.9' "$SNAP"; then
  fail "full recompute did not warm the snapshot — the bogus marker survived (warm dropped)"
fi
pass "full recompute warms the snapshot (bogus marker overwritten)"

# (2) Narrowed recompute (--pinned-only forces a recompute) must NOT warm: a
# partial audit would persist a snapshot the next reader trusts as complete.
seed_snapshot 600
"$BIN" outdated --pinned-only >/dev/null 2>&1 || true
if ! grep -q '9.9' "$SNAP"; then
  fail "narrowed recompute overwrote the snapshot — a partial audit was persisted (gate lost)"
fi
pass "narrowed recompute leaves the snapshot untouched (no partial warm)"

printf '\n\xe2\x9c\x94 outdated recompute warm-not-reaudit regression passed\n'
