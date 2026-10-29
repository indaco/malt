#!/usr/bin/env bash
# Regression: `mt doctor` must re-probe the prefix lock when a lock-aware
# check reports, not trust the snapshot taken before the walk. An install
# that takes the lock mid-walk shows expected intermediate states; reporting
# them as faults gives a false exit 2 on a healthy prefix.
#
# The race cannot be timed from the binary, so this runs the integration
# test that takes the lock after the snapshot.
#
# Usage: scripts/regressions/doctor-reprobes-live-lock-doctor-report-path-op-in-flight-toctou.sh
# Requirements: zig. Offline.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1

SRC=tests/doctor_dispatch_test.zig
NAME='an op that takes the lock after the pre-walk snapshot is still detected'
grep -qF "$NAME" "$SRC" || {
  echo "FAIL: guard test renamed or removed from $SRC" >&2
  exit 1
}

env -u MALT_CACHE zig build test-bin >/dev/null 2>&1 || {
  echo "FAIL: zig build test-bin" >&2
  exit 1
}
BIN=zig-out/test-bin/doctor_dispatch_test
[[ -x $BIN ]] || {
  echo "FAIL: $BIN not installed" >&2
  exit 1
}

PFX=$(mktemp -d /tmp/mt_toctou.XXXXXX)
trap 'rm -rf "$PFX"' EXIT

out=$(env -u MALT_CACHE MALT_PREFIX="$PFX" "$BIN" 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "FAIL: doctor reports a live op as a fault when the lock is taken after the snapshot" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS: lock-aware doctor checks re-probe the live lock"
