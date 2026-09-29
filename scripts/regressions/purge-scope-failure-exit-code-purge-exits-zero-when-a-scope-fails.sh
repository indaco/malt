#!/usr/bin/env bash
# Regression: a purge scope that refuses to run (unreadable database) must fail
# the command. `purge` and `cleanup` used to exit 0 and end on a success footer,
# so cron jobs could not tell "nothing to remove" from "refused to run". A fresh
# prefix with no database has nothing to refuse and must still exit 0.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network; all state lives under a throwaway prefix removed on EXIT.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The shell harness runs the built binary; `zig build test` does not refresh
# it, so a stale binary would mask the fix.
zig build >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_CACHE="$tmp/cache"
mkdir -p "$tmp/fresh" "$tmp/bad/db" "$MALT_CACHE"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Control: no database means nothing to do, not a failure.
out=$(MALT_PREFIX="$tmp/fresh" "$BIN" purge --store-orphans --yes 2>&1) ||
  fail "purge on a fresh prefix exited non-zero: $out"
grep -q '^  \* removed' <<<"$out" || fail "purge on a fresh prefix lost its success footer: $out"
out=$(MALT_PREFIX="$tmp/fresh" "$BIN" cleanup --yes 2>&1) ||
  fail "cleanup on a fresh prefix exited non-zero: $out"

printf 'not a sqlite header' >"$tmp/bad/db/malt.db"

rc=0
out=$(MALT_PREFIX="$tmp/bad" "$BIN" purge --store-orphans --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "purge --store-orphans exited 0 over an unreadable database: $out"
grep -q 'store-orphans: cannot open database' <<<"$out" || fail "purge did not name the failed scope: $out"
grep -q '^  \* removed' <<<"$out" && fail "a failed purge still ends on a success footer: $out"
grep -q '^  ! removed' <<<"$out" || fail "a failed purge lost its totals line: $out"

rc=0
out=$(MALT_PREFIX="$tmp/bad" "$BIN" cleanup --json 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "cleanup --json exited 0 over an unreadable database"
grep -q '"status":"error"' <<<"$out" || fail "cleanup --json lost its status:error summary: $out"

echo "PASS"
