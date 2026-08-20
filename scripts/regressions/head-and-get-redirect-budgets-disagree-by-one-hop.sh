#!/usr/bin/env bash
# Regression: the HEAD walk must not resolve a chain the download cannot follow.
#
# The two redirect loops carried independent budgets written in different
# units: the download's cap counted redirects (3), the HEAD walk's counted
# requests (5, i.e. 4 redirects). A cask URL sitting behind exactly 4
# redirects therefore classified successfully - possibly as `.pkg`, raising
# the system-wide `sudo installer -target /` prompt - and then always failed
# at download.
#
# There is now one budget and one place that enforces it, reached by all three
# walks through a shared hop decision. The fixture tests are the honest gate:
# they express every chain length in terms of that budget. The source
# preconditions guard the HEAD walk from growing a second one.
#
# No network, no temp state, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

if grep -Eqs -- "max_head_(requests|redirects)" "$SRC"; then
  echo "FAIL: the HEAD walk carries a redirect budget of its own again" >&2
  exit 1
fi

guards=$(grep -Ec -- "hops >= max_redirects" "$SRC")
if [[ "$guards" -ne 1 ]]; then
  echo "FAIL: the redirect budget is enforced in $guards places, not one" >&2
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
  echo "FAIL: net_redirect_auth_test - the HEAD walk and the download disagree on redirect depth" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: the HEAD walk resolves exactly the chains the download can follow"
