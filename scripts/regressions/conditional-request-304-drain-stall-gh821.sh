#!/usr/bin/env bash
# Pin that a conditional request answered 304 returns immediately.
#
# Re-resolving a tap sends If-None-Match and normally gets 304 Not Modified.
# A 304 carries no body and no framing headers, which the HTTP release path
# read as "body ends when the peer closes" - so it blocked on a keep-alive
# socket until the idle timeout, roughly 30 s per request, and only then
# returned the (correct) cached commit. A warm `bundle install` therefore
# paid ~30 s per tap line while doing no useful work at all.
#
# Pinned behaviour: the second resolve of the same tap is fast. The failure
# mode is a fixed ~30 s stall per request, so the threshold sits far below
# one timeout and far above any plausible round trip.
#
# Needs the network. Set MALT_GITHUB_TOKEN to avoid the anonymous API cap.
#
# Usage: scripts/regressions/conditional-request-304-drain-stall-gh821.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s - run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# One timeout is ~30 s; a healthy conditional resolve is well under a second.
MAX_WARM_SECS=10
TAP=${TAP:-keith/formulae}

PFX=$(mktemp -d -t mt_cond304.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
export MALT_PREFIX="$PFX" NO_COLOR=1

# `tap` is a no-op against a prefix with no database, so bring one into
# existence first: an unresolvable name creates it and then fails.
"$MALT_BIN" install --quiet nope-not-real >/dev/null 2>&1 || true
[[ -f "$PFX/db/malt.db" ]] || fail 'could not bootstrap the fixture database'

# Cold resolve: no cached etag yet, so this one gets a 200 and stores the
# validator the warm run below sends back.
"$MALT_BIN" tap "$TAP" >"$PFX/cold.log" 2>&1 ||
  fail "could not resolve $TAP - see $PFX/cold.log"
grep -q 'Tapped' "$PFX/cold.log" || fail "cold resolve did not register the tap"

etag=$(sqlite3 "$PFX/db/malt.db" "SELECT COALESCE(head_etag,'') FROM taps WHERE name='$TAP';")
[[ -n "$etag" ]] ||
  fail 'no ETag stored, so the warm run would not send If-None-Match and would prove nothing'

start=$(date +%s)
"$MALT_BIN" tap "$TAP" >"$PFX/warm.log" 2>&1 ||
  fail "warm resolve of $TAP failed - see $PFX/warm.log"
elapsed=$(($(date +%s) - start))

grep -q 'Tapped' "$PFX/warm.log" || fail "warm resolve did not register the tap"
((elapsed < MAX_WARM_SECS)) ||
  fail "warm conditional resolve took ${elapsed}s (limit ${MAX_WARM_SECS}s) - the 304 stalled until timeout"

printf 'PASS: a 304 conditional resolve returned in %ss\n' "$elapsed"
