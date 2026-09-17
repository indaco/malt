#!/usr/bin/env bash
# Pin that a network command honours HTTPS_PROXY.
#
# The HTTP client never opted in to the stdlib's proxy support, so on a host
# whose only egress is an HTTP proxy every fetch dialled the origin directly
# and died on connect timeout.
#
# Pinned behaviour: with HTTPS_PROXY pointing at a loopback listener, the only
# bytes malt emits are an HTTP CONNECT to that listener for the API host. A
# broken build sends the listener nothing and reaches the real origin instead.
#
# Usage: scripts/regressions/proxy-env-routes-fetches-through-proxy-proxy-env.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s - run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

TMP=$(mktemp -d -t mt_proxy_env.XXXXXX)
NC_PID=
trap 'kill "$NC_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

PORT=$((20000 + RANDOM % 20000))
nc -l 127.0.0.1 "$PORT" >"$TMP/hits" 2>/dev/null &
NC_PID=$!
sleep 0.3

unset MALT_API_DOMAIN HOMEBREW_API_DOMAIN MALT_OFFLINE
export MALT_PREFIX="$TMP/prefix" MALT_CACHE="$TMP/cache" MALT_NO_VERSION_NOTIFIER=1 NO_COLOR=1
export HTTPS_PROXY="http://127.0.0.1:$PORT" HTTP_PROXY="http://127.0.0.1:$PORT"

# Expected to fail: the fake proxy closes the tunnel after recording it, and
# the retries that follow are refused instantly, so no `timeout` (which the
# CI macOS runner lacks) is needed to bound the run.
"$MALT_BIN" info wget >/dev/null 2>&1 || true

if ! grep -q '^CONNECT formulae.brew.sh:443' "$TMP/hits"; then
  fail "HTTPS_PROXY ignored - proxy saw $(wc -c <"$TMP/hits" | tr -d ' ') bytes, no CONNECT"
fi

# A value that cannot be a proxy is refused up front and named, so the user
# knows which variable to fix instead of meeting a connect timeout later.
if ERR=$(HTTPS_PROXY=":8080" "$MALT_BIN" list 2>&1 >/dev/null) || ! grep -q 'HTTPS_PROXY=:8080' <<<"$ERR"; then
  fail "malformed HTTPS_PROXY was not refused by name: $ERR"
fi

# Offline runs never dial, so the same stray value must not block them.
if ! HTTPS_PROXY=":8080" "$MALT_BIN" --offline list >/dev/null 2>&1; then
  fail "malformed HTTPS_PROXY blocked an offline command"
fi

echo "ok: fetch routed through HTTPS_PROXY, malformed value refused by name, offline unaffected"
