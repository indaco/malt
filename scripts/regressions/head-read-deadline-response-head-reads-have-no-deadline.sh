#!/usr/bin/env bash
# Regression: the request/head phase of an HTTP walk must run under a deadline.
#
# The bug: the per-request timeout was only ever threaded into the body read,
# and the watchdog that enforces it - deadline plus the Ctrl-C predicate - was
# spawned inside `streamResponseBody`. Everything before the body ran with
# whatever the OS gave it, so an origin that completed TCP and TLS and then
# never sent a response head parked the walk forever, and nothing sampled the
# cancel flag during that window. On a cask install the stall happens after
# `db/malt.lock` is taken, blocking every other invocation.
#
# The fix runs the send+head pair under that same watchdog, one budget per hop,
# and reports a read the watchdog cut short as the peer's answer rather than a
# blip to sleep off.
#
# The assertion is behavioural and wall-clock-bound, and `MALT_API_DOMAIN` is
# https-only so the real binary cannot be pointed at a cleartext loopback stall
# server. It is judged through the integration test binary instead: loopback
# only, no network, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"
TESTS="tests/net_redirect_auth_test.zig"
BIN="$ROOT/zig-out/test-bin/net_redirect_auth_test"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# A dropped guard or a dropped fixture would let the binary go green vacuously.
grep -Fqs -- "head_timeout_ns" "$SRC" || fail "the head-phase deadline is gone"
grep -Fqs -- "receiveHeadDeadlined" "$SRC" || fail "the deadlined head helper is gone"
grep -Fqs -- "stall: bool" "$TESTS" || fail "the stalling-hop fixture is gone"

# Every head read must go through the helper; a raw one is the pre-fix shape.
if [[ "$(grep -Fc -- "req.receiveHead(&redirect_buf)" "$SRC")" -ne 0 ]]; then
  fail "a head read still runs with no deadline"
fi

# Always rebuild: a prebuilt binary could predate the fix, and zig 0.16 has no
# --test-filter to narrow this down.
zig build test-bin >/dev/null 2>&1 || fail "could not build the test binaries"

OUT=$(mktemp -t head-deadline)
trap 'rm -f "$OUT"' EXIT

start=$(date +%s)
timeout 25 "$BIN" >"$OUT" 2>&1 || fail "a silent origin was not cut off: $(tail -3 "$OUT")"
elapsed=$(($(date +%s) - start))

((elapsed < 20)) || fail "the head phase took ${elapsed}s - the deadline did not fire"

echo "PASS: a silent origin cannot park the request phase"
