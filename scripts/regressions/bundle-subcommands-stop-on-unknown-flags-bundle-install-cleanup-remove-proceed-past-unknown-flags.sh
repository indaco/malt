#!/usr/bin/env bash
# Regression: `bundle install`, `cleanup` and `remove` must stop on a flag they
# don't know instead of warning and running the unmodified mutation. A mistyped
# safety flag (`--prge`, `--dryrun`) used to run the real operation, and
# `install -n` (offered by completions, honoured by cleanup and remove)
# installed for real.
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
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
DB="$MALT_PREFIX/db/malt.db"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# refused <what> <rc> <out> <flag>
refused() {
  [ "$2" -ne 0 ] || fail "$1 ran past $4 and exited 0: $3"
  grep -q "Unknown flag: $4" <<<"$3" || fail "$1 did not name $4: $3"
}

# A first backup materialises the schema so the seed rows have tables.
"$BIN" backup -o - >/dev/null 2>&1
[ -f "$DB" ] || fail "setup: no database created"
echo '# empty' >"$tmp/Brewfile"

# A real install records the bundle; a preview records nothing.
rc=0
out=$("$BIN" bundle install -n "$tmp/Brewfile" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "install -n exited $rc: $out"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundles;")" = 0 ] ||
  fail "install -n ran a real install and recorded the bundle: $out"

rc=0
out=$("$BIN" bundle install --bogus "$tmp/Brewfile" 2>&1) || rc=$?
refused install "$rc" "$out" --bogus
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundles;")" = 0 ] ||
  fail "install --bogus recorded the bundle"

sqlite3 "$DB" "INSERT INTO bundles(name,manifest_path,created_at,version) VALUES('dev',NULL,0,1);"
rc=0
out=$("$BIN" bundle remove --prge dev 2>&1) || rc=$?
refused remove "$rc" "$out" --prge
[ "$(sqlite3 "$DB" "SELECT count(*) FROM bundles WHERE name='dev';")" = 1 ] ||
  fail "remove --prge unregistered the bundle"

# --yes and a closed stdin keep a pre-fix run from blocking on the confirm.
rc=0
out=$("$BIN" bundle cleanup --dryrun --yes "$tmp/Brewfile" 2>&1 </dev/null) || rc=$?
refused cleanup "$rc" "$out" --dryrun
if grep -q "using bundle file" <<<"$out"; then
  fail "cleanup read the bundle file before refusing: $out"
fi

echo "  ✓ bundle install, cleanup and remove stop on an unknown flag"
