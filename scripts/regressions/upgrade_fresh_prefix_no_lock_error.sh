#!/usr/bin/env bash
# Regression: `mt upgrade` against a fresh, never-initialised prefix.
#
# When malt is installed via the Homebrew cask, nothing creates the
# prefix (e.g. /opt/malt) up front. Running `mt upgrade` before the
# first install therefore reached the advisory lock at
# `<prefix>/db/malt.lock`, whose parent `db/` did not exist. The lock
# create failed with ENOENT, which `LockFile.acquire` collapsed into a
# generic open error, and the command reported:
#
#   ✗ Could not acquire lock. Another malt process may be running.
#
# — a flat-out wrong diagnosis (no other process was involved) and a
# non-zero exit. The fix distinguishes a missing lock directory
# (DirMissing) from real contention (Timeout): a fresh prefix has
# nothing installed and therefore nothing to upgrade, so `mt upgrade`
# exits 0 silently instead of crying contention.
#
# This script points MALT_PREFIX at a path that does not exist, runs
# `mt upgrade`, and asserts a clean exit with no contention message.
#
# Usage: scripts/regressions/upgrade_fresh_prefix_no_lock_error.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# A prefix that is guaranteed not to exist: parent is created, the prefix
# itself (and its db/ dir) is not, mirroring a just-installed cask.
PREFIX="/tmp/mt_fresh_prefix_$$"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

printf '\xe2\x96\xb8 mt upgrade on a non-existent prefix %s\n' "$PREFIX"

# Capture both streams and the exit code without tripping `set -e`.
OUT=$("$BIN" upgrade 2>&1) && RC=0 || RC=$?

# --- 1. Clean exit -----------------------------------------------------
[[ "$RC" -eq 0 ]] ||
  fail "expected exit 0 on a fresh prefix, got $RC; output: $OUT"
pass "exit 0 (nothing installed = nothing to upgrade)"

# --- 2. No phantom contention message ----------------------------------
if echo "$OUT" | grep -qi "Another malt process"; then
  fail "reported phantom lock contention; output: $OUT"
fi
pass "no 'Another malt process' message"

# --- 3. The prefix was not silently created as a side effect -----------
# `mt upgrade` is read-only on an empty system; it must not materialise a
# prefix just to discover there is nothing to do.
[[ ! -e "$PREFIX" ]] ||
  fail "upgrade created $PREFIX as a side effect"
pass "prefix left untouched"

printf '\n\xe2\x9c\x94 upgrade-fresh-prefix regression passed\n'
