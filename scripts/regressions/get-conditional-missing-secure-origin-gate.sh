#!/usr/bin/env bash
# Regression: a conditional GET must refuse a cleartext origin.
#
# The bug: every url entry point on `HttpClient` gated the caller-supplied URL
# with `requireSecureOrigin` except `getConditional`, which went straight from
# the offline check to the transport. The redirect loop below it already
# refuses an https-to-http hop, so the gap was strictly the initial scheme,
# and since `getConditional` exists to carry caller-supplied headers, that
# cleartext request could carry an `Authorization` header.
#
# The fix adds the guard and pins the entry-point list at comptime, so a
# seventh entry point cannot arrive ungated.
#
# Presenting a real https origin needs a TLS fixture, so the guard is judged
# through the colocated inline unit tests (`lib_tests`). This script builds and
# runs only that binary: no network, and no state beyond the zig cache.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

# The source-shape greps are the load-bearing half: drop the guard *and* its
# assertion and the unit binary goes green vacuously.
body=$(awk '/pub fn getConditional\(/,/^    }$/' "$SRC")
if ! grep -Fq -- 'requireSecureOrigin(url, .transport_only)' <<<"$body"; then
  echo "FAIL: getConditional has no secure-origin gate" >&2
  exit 1
fi
if ! grep -Fqs -- 'expectError(error.InsecureUrlScheme, http.getConditional(' "$SRC"; then
  echo "FAIL: the entry-point sweep no longer covers getConditional" >&2
  exit 1
fi
if ! grep -Fqs -- 'entry_points' "$SRC"; then
  echo "FAIL: the comptime entry-point roster is missing from $SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild - a prebuilt lib_tests could predate the fix.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: the unit suite is red - a cleartext origin may have reached a conditional GET" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: getConditional refuses a cleartext origin"
