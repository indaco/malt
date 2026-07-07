#!/usr/bin/env bash
# Regression: unknown-command hint paths must report overlong argv cleanly
# instead of aborting. Both the slug-hint and the brew-fallback notice format
# the argv-derived string into a 1024-byte stack buffer and unwrap the result
# with `catch unreachable`; a long enough argument made bufPrint return
# NoSpaceLeft and the process died with a panic (SIGABRT) instead of the
# normal "not a malt command" error.
#
# Drives all three overflow shapes against the built binary:
#   - 2-segment slug >= 317 bytes (slug interpolated three times)
#   - 3-segment slug >= 486 bytes (slug interpolated twice)
#   - slash-free arg >= 933 bytes (brew-fallback notice, stub brew via
#     MALT_BREW_PATH so no real brew or live prefix is touched)
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MT="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

check_no_panic() { # $1=label $2=output
  if printf '%s' "$2" | grep -qi 'panic'; then
    fail "$1: panicked instead of reporting a clean error"
  fi
  if ! printf '%s' "$2" | grep -q 'is not a malt command'; then
    fail "$1: expected hint/notice missing from output"
  fi
}

# 2-segment slug, >= 317 bytes -> slug-hint path, triple interpolation.
slug2="$(printf 'a%.0s' {1..400})/$(printf 'b%.0s' {1..400})"
rc=0
out="$("$MT" "$slug2" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "slug2: want exit 1, got $rc"
check_no_panic "slug2" "$out"

# 3-segment slug, >= 486 bytes -> the other slug-hint arm.
slug3="$(printf 'a%.0s' {1..300})/$(printf 'b%.0s' {1..300})/$(printf 'c%.0s' {1..300})"
rc=0
out="$("$MT" "$slug3" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "slug3: want exit 1, got $rc"
check_no_panic "slug3" "$out"

# Slash-free arg >= 933 bytes -> brew-fallback notice. A stub brew keeps the
# run offline and away from any real brew; its exit code is forwarded, so
# only the notice and the absence of a panic are asserted.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 0\n' >"$tmp/brew"
chmod +x "$tmp/brew"
long="$(printf 'x%.0s' {1..2000})"
rc=0
out="$(MALT_BREW_PATH="$tmp/brew" "$MT" "$long" 2>&1)" || rc=$?
[ "$rc" -eq 134 ] && fail "fallback-notice: aborted (exit 134)"
check_no_panic "fallback-notice" "$out"

echo "PASS: overlong unknown commands report cleanly on all three paths"
