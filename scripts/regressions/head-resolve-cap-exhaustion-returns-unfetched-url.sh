#!/usr/bin/env bash
# Regression: the manual HEAD redirect loop must fail when it runs out of hops.
#
# When the last response inside the cap was still a redirect, the loop swapped
# `final_url` to the next hop and fell out, returning that URL as resolved -
# nothing had ever requested it. Falling out and breaking out converged on the
# same `return resolved`, so cap exhaustion was indistinguishable from a
# terminal response. The walk now takes every hop from a shared decision that
# errors on exhaustion, before there is a url to adopt. The cask installer then classified the artifact type from that
# URL and could raise a `sudo installer -target /` prompt on the strength of
# a URL malt never contacted. Both GET loops already error out here.
#
# The fixture test is the honest gate. The source precondition guards the walk
# from resolving its own hops again.
#
# No network, no temp state, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

if ! grep -Eqs -- "nextRedirectHop\(uri, status, response\.head\.location, hops\)\) orelse break" "$SRC"; then
  echo "FAIL: the HEAD loop still returns an un-fetched url when it runs out of hops" >&2
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
  echo "FAIL: net_redirect_auth_test - an exhausted redirect walk was reported as resolved" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: an exhausted HEAD redirect walk is reported as an error"
