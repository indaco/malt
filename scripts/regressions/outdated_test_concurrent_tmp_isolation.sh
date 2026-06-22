#!/usr/bin/env bash
# Regression: each outdated_test cache dir must be unique per process+init, so
# two overlapping test runs cannot wipe each other's seeded cache mid-test.
#
# The bug: the test helpers opened a FIXED /tmp path and deleteTree'd it on
# setup. A second concurrent outdated_test process wiped the first's seeded
# cache, surfacing as `expected N, found 0` (TestExpectedEqual) or
# `unexpected errno: 22` on a directory whose parent vanished underneath it.
# A single isolated run never collides — which is exactly why it read as a
# non-reproducing flake.
#
# This script forces the race: it runs several outdated_test processes
# concurrently and fails if any temp-path corruption signature appears. The
# unrelated, still-open sqlite WAL `OpenFailed` flake is deliberately ignored so
# this guard does not itself flake on it.
#
# Usage: scripts/regressions/outdated_test_concurrent_tmp_isolation.sh
# Requirements: built test binary at zig-out/test-bin/outdated_test.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="$ROOT/zig-out/test-bin/outdated_test"
[[ -x "$BIN" ]] || zig build test-bin >/dev/null 2>&1 || true
[[ -x "$BIN" ]] || {
  echo "build the test binary first: zig build test-bin" >&2
  exit 2
}

WORK=$(mktemp -d -t malt_outdated_conc.XXXXXX)
trap 'rm -rf "$WORK" /tmp/malt_outdated_test_* /tmp/malt_outdated_pinned_* /tmp/malt_update_test_* 2>/dev/null || true' EXIT

CONC=8
ROUNDS=6
for _ in $(seq 1 "$ROUNDS"); do
  for j in $(seq 1 "$CONC"); do
    "$BIN" >"$WORK/o.$$.$j.$RANDOM" 2>&1 &
  done
  # A process may exit non-zero on the orthogonal WAL flake; ignore exit codes
  # here — the temp-path verdict comes solely from the signature grep below.
  wait || true
done

if grep -rqE "found 0|unexpected errno: 22" "$WORK"; then
  echo "FAIL: concurrent outdated_test runs corrupted a shared temp cache dir" >&2
  grep -rhE "found 0|unexpected errno: 22" "$WORK" | sort -u | head >&2
  exit 1
fi

echo "ok: $((CONC * ROUNDS)) concurrent outdated_test runs, no temp-path corruption"
