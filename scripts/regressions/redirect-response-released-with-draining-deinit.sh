#!/usr/bin/env bash
# Regression: a redirect hop must be released without draining its body.
#
# The bug: a 3xx body is never read, and the stdlib release path drains an
# unread body. Absent `Content-Length` and a transfer encoding the body is
# close-delimited, so that drain ends only when the peer closes - and no
# watchdog runs across a redirect hop. A peer answering `302` plus `Location`
# with no framing headers, on a socket it holds open, parked the walk there.
#
# `finishBodiless` already existed for the 1xx/204/304 case; the fix routes an
# unframed redirect through it too, and retires the connection rather than
# pooling bytes nobody read.
#
# The assertion is behavioural and wall-clock-bound: the fixture holds the
# socket open long enough that a draining release is unmistakable, and closes
# it afterwards so a regression fails cleanly instead of hanging. Loopback
# only, no network.

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
grep -Fqs -- "finishRedirect" "$SRC" || fail "the redirect release helper is gone"
grep -Fqs -- "UnframedRedirectPeer" "$TESTS" || fail "the unframed-redirect fixture is gone"

# Both walks must release a committed hop through the helper; a bare release is
# the pre-fix shape.
if [[ "$(grep -Fc -- "finishRedirect(&req, &response.head)" "$SRC")" -ne 2 ]]; then
  fail "a redirect hop is still released with a draining deinit"
fi

# `zig build test-bin` does not prune, so a binary left by an earlier build
# still runs after its file is dropped from the build. Pin the registration.
grep -Fqs -- "tests/net_redirect_auth_test.zig" build.zig || fail "the test file is no longer built"

# Always rebuild: a prebuilt binary could predate the fix, and zig 0.16 has no
# --test-filter to narrow this down.
zig build test-bin >/dev/null 2>&1 || fail "could not build the test binaries"

OUT=$(mktemp -t redirect-drain)
trap 'rm -f "$OUT"' EXIT

timeout 60 "$BIN" >"$OUT" 2>&1 || fail "an unframed redirect was not released: $(tail -3 "$OUT")"

grep -Fqs -- "released without draining until the peer closes...OK" "$OUT" || fail "the redirect-release tests did not run"
grep -Fqs -- "released on the way out, not drained...OK" "$OUT" || fail "the redirect-release tests did not run"

echo "PASS: an unframed redirect is released without draining until close"
