#!/usr/bin/env bash
# Regression: each clonefile_test temp root must be unique per process+init, so
# two overlapping test runs cannot race on setup/teardown of a shared /tmp tree.
#
# The bug: the test helpers built a FIXED /tmp path and, on setup, did a
# best-effort deleteTree followed by a hard makeDir. A second concurrent
# clonefile_test process (or a stale leftover from a killed run) left the
# directory present at the instant makeDir ran, surfacing `PathAlreadyExists`
# before any clone executed; a narrower window also let a concurrent re-create
# of root/dst flip the clone result. A single isolated run never collides —
# which is exactly why it read as a non-reproducing flake.
#
# This script forces the race: it runs several clonefile_test processes
# concurrently across rounds and fails if any shared-temp-path signature
# appears in the captured output.
#
# Usage: scripts/regressions/clonefile_test_concurrent_tmp_isolation.sh
# Requirements: built test binary at zig-out/test-bin/clonefile_test.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="$ROOT/zig-out/test-bin/clonefile_test"
[[ -x "$BIN" ]] || zig build test-bin >/dev/null 2>&1 || true
[[ -x "$BIN" ]] || {
  echo "build the test binary first: zig build test-bin" >&2
  exit 2
}

WORK=$(mktemp -d -t malt_clonefile_conc.XXXXXX)
trap 'rm -rf "$WORK" /tmp/malt_clonefile_test_* /tmp/malt_clonefile_nowhere /tmp/malt_clonefile_nonapfs_dst 2>/dev/null || true' EXIT

CONC=8
ROUNDS=6
for _ in $(seq 1 "$ROUNDS"); do
  for j in $(seq 1 "$CONC"); do
    "$BIN" >"$WORK/o.$$.$j.$RANDOM" 2>&1 &
  done
  # A run may exit non-zero on a collision; ignore exit codes here — the
  # temp-path verdict comes solely from the signature grep below.
  wait || true
done

if grep -rqE "PathAlreadyExists|error.AlreadyExists|error.NotDir" "$WORK"; then
  echo "FAIL: concurrent clonefile_test runs collided on a shared /tmp path" >&2
  grep -rhE "PathAlreadyExists|error.AlreadyExists|error.NotDir" "$WORK" | sort -u | head >&2
  exit 1
fi

echo "ok: $((CONC * ROUNDS)) concurrent clonefile_test runs, no temp-path collision"
