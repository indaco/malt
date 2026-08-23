#!/usr/bin/env bash
# Regression: the connect + TLS handshake phase of an HTTP walk must run under
# a deadline.
#
# The bug: `std.http.Client.request` resolves DNS, opens the TCP connection and
# runs the whole TLS handshake before it returns, and the head-phase watchdog
# kills a stall by shutting down `req.connection`'s socket - which does not
# exist yet during that window. A peer that completes the TCP accept and then
# never speaks TLS parked the calling thread forever, with nothing sampling the
# cancel flag, so Ctrl-C did not free it either. On a cask or bottle install the
# stall happens while `db/malt.lock` is held, wedging every other invocation.
#
# The fix races the connect against a cancel-polling deadline and reports a
# connect the deadline cut short as the peer's answer, sharing one budget per
# hop with the head read.
#
# The assertion is behavioural and wall-clock-bound, and `MALT_API_DOMAIN` is
# https-only so the real binary cannot be pointed at a loopback fixture. It is
# judged through the integration test binary instead: loopback only, no
# network, well under 30s.

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
grep -Fqs -- "requestDeadlined" "$SRC" || fail "the connect-phase deadline is gone"
grep -Fqs -- "tls_silent" "$TESTS" || fail "the silent-handshake fixture is gone"

# Every walk must open through the helper; a bare call is the pre-fix shape.
if [[ "$(grep -Fc -- "self.client.request(" "$SRC")" -ne 0 ]]; then
  fail "a walk still connects with no deadline"
fi

# `zig build test-bin` does not prune, so a binary left by an earlier build
# still runs after its file is dropped from the build. Pin the registration.
grep -Fqs -- "tests/net_redirect_auth_test.zig" build.zig || fail "the test file is no longer built"

# Always rebuild: a prebuilt binary could predate the fix, and zig 0.16 has no
# --test-filter to narrow this down.
zig build test-bin >/dev/null 2>&1 || fail "could not build the test binaries"

OUT=$(mktemp -t connect-deadline)
trap 'rm -f "$OUT"' EXIT

start=$(date +%s)
timeout 90 "$BIN" >"$OUT" 2>&1 || fail "a silent TLS peer was not cut off: $(tail -3 "$OUT")"
elapsed=$(($(date +%s) - start))

# Wide enough for a loaded CI box: the pre-fix shape parks forever, so the
# ceiling only has to separate "finished" from "never".
((elapsed < 75)) || fail "the connect phase took ${elapsed}s - the deadline did not fire"

grep -Fqs -- "never starts its TLS handshake...OK" "$OUT" || fail "the connect-deadline tests did not run"
grep -Fqs -- "stalled TLS handshake is the answer, not a blip to retry...OK" "$OUT" || fail "the connect-deadline tests did not run"

echo "PASS: a silent TLS peer cannot park the connect phase"
