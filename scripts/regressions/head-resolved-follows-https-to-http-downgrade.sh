#!/usr/bin/env bash
# Regression: the manual HEAD redirect loop must refuse a hop that drops from
# https to cleartext.
#
# The bug: `headResolved` checked the caller-supplied URL once with
# `requireSecureOrigin`, then followed `Location` for up to five hops with no
# further scheme inspection — while both GET loops already compared the hop's
# scheme against the origin's and returned `TlsDowngradeRefused`. An https cask
# URL that 301s to `http://` therefore issued a cleartext HEAD, and the
# `final_url` plus `Content-Disposition` harvested from that response are what
# pick the cask's artifact type — `.pkg` being the one that routes the install
# through `sudo installer -target /`.
#
# The fix routes all three loops through one `nextHopUrl` helper that resolves
# the location against the current base and refuses the downgrade in one place,
# so the rule cannot drift between them again.
#
# Presenting a real https origin needs a TLS fixture, so the guard is judged
# through the colocated inline unit tests (`lib_tests`). This script builds and
# runs only that binary: no network, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"
TEST_NAME="nextHopUrl refuses an https to http downgrade"

# If the guard or its test is ever dropped, the unit binary would go green
# vacuously. Fail loudly instead.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the downgrade-refusal test is missing from $SRC" >&2
  exit 1
fi
if ! grep -Fqs -- "nextHopUrl" "$SRC"; then
  echo "FAIL: the shared redirect-hop helper is missing from $SRC" >&2
  exit 1
fi

# Every loop must route its hop through the helper. Asserting the pre-fix shape
# is absent is the load-bearing half: a range-extraction check could run away
# and pass on a reverted body, and a gate that fails open is worse than none.
if grep -Fqs -- "replaceFinalUrl(loc)" "$SRC"; then
  echo "FAIL: headResolved still follows Location without a scheme check" >&2
  exit 1
fi
if [[ "$(grep -Fc -- "nextHopUrl(uri, loc)" "$SRC")" -ne 3 ]]; then
  echo "FAIL: not all three redirect loops resolve their hop through the helper" >&2
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
  echo "FAIL: an https to http redirect hop was accepted" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: redirect hops refuse an https to http downgrade"
