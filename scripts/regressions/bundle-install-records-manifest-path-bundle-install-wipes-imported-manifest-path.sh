#!/usr/bin/env bash
# Regression: `bundle install` must record the manifest it installed from.
# It stored no path, so installing an imported bundle erased the path import
# recorded and `bundle remove --purge` refused the bundle; a bundle only ever
# installed could never be purged.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network (the manifests have no members); all state lives under a
# throwaway prefix removed on EXIT.

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
# The path import records: canonical, so /var vs /private/var cannot differ.
real() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

echo '{"name":"dev","version":1}' >"$tmp/dev.json"
out=$("$BIN" bundle import "$tmp/dev.json" 2>&1) || fail "import failed: $out"
out=$("$BIN" bundle install "$tmp/dev.json" 2>&1) || fail "install failed: $out"
got=$(sqlite3 "$DB" "SELECT ifnull(manifest_path,'NULL') FROM bundles WHERE name='dev';")
[ "$got" = "$(real "$tmp/dev.json")" ] || fail "install erased the imported manifest path: $got"

# Installed only, never imported: the path still lands, so purge can find it.
echo '{"name":"solo","version":1}' >"$tmp/solo.json"
out=$("$BIN" bundle install "$tmp/solo.json" 2>&1) || fail "install failed: $out"
got=$(sqlite3 "$DB" "SELECT ifnull(manifest_path,'NULL') FROM bundles WHERE name='solo';")
[ "$got" = "$(real "$tmp/solo.json")" ] || fail "install recorded no manifest path: $got"
out=$("$BIN" bundle remove --purge solo 2>&1) || fail "purge refused an installed bundle: $out"

echo "  ✓ bundle install records the manifest it installed from"
