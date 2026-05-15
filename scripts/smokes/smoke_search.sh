#!/usr/bin/env bash
# Smoke test for `malt search`.
#
# Verifies the substring-search command returns brew-parity results for
# a known-populated query ("go"), that the exact match is present, and
# that --json / nonexistent-query paths behave. Also covers the new
# --installed and MALT_OFFLINE scopes, which never touch the network.
# Hits the live Homebrew API for the default path; safe to run locally
# (no install side effects).
#
# Usage: scripts/smokes/smoke_search.sh
# Requirements: built `malt` binary in zig-out/bin or $MALT_BIN.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# Minimum result count for `go` — brew returns >300; we set the floor
# well below that so the test isn't fragile to daily index drift.
MIN_HITS=100

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

printf '▸ human output: mt search go\n'
out=$("$BIN" search go)
hits=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
((hits >= MIN_HITS)) || fail "expected ≥$MIN_HITS rows, got $hits"
pass "$hits rows returned"

printf '%s\n' "$out" | grep -q '^  ▸ go (formula)$' ||
  fail "exact match 'go (formula)' missing from output"
pass "exact formula match present"

printf '%s\n' "$out" | grep -q '(cask)$' ||
  fail "no cask results — expected at least one"
pass "cask results present"

printf '\n▸ json output: mt --json search wget\n'
json=$("$BIN" --json search wget)
printf '%s\n' "$json" | grep -q '"formulae":\[{"name":"wget"}' ||
  fail "JSON missing wget formula entry"
pass "JSON shape ok ($json)"

printf '\n▸ empty result: mt search xyz-no-such-pkg-abc-123\n'
miss=$("$BIN" search xyz-no-such-pkg-abc-123 2>&1 || true)
printf '%s\n' "$miss" | grep -q 'No results found' ||
  fail "missing 'No results found' line for empty query"
pass "empty-query message shown"

# --installed is offline by contract; a query for an unlikely-to-be-installed
# name must exit cleanly with "No results found" without making any network
# request.
printf '\n▸ installed scope: mt search --installed zzz-no-such-keg\n'
inst=$("$BIN" search --installed zzz-no-such-keg 2>&1 || true)
printf '%s\n' "$inst" | grep -q 'No results found' ||
  fail "--installed missing 'No results found' line"
pass "--installed empty-query message shown"

# MALT_OFFLINE mirrors --installed; identical behaviour on a clean miss.
printf '\n▸ offline env: MALT_OFFLINE=1 mt search zzz-no-such-keg\n'
off=$(MALT_OFFLINE=1 "$BIN" search zzz-no-such-keg 2>&1 || true)
printf '%s\n' "$off" | grep -q 'No results found' ||
  fail "MALT_OFFLINE=1 missing 'No results found' line"
pass "MALT_OFFLINE=1 empty-query message shown"

printf '\n✓ all smoke checks passed\n'
