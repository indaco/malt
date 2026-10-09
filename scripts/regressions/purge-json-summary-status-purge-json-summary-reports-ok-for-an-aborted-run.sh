#!/usr/bin/env bash
# Regression: if `purge --json` or `cleanup --json` exits non-zero, the summary
# must not report a top-level `"status":"ok"`. Before the fix, the summary got
# its status from the scope rows only. An interrupt between scopes adds no
# failed row, so an aborted run looked like a clean run.
#
# A second process holds the flock on db/malt.lock, so purge waits for the
# lock. The script sends SIGINT only after purge opens the lock file, so the
# result does not depend on timing.
#
# Exits 0 if the bug is absent. Exits non-zero with a message if it is present.
# No network. The EXIT trap kills the lock holder and removes the temporary
# prefix that holds all state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The script runs the built binary. `zig build test` does not rebuild it, and
# an old binary can hide the fix.
zig build >/dev/null

tmp=$(mktemp -d /tmp/mt_purge_sum.XXXXXX)
holder=""
trap '[ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_PREFIX="$tmp/prefix" MALT_CACHE="$tmp/cache"
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
lock="$MALT_PREFIX/db/malt.lock"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Interrupt the command while it waits for the lock, then check the summary.
# $1=label, then the malt arguments.
check() {
  local label=$1 out="$tmp/$1.json" pid rc ready=""
  shift
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

  "$BIN" "$@" >"$out" 2>/dev/null &
  pid=$!
  # A background job starts with SIGINT ignored. Malt opens the lock file
  # only after it installs its handler, so an open lock file means ready.
  for _ in $(seq 1 100); do
    if lsof -t -- "$lock" 2>/dev/null | grep -qx "$pid"; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [ -n "$ready" ] || fail "$label: malt never opened the lock file"
  kill -INT "$pid"
  # Release the lock now, so malt reaches the scope check at once.
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  holder=""
  rc=0
  wait "$pid" || rc=$?

  [ "$rc" -ne 0 ] || fail "$label: the interrupted run exited 0"
  # Match the top-level status after totals. A row status can also be "error".
  grep -q '"totals":{[^}]*},"status":"error"' "$out" ||
    fail "$label: exited $rc but the summary status is not error: $(<"$out")"
}

check purge purge --cache --broken-symlinks --dry-run --json
check cleanup cleanup --dry-run --json

echo "PASS"
