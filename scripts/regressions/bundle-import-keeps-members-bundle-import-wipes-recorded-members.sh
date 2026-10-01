#!/usr/bin/env bash
# Regression: `bundle import` of an already-recorded bundle must keep the
# members `bundle install` recorded. A replace of the bundles row cascaded
# through bundle_members, so `bundle export <name>` printed an empty manifest
# and exited 0.
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

# A first backup materialises the schema so the seed rows have tables.
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
"$BIN" backup -o - >/dev/null 2>&1
DB="$MALT_PREFIX/db/malt.db"
[ -f "$DB" ] || fail "setup: no database created"

echo '{"name":"dev","version":1,"formulas":[{"name":"wget"}]}' >"$tmp/Maltfile.json"
# The rows `bundle install` records for this manifest.
sqlite3 "$DB" "INSERT INTO bundles(name,manifest_path,created_at,version) VALUES('dev','$tmp/Maltfile.json',0,1);
  INSERT INTO bundle_members(bundle_name,kind,ref) VALUES('dev','formula','wget');"

out=$("$BIN" bundle export dev 2>&1) || fail "control: export failed: $out"
grep -q '"wget"' <<<"$out" || fail "control: seeded export lost wget: $out"

out=$("$BIN" bundle import "$tmp/Maltfile.json" 2>&1) || fail "import failed: $out"

out=$("$BIN" bundle export dev 2>&1) || fail "export after import failed: $out"
grep -q '"wget"' <<<"$out" || fail "import wiped the bundle's members: '$out'"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundle_members WHERE bundle_name='dev';")" = 1 ] ||
  fail "bundle_members row gone after import"
# The upsert must still refresh the registration it was asked to record.
[ "$(sqlite3 "$DB" "SELECT created_at > 0 FROM bundles WHERE name='dev';")" = 1 ] ||
  fail "import did not update the bundles row"

echo "  ✓ bundle import keeps a recorded bundle's members"
