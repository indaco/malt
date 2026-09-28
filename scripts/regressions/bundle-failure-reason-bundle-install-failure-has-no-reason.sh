#!/usr/bin/env bash
# Regression: `bundle install` routes each member through a silent install
# sink, so a failing member printed only `install failed: <name>` and the
# user had to re-run `mt install <name>` to learn why. The bundle sink now
# keeps the first error line and the failure line carries it.
#
# Offline mode against a throwaway prefix makes the uncached formula fail
# deterministically with no network. Uses the built binary: run `zig build`.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=${MALT_BIN:-$ROOT/zig-out/bin/mt}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$BIN" ] || {
  echo "missing $BIN - run zig build" >&2
  exit 2
}

T=$(mktemp -d /tmp/mt-bfr.XXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/p" "$T/c"
printf 'brew "zz-no-such-formula"\n' >"$T/Brewfile"

# No `timeout`: the CI job running this lacks coreutils, and an offline miss
# fails fast anyway.
rc=0
out=$(env -u MALT_PREFIX -u MALT_CACHE -u MALT_OFFLINE \
  MALT_PREFIX="$T/p" MALT_CACHE="$T/c" MALT_OFFLINE=1 \
  "$BIN" bundle install "$T/Brewfile" 2>&1) || rc=$?

[ "$rc" -ne 0 ] || fail "bundle install unexpectedly succeeded"
grep -q 'install failed: zz-no-such-formula: .*not cached' <<<"$out" ||
  fail "bundle failure line has no reason:"$'\n'"$out"

echo "PASS: bundle install names why a member failed"
