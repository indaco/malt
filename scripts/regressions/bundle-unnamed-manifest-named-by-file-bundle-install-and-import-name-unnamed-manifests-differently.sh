#!/usr/bin/env bash
# Regression: a manifest without a name (every Brewfile) must be one bundle,
# named by its file, whichever of `bundle import` / `bundle install` saw it.
# Import named it by the typed path and install as "unnamed", so one Brewfile
# became two bundles and every unnamed install overwrote the same one.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network (the Brewfiles have no members); all state lives under a
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
real() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

mkdir -p "$tmp/a" "$tmp/b"
echo '# empty bundle' >"$tmp/a/Brewfile"
echo '# empty bundle' >"$tmp/b/Brewfile"

# Typed relative, as `bundle import Brewfile` from its own directory would be.
out=$(cd "$tmp/a" && "$BIN" bundle import Brewfile 2>&1) || fail "import failed: $out"
out=$("$BIN" bundle install "$tmp/a/Brewfile" 2>&1) || fail "install failed: $out"
out=$("$BIN" bundle install "$tmp/b/Brewfile" 2>&1) || fail "install failed: $out"

want="$(real "$tmp/a/Brewfile")
$(real "$tmp/b/Brewfile")"
got=$(sqlite3 "$DB" "SELECT name FROM bundles ORDER BY name;")
[ "$got" = "$want" ] || fail "unnamed manifests are not one bundle per file: $(tr '\n' ' ' <<<"$got")"

echo "  ✓ an unnamed manifest is one bundle, named by its file"
