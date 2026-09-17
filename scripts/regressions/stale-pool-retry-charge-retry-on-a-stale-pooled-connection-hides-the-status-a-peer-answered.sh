#!/usr/bin/env bash
# Regression: a transient status on a keep-alive response must not leave a
# dead socket in the pool for the next retry attempt to trip over.
#
# The bug: after a 5xx / 429 without `Connection: close` the connection went
# back to the pool, and the retry was spent reading EOF from a peer that had
# dropped it - charged against the backoff budget as if the peer had been
# dialled. With the default budget the last attempt was the stale one, so the
# status the peer answered with surfaced as a transport error.
#
# The fix retires the connection once the status is known to be transient, so
# every retry dials afresh; a healthy keep-alive response still pools.
#
# The answer-then-drop peer is a loopback fixture inside the colocated inline
# unit tests (`lib_tests`). This script builds and runs only that binary: no
# network, about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"
TEST_NAME="transient status retires the connection so every retry dials"

# If the guarding test is ever dropped, the unit binary would go green
# vacuously. Fail loudly instead.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the retry-dials test is missing from $SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source — a prebuilt lib_tests
# could predate the fix. Zig's cache makes a no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: a retry attempt was spent on a stale pooled connection" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: every retry attempt after a transient status reaches the peer"
