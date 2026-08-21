#!/usr/bin/env bash
# Regression: a Ctrl-C during a bottle download must end the retry loop, not
# be re-dialled and reported as a network failure.
#
# The bug: downloadBottleToStore's three-attempt loop had no cancellation
# input at all. Its only stop signal was a backoff helper reading cancellation
# off std.Io.sleep - a channel nothing in the process ever arms - while the
# real interrupt state lives in the signals module the same file already
# imports. A Ctrl-C mid-download therefore burned all three attempts, slept
# both backoffs, and ended with a per-formula "DownloadFailed (after 3
# attempts)" line before the install loop finally reported the interruption.
#
# The fix polls the interrupt flag once per attempt and breaks, which also
# skips the attempts-exhausted line, so the interruption is reported once by
# the caller.
#
# The CLI cannot reach this path offline: MALT_BOTTLE_DOMAIN is https-only, so
# no cleartext loopback registry is reachable from the binary, and driving real
# GHCR would need network plus a race-prone signal. The contract is pinned by
# the integration test instead; this script builds and runs only that binary.
# Hermetic, no network, well under 30s - the test owns and cleans its own temp
# prefix, so nothing is left behind here.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/cli/install/download.zig"
TEST="tests/install_download_cancel_test.zig"

# A dropped guard or a dropped test would let the binary go green vacuously.
# Fail loudly instead: both must still be present.
if ! grep -Fqs -- "signals.isInterrupted()" "$SRC"; then
  echo "FAIL: the interrupt poll is missing from the bottle retry loop" >&2
  exit 1
fi
if ! grep -Fqs -- "setInterruptedForTest" "$TEST"; then
  echo "FAIL: the download cancellation integration test is missing" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/install_download_cancel_test"
# Always rebuild so the binary reflects current source; zig's cache keeps a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: a set interrupt flag did not stop the bottle retry loop after one attempt" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|expected|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: a Ctrl-C during a bottle download stops the retry loop at one attempt"
