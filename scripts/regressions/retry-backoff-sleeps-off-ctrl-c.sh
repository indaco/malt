#!/usr/bin/env bash
# Regression: a Ctrl-C arriving during an HTTP retry backoff must end the wait,
# not be slept off and followed by another re-dial.
#
# The bug: HttpClient.retrySleep - the one backoff shared by all four retry
# loops - read cancellation only off std.Io.sleep's error.Canceled. Nothing in
# this process ever arms that channel, while the live stop signal is the
# `cancel` predicate main wires to the interrupt flag. So a cancel landing
# during a backoff was ignored for the whole schedule (up to 1s + 2s + 4s) and
# the request was re-dialled anyway. The doc comment claimed the opposite,
# which is what let it survive.
#
# The fix polls `cancel` before the wait and between short slices of it, so the
# stop is honoured promptly. The error.Canceled return plumbing already existed
# at every call site; only the trigger was dead.
#
# Driven through the inline unit tests: retrySleep is private and the contract
# is about a predicate plus a clock, so no registry or network is needed. Grep
# guards first so a deleted poll cannot go green vacuously.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

# Both halves must survive: the predicate poll inside the backoff, and the
# sliced wait that lets a mid-backoff cancel be seen at all.
if ! grep -Fqs -- "backoff_poll_slice_ms" "$SRC"; then
  echo "FAIL: the retry backoff no longer waits in cancellable slices" >&2
  exit 1
fi
if ! grep -Fqs -- "retrySleep observes a cancel that arrives mid-backoff" "$SRC"; then
  echo "FAIL: the mid-backoff cancellation test is missing" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source; zig's cache keeps a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: a cancel during a retry backoff was slept off" >&2
  printf '%s\n' "$OUT" | grep -iE "FAIL \(|[0-9]+ failed|expected .* found|leaked" >&2 || true
  exit 1
fi

echo "PASS: a Ctrl-C during a retry backoff ends the wait instead of re-dialling"
