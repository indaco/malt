#!/usr/bin/env bash
# Regression: a tap cask's `binary "<x>"` must not steer a bare release
# binary outside its keg.
#
# The bug: for a suffix-less URL the downloaded asset is copied to
# `<keg>/bin/<x>` with `<x>` taken verbatim from the tap `.rb`, so a
# `..`-laden value overwrote any file the user could write, mode 0755.
#
# The fix screens that name with the shared path-component predicate before
# any Cellar mutation (ahead of the --force prune). `--local` never reads the
# directive and MALT_API_DOMAIN is https-only, so no offline binary-level
# repro exists: this asserts the screen and its call site are wired, then
# builds and runs the inline tests in `lib_tests`. About a minute, no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SRC=src/cli/install/local.zig

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fqs -- "fn screenRawBinaryName" "$SRC" ||
  fail "the raw binary name screen is gone - a tap binary name can escape the keg"
grep -A12 -- "fn screenRawBinaryName" "$SRC" | grep -Fqs -- "isPathComponent" ||
  fail "the raw binary name screen no longer uses isPathComponent"

# The screen must run before --force prunes the old keg, or a refusal
# deletes the installed version first.
call=$(grep -n -- "try screenRawBinaryName(" "$SRC" | head -1 | cut -d: -f1)
prune=$(grep -n -- "pruneCellarForReinstall(ctx" "$SRC" | head -1 | cut -d: -f1)
[[ -n "$call" && -n "$prune" && "$call" -lt "$prune" ]] ||
  fail "the raw binary name screen is not called, or runs after the --force prune"

grep -Eqs -- 'test ".*unsafe binary name' "$SRC" ||
  fail "the unsafe binary name refusal tests were removed"

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source; a caller's MALT_*
# must not leak into the tests.
env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >/dev/null 2>&1 ||
  fail "could not build the unit test binary (zig build test-bin)"

OUT=$(env -u MALT_PREFIX -u MALT_CACHE "$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  fail "lib_tests failed - a tap binary name may escape the keg"
fi

echo "PASS: a tap's raw binary name is screened before any Cellar write"
