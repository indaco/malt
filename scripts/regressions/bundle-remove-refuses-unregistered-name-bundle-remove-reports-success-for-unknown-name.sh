#!/usr/bin/env bash
# Regression: `bundle remove` must refuse a name that is not registered, as
# `export` and `remove --purge` do. It printed "bundle removed" and exited 0,
# so a typo read as success while the intended bundle stayed registered.
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
export NO_COLOR=1 MALT_NO_EMOJI=1
export MALT_PREFIX="$tmp/p" MALT_CACHE="$tmp/cache"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# A first backup materialises the schema.
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
"$BIN" backup -o - >/dev/null 2>&1
DB="$MALT_PREFIX/db/malt.db"
[ -f "$DB" ] || fail "setup: no database created"
sqlite3 "$DB" "INSERT INTO bundles(name,manifest_path,created_at,version) VALUES('devtools',NULL,0,1);"

for args in "devtool" "--dry-run devtool"; do
  rc=0
  # shellcheck disable=SC2086 # split the flag from the name on purpose
  out=$("$BIN" bundle remove $args 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "remove $args of an unregistered name exited $rc: $out"
  grep -q "bundle not registered: devtool" <<<"$out" || fail "remove $args did not say why: $out"
done
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundles WHERE name='devtools';")" = 1 ] ||
  fail "a refused remove touched the registered bundle"

# Control: the registered name still removes.
out=$("$BIN" bundle remove devtools 2>&1) || fail "remove of a registered bundle failed: $out"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundles;")" = 0 ] || fail "registered bundle not removed"

echo "  ✓ bundle remove refuses a name that is not registered"
