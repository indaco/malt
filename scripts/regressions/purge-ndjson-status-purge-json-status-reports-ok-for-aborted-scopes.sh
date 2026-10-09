#!/usr/bin/env bash
# Regression: if a `purge` run exits non-zero, its NDJSON stream must not close
# with `purge_complete ... "status":"ok"`. Consumers use that line as the result
# of the run. Before the fix, an interrupted run looked like a clean run.
#
# Checks:
#   1. SIGINT before the first non-wipe scope. A second process holds the
#      flock on db/malt.lock, so purge waits for the lock. The script sends
#      the signal only after purge opens the lock file, so the result does
#      not depend on timing.
#   2. Pin, not proof of the fix: the user declines a wipe at the confirm
#      prompt. The wipe path already reported this correctly.
#
# Exits 0 if the bug is absent. Exits non-zero with a message if it is present.
# No network. The EXIT trap removes the temporary prefix that holds all state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The script runs the built binary. `zig build test` does not rebuild it, and
# an old binary can hide the fix.
zig build >/dev/null

tmp=$(mktemp -d /tmp/mt_purge_ndjson.XXXXXX)
holder=""
trap '[ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_PREFIX="$tmp/prefix" MALT_CACHE="$tmp/cache"
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
lock="$MALT_PREFIX/db/malt.lock"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Interrupt purge while it waits for the lock. Sets `rc`.
# $1=label $2=output file, then the output-format flags.
interrupted_run() {
  local label=$1 out=$2 pid ready=""
  shift 2
  : >"$tmp/holder.out"
  perl -e 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die $!;
    flock($f, LOCK_EX) or die $!; print "locked\n"; $| = 1; sleep 30' \
    "$lock" >"$tmp/holder.out" &
  holder=$!
  for _ in $(seq 1 50); do
    grep -q locked "$tmp/holder.out" && break
    sleep 0.1
  done
  grep -q locked "$tmp/holder.out" || fail "$label: lock holder never took the flock"

  "$BIN" purge --cache --broken-symlinks --dry-run "$@" >"$out" 2>/dev/null &
  pid=$!
  # A background job starts with SIGINT ignored. Purge opens the lock file
  # only after it installs its handler, so an open lock file means ready.
  for _ in $(seq 1 100); do
    if lsof -t -- "$lock" 2>/dev/null | grep -qx "$pid"; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [ -n "$ready" ] || fail "$label: purge never opened the lock file"
  kill -INT "$pid"
  # Release the lock now, so purge reaches the scope check at once.
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  holder=""
  rc=0
  wait "$pid" || rc=$?

  [ "$rc" -eq 130 ] || fail "$label: expected exit 130, got $rc: $(<"$out")"
  grep -q '"scope":' "$out" && fail "$label: a scope ran despite the pending interrupt: $(<"$out")"
  return 0
}

interrupted_run sigint-ndjson "$tmp/ndjson.out" --output-format=ndjson
grep -q '"event":"purge_complete".*"status":"error"' "$tmp/ndjson.out" ||
  fail "sigint-ndjson: exited $rc but purge_complete did not report status:error: $(<"$tmp/ndjson.out")"

rc=0
echo no | "$BIN" purge --wipe --output-format=ndjson >"$tmp/wipe.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "wipe-declined: expected a non-zero exit, got 0"
grep -q '"event":"purge_complete".*"status":"error"' "$tmp/wipe.out" ||
  fail "wipe-declined: exited $rc but purge_complete did not report status:error: $(<"$tmp/wipe.out")"

echo "PASS"
