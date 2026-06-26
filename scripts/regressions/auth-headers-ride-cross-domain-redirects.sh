#!/usr/bin/env bash
# Regression: a credential header (GitHub PAT / GHCR bearer) must NOT follow a
# redirect off the origin's scheme+parent-domain.
#
# The bug: malt injected credentials through stdlib's `extra_headers`, which are
# deliberately kept across a redirect to a different domain. GitHub release and
# GHCR blob URLs 302 to object storage on another domain, so the secret rode the
# hop and was re-sent verbatim to the CDN (and, on an https->http downgrade, to a
# cleartext socket). stdlib's `privileged_headers` slot is never written to the
# wire in this toolchain, so the fix takes over redirect-following and drops the
# credential whenever the next hop changes scheme or leaves the parent domain.
#
# No CLI surface points a credentialed GET at an arbitrary URL, so the guard is
# exercised by an integration test (loopback hop-1 302s to a different-host
# hop-2 that records request headers; the test asserts the origin is still
# authenticated but the cross-domain target sees no Authorization). This script
# builds and runs only that test binary, so it stays well under 30s and needs no
# network.
#
# Exits 0 when credentials are stripped on the cross-domain hop, non-zero when
# they ride.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

TEST_NAME="auth headers stripped on redirect across a cross-domain hop"
TEST_SRC="tests/net_redirect_auth_test.zig"

# If the guard test is ever deleted, the runner would simply report "no tests"
# and pass. Fail loudly instead.
if ! grep -Rqs -- "$TEST_NAME" "$TEST_SRC"; then
  echo "FAIL: the cross-domain auth-strip guard test is missing from $TEST_SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/net_redirect_auth_test"
if [[ ! -x "$BIN" ]]; then
  if ! zig build test-bin >/dev/null 2>&1; then
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  fi
fi

# The runner has no per-test filter, so run the file's suite and judge the
# cross-domain guard by name: a pass ends in "OK", a regression prints "FAIL"
# there (the credential rode to the off-domain target) and the binary exits
# non-zero.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the cross-domain auth-strip guard test did not run" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a credential header rode a cross-domain redirect" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi

echo "PASS: credential headers stripped across cross-domain / downgrade redirects"
