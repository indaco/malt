#!/usr/bin/env bash
# Regression: an extensionless cask URL must classify through a redirect the
# origin only emits on GET.
#
# The classification walk sent HEAD and nothing else. A download endpoint that
# answers HEAD with a plain 200 page and only redirects a GET to the real file
# therefore terminated on the origin, the type resolved to `unknown`, and the
# install was refused as an unsupported format. The walk now retries with GET
# when HEAD came back with nothing usable, releasing every hop without draining
# its body - the terminal hop of such a walk is the artifact itself.
#
# The fixture tests are the honest gate: a method-discriminating loopback hop
# and an oversize terminal body. The source preconditions guard against the
# fallback being dropped, its errors swallowed, or its release drifting back
# to a body-draining deinit.
#
# No network, no temp state, well under 30s once the test binaries are cached.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"
CLI="src/cli/install.zig"
T="tests/net_redirect_auth_test.zig"

grep -Fqs -- 'pub fn getResolved' "$SRC" || {
  echo "FAIL: GET classification walk missing from $SRC" >&2
  exit 1
}
grep -Fqs -- 'getResolved(' "$CLI" || {
  echo "FAIL: cask classification never falls back to GET in $CLI" >&2
  exit 1
}
grep -Fqs -- 'getResolved follows a redirect the origin only emits on GET' "$T" || {
  echo "FAIL: method-discriminating fixture test missing from $T" >&2
  exit 1
}
grep -Fqs -- 'getResolved closes the terminal hop without reading its body' "$T" || {
  echo "FAIL: no-drain fixture test missing from $T" >&2
  exit 1
}

# A plain deinit on the walk's request drains a GET body: the whole artifact.
if awk '/fn resolveOnce\(/,/^    }$/' "$SRC" | grep -Fqs -- 'req.deinit()'; then
  echo "FAIL: the classification walk still releases its request with a draining deinit" >&2
  exit 1
fi
# The swallowed-error shape must not come back with the fallback.
if grep -Fqs -- 'getResolved(url) catch return .unknown' "$CLI"; then
  echo "FAIL: GET walk errors are swallowed instead of reported" >&2
  exit 1
fi

# Always rebuild so the binaries reflect current source. Zig's cache makes a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/net_redirect_auth_test"
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: net_redirect_auth_test - a GET-only redirect is not resolved, or the GET walk drains a body" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: extensionless cask URLs resolve through a GET-only redirect without pulling a body"
