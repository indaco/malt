#!/usr/bin/env bash
# Pin that Ctrl-C actually stops `mt doctor`.
#
# malt installs a SIGINT handler that only flips a process-global flag, so
# the kernel's default terminate disposition is gone for the whole run.
# Doctor never polled that flag: a Ctrl-C during its multi-second Cellar
# walk was recorded and then ignored, and the command ran the full check
# table to completion.
#
# Pinned behaviour:
#   1. A SIGINT delivered mid-walk stops the run — the checks that come
#      after the Cellar walk never render.
#   2. The run exits 130 (128 + SIGINT), the shell convention.
#   3. The checks before the walk still render, so a pass means "stopped
#      mid-table", not "died before starting".
#   4. `--fix` never starts: an interrupted walk holds a partial picture, so
#      no mutating sweep may be planned from it.
#
# Hermetic: MALT_OFFLINE short-circuits the network probe, and the prefix is
# a throwaway mktemp tree. The Cellar is seeded with cloned multi-megabyte
# files so the placeholder walk lasts long enough for the signal to land
# inside it — with a fast walk both a fixed and a broken binary finish
# before the signal and the script would prove nothing.
#
# Usage: scripts/regressions/doctor-honors-sigint-gh820.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_doctor_sigint.XXXXXX)
trap 'rm -rf "$PFX"' EXIT

KEG="$PFX/Cellar/pkg/1.0/bin"
mkdir -p "$KEG"

# 9MB is just under the 10MB cap doctor scans; the clone keeps the seeding
# cost near zero on APFS.
SEED="$PFX/seed"
dd if=/dev/zero bs=1m count=9 2>/dev/null | tr '\0' 'a' >"$SEED"
for i in $(seq 1 100); do
  cp -c "$SEED" "$KEG/f$i" 2>/dev/null || cp "$SEED" "$KEG/f$i"
done
rm -f "$SEED"

export MALT_PREFIX="$PFX" MALT_OFFLINE=1

# Run doctor with the given extra args, interrupt it mid-walk, and echo the
# exit status. Output lands in $1.
run_interrupted() {
  local out=$1
  shift
  "$MALT_BIN" doctor "$@" >"$out" 2>&1 &
  local pid=$!

  # Long enough to be inside the Cellar walk, short enough that a swallowed
  # signal still has most of the walk left to run.
  sleep 1
  kill -INT "$pid"

  # Guard against a doctor that neither honours the signal nor terminates.
  # stdout is closed so the watchdog cannot hold this function's command
  # substitution open for its full sleep.
  (
    sleep 15
    kill -KILL "$pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local watchdog=$!

  local rc
  set +e
  wait "$pid"
  rc=$?
  set -e
  kill "$watchdog" 2>/dev/null || true
  printf '%s' "$rc"
}

OUT="$PFX/out.txt"
rc=$(run_interrupted "$OUT")

grep -q 'MALT_PREFIX' "$OUT" ||
  fail 'doctor never reached the check table — the run died for an unrelated reason'

if grep -q 'Disk space' "$OUT"; then
  fail 'doctor ran past the Cellar walk despite SIGINT (the signal was swallowed)'
fi

[[ "$rc" -eq 130 ]] ||
  fail "expected exit 130 after SIGINT, got $rc"

# --fix must never plan a sweep off a partial walk.
FIX_OUT="$PFX/fix.txt"
fix_rc=$(run_interrupted "$FIX_OUT" --fix)

if grep -q 'safe-class fixes' "$FIX_OUT"; then
  fail 'doctor --fix started applying fixes after SIGINT'
fi

[[ "$fix_rc" -eq 130 ]] ||
  fail "expected exit 130 from --fix after SIGINT, got $fix_rc"

printf 'PASS: doctor stops on SIGINT, exits 130, and skips --fix\n'
