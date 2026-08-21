#!/usr/bin/env bash
# Regression: a redirect walk must retry a transient fault and must not retry a
# deterministic one - on the classification walk and on the download alike.
#
# The HEAD walk that picks a cask's artifact type had no retry wrapper at all,
# so one reset connection during classification was a hard install failure even
# though the download that follows would have retried the identical hop three
# times. The download's wrapper had the opposite defect: it retried any error,
# so a chain that had already tripped the hop budget was re-walked twice more
# before surfacing the same, inevitable error.
#
# Both halves are behavioural, so this reruns the fixture binary rather than
# grepping the source: a precondition would pin the shape of the fix, not the
# property. Those tests already gate CI through `zig build test`; this script is
# the correlatable rerun. Runtime doubles as evidence - a suite that spends the
# backoff table on a deterministic failure takes seconds longer than one that
# does not.
#
# No network beyond loopback, no temp state, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# Always rebuild so the binaries reflect current source. Zig's cache makes a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/net_redirect_auth_test"
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: net_redirect_auth_test - a redirect walk retries the wrong class of failure" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: transient faults are retried on both walks, deterministic ones on neither"
