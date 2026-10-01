#!/usr/bin/env bash
# Regression: the global `--dry-run` must preview `bundle create`,
# `bundle import` and `backup`, leaving the Brewfile, backup file and bundle
# registry untouched.
#
# The bug: none of the three read the flag, so a preview overwrote the
# Brewfile or backup file and registered the bundle, then exited 0.
#
# Exits 0 when every dry run leaves those untouched, non-zero with a message
# otherwise. No network; well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MALT_PREFIX="$tmp/p"
export MALT_CACHE="$tmp/c"
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE" "$tmp/w"
export NO_COLOR=1
export MALT_NO_EMOJI=1
DB="$MALT_PREFIX/db/malt.db"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Creates the schema so the bundles count below reads a real table.
"$BIN" backup -o - >/dev/null 2>&1 || fail "could not initialise the database"

"$BIN" --dry-run bundle create "$tmp/dry.Brewfile" >/dev/null 2>&1 || fail "bundle create --dry-run failed"
[ -e "$tmp/dry.Brewfile" ] && fail "--dry-run bundle create wrote the file"

echo '{"name":"dev","version":1,"formulas":[]}' >"$tmp/Maltfile.json"
"$BIN" --dry-run bundle import "$tmp/Maltfile.json" >/dev/null 2>&1 || fail "bundle import --dry-run failed"
[ "$(sqlite3 "$DB" 'select count(*) from bundles')" = 0 ] || fail "--dry-run bundle import registered the bundle"

"$BIN" --dry-run backup -o "$tmp/bk.txt" >/dev/null 2>&1 || fail "backup --dry-run failed"
[ -e "$tmp/bk.txt" ] && fail "--dry-run backup wrote the file"

"$BIN" --dry-run --json backup -o "$tmp/bk.json" >/dev/null 2>&1 || fail "backup --json --dry-run failed"
[ -e "$tmp/bk.json" ] && fail "--dry-run backup --json wrote the file"

# No -o: the dated default lands in the cwd.
(cd "$tmp/w" && "$BIN" --dry-run backup >/dev/null 2>&1) || fail "backup --dry-run to the default path failed"
[ -z "$(ls -A "$tmp/w")" ] || fail "--dry-run backup wrote the default backup file"

# Control: without the flag the same commands still write, so the checks
# above can't pass on a broken path.
"$BIN" bundle create "$tmp/real.Brewfile" >/dev/null 2>&1 && [ -f "$tmp/real.Brewfile" ] ||
  fail "bundle create no longer writes without --dry-run"
"$BIN" backup -o "$tmp/real.txt" >/dev/null 2>&1 && [ -f "$tmp/real.txt" ] ||
  fail "backup no longer writes without --dry-run"

echo "ok: --dry-run bundle create, bundle import and backup leave the Brewfile, backup file and bundle registry untouched"
