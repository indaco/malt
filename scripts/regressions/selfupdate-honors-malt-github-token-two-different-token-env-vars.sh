#!/usr/bin/env bash
# Regression: the self-update / notifier GitHub API GET (HttpClient.get) must
# honor MALT_GITHUB_TOKEN, not only HOMEBREW_GITHUB_API_TOKEN.
#
# The bug: get() keyed its auto-injected Authorization header exclusively off
# HOMEBREW_GITHUB_API_TOKEN, while the tap/forge path read MALT_GITHUB_TOKEN.
# A user who set only MALT_GITHUB_TOKEN still went out unauthenticated on
# `version update`, hit the anonymous 60/hr cap, and got a hard 403.
#
# The host gate (githubTokenApplies) only injects on real GitHub hosts, so a
# loopback capture server can never exercise the selection end-to-end. Instead
# the guard is an integration test asserting get()'s token resolution prefers
# MALT_GITHUB_TOKEN and treats an empty value as unset. This script builds and
# runs only that test binary, so it stays well under 30s and needs no network.
#
# Exits 0 when the token resolution honors MALT_GITHUB_TOKEN, non-zero when it
# does not (or the guard test is missing).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

TEST_NAME="HttpClient.get token resolution honors MALT_GITHUB_TOKEN, falls back to HOMEBREW_GITHUB_API_TOKEN"
TEST_SRC="tests/http_inject_test.zig"

# If the guard test is ever deleted, the runner would simply report "no tests"
# and pass. Fail loudly instead.
if ! grep -Rqs -- "$TEST_NAME" "$TEST_SRC"; then
  echo "FAIL: the self-update token-resolution guard test is missing from $TEST_SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/http_inject_test"
if [[ ! -x "$BIN" ]]; then
  if ! zig build test-bin >/dev/null 2>&1; then
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  fi
fi

# The runner has no per-test filter, so run the file's suite and judge the
# token-resolution guard by name: a pass ends in "OK", a regression prints
# "FAIL" there and the binary exits non-zero.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$TEST_NAME" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the self-update token-resolution guard test did not run" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: self-update GET did not honor MALT_GITHUB_TOKEN" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi

echo "PASS: self-update honors MALT_GITHUB_TOKEN"
