#!/usr/bin/env bash
# Regression: `info --json` on an unknown name reports the kind the caller
# selected. `--cask` must not get back a formula-typed object.
#
# Offline throughout: the API validator refuses `bad..name`, so nothing
# reaches the network, before or after the fix.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=${MALT_BIN:-$ROOT/zig-out/bin/mt}
P=$(mktemp -d /tmp/mt_info_not_found.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX=$P MALT_CACHE=$P/cache
mkdir -p "$P/cache"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check() { # $1 = expected type, rest = argv
  local want=$1 rc=0 out
  shift
  out=$("$B" --offline info --json "$@" 'bad..name' </dev/null) || rc=$?
  [ "$rc" -eq 0 ] || fail "info --json $* exited $rc"
  [ -n "$out" ] || fail "info --json $*: empty stdout"
  [[ $out == *"\"type\":\"$want\",\"installed\":false}"* ]] ||
    fail "info --json $* on unknown name: want type=$want, got: $out"
}

check cask --cask
check formula --formula
check formula --cask --formula
# Default shape stays byte-compatible.
check formula
echo PASS
