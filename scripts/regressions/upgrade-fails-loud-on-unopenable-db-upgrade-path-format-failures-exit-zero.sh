#!/usr/bin/env bash
# Regression: `mt upgrade` and `mt tap <name>` never exit 0 having done
# nothing on a long MALT_PREFIX. A prefix too long for SQLite to open its
# database is refused up front, and the longest accepted one works.
#
# Pre-fix, a 501-512-byte prefix passed validation, overflowed a fixed
# 512-byte path buffer, and the command returned success with no output;
# 494-500 bytes passed validation only to fail at the database open.
# Controls: a healthy short prefix and a fresh prefix with no db/ exit 0.
#
# Usage: scripts/regressions/upgrade-fails-loud-on-unopenable-db-upgrade-path-format-failures-exit-zero.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# Resolved: SQLite measures the real path, and /tmp is a symlink on macOS.
S=$(cd "$(mktemp -d /tmp/mt.XXXXXX)" && pwd -P)
trap 'rm -rf "$S"' EXIT
export MALT_CACHE="$S/cache"
export NO_COLOR=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
run() { MALT_PREFIX=$1 "$BIN" --offline "${@:2}" 2>&1; }

# A prefix of exactly $1 bytes holding a copy of the seeded db/.
long_prefix() {
  local p=$S/l$1
  while ((${#p} < $1 - 60)); do p=$p/$(printf 'a%.0s' {1..50}); done
  p=$p/$(printf 'b%.0s' $(seq 1 $(($1 - 1 - ${#p}))))
  ((${#p} == $1)) || fail "fixture: prefix is ${#p} bytes, wanted $1"
  mkdir -p "$p"
  cp -R "$S/ok/db" "$p/"
  printf '%s' "$p"
}

mkdir -p "$S/cache" "$S/ok/db"
run "$S/ok" uses x >/dev/null || true # seeds a healthy malt.db

rc=0
out=$(run "$S/ok" upgrade) || rc=$?
[[ $rc -eq 0 ]] || fail "healthy: rc=$rc out=$out"
grep -q 'No formulas installed' <<<"$out" || fail "healthy: out=$out"

mkdir -p "$S/fresh"
rc=0
out=$(run "$S/fresh" upgrade) || rc=$?
[[ $rc -eq 0 ]] || fail "fresh: rc=$rc out=$out"

P=$(long_prefix 493)
rc=0
out=$(run "$P" upgrade) || rc=$?
[[ $rc -eq 0 ]] || fail "493-byte prefix: rc=$rc out=$out"
grep -q 'No formulas installed' <<<"$out" || fail "493-byte prefix: out=$out"
rc=0
out=$(run "$P" untap user/repo) || rc=$?
[[ $rc -eq 0 ]] || fail "493-byte prefix, untap: rc=$rc out=$out"

for len in 494 505 512; do
  P=$(long_prefix "$len")
  for cmd in "upgrade" "upgrade --dry-run" "tap user/repo"; do
    rc=0
    # shellcheck disable=SC2086 # split the subcommand and its args
    out=$(run "$P" $cmd) || rc=$?
    [[ $rc -eq 78 ]] || fail "$len-byte prefix, $cmd: rc=$rc out=$out"
    grep -q 'exceeds 493 bytes' <<<"$out" || fail "$len-byte prefix, $cmd: out=$out"
  done
done

echo "ok"
