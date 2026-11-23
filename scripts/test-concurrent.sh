#!/usr/bin/env bash
#
# Run the test suite as several simultaneous processes.
#
# `zig build test` runs one process, so it cannot see a test that shares a
# fixture path with another run. Those bugs surface only under parallelism:
# two processes build a tree at the same path and delete each other's files,
# which reads as OpenFailed, PathAlreadyExists, FileNotFound or a sqlite
# LockError somewhere unrelated to the real culprit.
#
# Usage: scripts/test-concurrent.sh [copies] [rounds]

set -euo pipefail

# Keep test binaries off the developer's real cache and prefix.
unset MALT_CACHE
export MALT_PREFIX=/tmp/malt-test-prefix
cd "$(dirname "$0")/.."

copies=${1:-6}
rounds=${2:-2}

log_dir=$(mktemp -d "/tmp/malt_concurrent.XXXXXX")
# The logs are the only record of a failing run, so only a clean run removes them.
trap '[ "$failed" -eq 0 ] && rm -rf "$log_dir"' EXIT
failed=0

echo "▸ Building test binaries"
zig build test-bin

bin=zig-out/test-bin/lib_tests
if [ ! -x "$bin" ]; then
  echo "error: $bin missing — did 'zig build test-bin' change its output?" >&2
  exit 1
fi

# Scratch trees are keyed by pid, so a leak only shows up as a directory
# nobody removed. Count around the run rather than trusting exit codes.
count_scratch() {
  {
    find .zig-cache/tmp -mindepth 1 -maxdepth 1 2>/dev/null
    find /tmp -maxdepth 1 -name 'malt_*' 2>/dev/null
  } | wc -l | tr -d ' '
}
scratch_before=$(count_scratch)

for round in $(seq 1 "$rounds"); do
  echo "▸ Round $round/$rounds — $copies concurrent copies"
  pids=""
  for i in $(seq 1 "$copies"); do
    "$bin" >"$log_dir/r${round}_$i.log" 2>&1 &
    pids="$pids $!"
  done

  # Collect every exit status; a bare `wait` would report only the last.
  for pid in $pids; do
    if ! wait "$pid"; then
      failed=$((failed + 1))
    fi
  done
done

if [ "$failed" -gt 0 ]; then
  echo "error: $failed of $((copies * rounds)) concurrent runs failed" >&2
  echo "  Two processes almost certainly shared a fixture path. Failing tests:" >&2
  # Test output can push FAIL onto a line of its own, so name the test
  # from the last "N/M name..." line seen before it.
  awk '/^[0-9]+\/[0-9]+ /{name=$0} /FAIL/{print ($0 == name ? $0 : name " " $0)}' \
    "$log_dir"/*.log 2>/dev/null | sort -u | sed 's/^/    /' >&2
  echo "  Logs kept in $log_dir" >&2
  exit 1
fi

scratch_after=$(count_scratch)
if [ "$scratch_after" -gt "$scratch_before" ]; then
  echo "error: $((scratch_after - scratch_before)) scratch dir(s) leaked" >&2
  echo "  A test built a scratch tree and never removed it." >&2
  exit 1
fi

echo "✓ $((copies * rounds)) concurrent runs clean, no scratch leaked"
