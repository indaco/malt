#!/usr/bin/env bash
# Regression: a GHCR blob GET that 401s on a locally-unexpired token must
# invalidate the cached token, re-fetch a fresh one, and replay the GET once.
#
# The bug: downloadBlob documented "401 -> token -> retry" but treated the
# first 401 as terminal (returned Unauthorized, cache untouched). A token the
# local clock still considers valid but the registry rejects — clock skew,
# early revocation, a scope gap — failed the download outright, and the stale
# token poisoned every sibling batch worker until the expiry buffer lapsed.
#
# No CLI surface points downloadBlob at an arbitrary registry, so the retry is
# exercised by an integration test: a loopback stub registry answers /token
# (fresh token per call) and 401s the first blob GET, then 200s the second only
# if a new bearer is presented. The test asserts the download succeeds, two
# token fetches happened, and the retry carried a different bearer. This script
# builds and runs only that test binary, so it stays well under 30s, cleans up
# after itself (no temp state), and needs no network.
#
# Exits 0 when the invalidate-and-retry path works, non-zero when the first
# 401 is terminal (retry not implemented).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

TEST_NAME="downloadBlob invalidates the cached token and retries once on a 401"
TEST_SRC="tests/ghcr_401_retry_test.zig"

# If the guard test is ever deleted, the runner would report "no tests" and
# pass silently. Fail loudly instead.
if ! grep -Rqs -- "$TEST_NAME" "$TEST_SRC"; then
  echo "FAIL: the blob 401 retry guard test is missing from $TEST_SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/ghcr_401_retry_test"
if [[ ! -x "$BIN" ]]; then
  if ! zig build test-bin >/dev/null 2>&1; then
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  fi
fi

# The runner has no per-test filter, so run the file's suite and judge the
# retry guard by name: a pass ends in "OK", a regression prints "FAIL" there
# (the first 401 was terminal) and the binary exits non-zero.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the blob 401 retry guard test did not run" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: downloadBlob returned Unauthorized on a recoverable 401 (retry not implemented)" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi

echo "PASS: a 401 blob download triggers token invalidation + a single retry"
