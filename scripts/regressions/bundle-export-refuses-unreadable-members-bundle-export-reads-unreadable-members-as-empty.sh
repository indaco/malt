#!/usr/bin/env bash
# Regression: `bundle export` must refuse a database it cannot read, not print
# a manifest missing what it failed to read. A named bundle whose members are
# unreadable used to export as empty and exit 0; an unnamed export over an
# unreadable table surfaced a raw error name and trace instead of words.
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
fresh_prefix() {
  rm -rf "$MALT_PREFIX"
  mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
  "$BIN" backup -o - >/dev/null 2>&1
  [ -f "$DB" ] || fail "setup: no database created"
}

# Overwrite the table's b-tree pages; the schema stays, so only `step` fails.
corrupt() {
  local ps pg
  ps=$(sqlite3 "$DB" "PRAGMA page_size;")
  for pg in $(sqlite3 "$DB" "SELECT rootpage FROM sqlite_master WHERE tbl_name='$1' AND rootpage>0;"); do
    head -c "$ps" /dev/zero | LC_ALL=C tr '\0' '\377' |
      dd of="$DB" bs="$ps" seek=$((pg - 1)) conv=notrunc 2>/dev/null
  done
}

DB="$MALT_PREFIX/db/malt.db"
fresh_prefix
sqlite3 "$DB" "INSERT INTO bundles(name,manifest_path,created_at,version) VALUES('x',NULL,0,1);
  INSERT INTO bundle_members(bundle_name,kind,ref) VALUES('x','formula','wget');"

# Control: a healthy table exports the member.
out=$("$BIN" bundle export x 2>&1) || fail "control: export failed: $out"
grep -q '"wget"' <<<"$out" || fail "control: healthy export lost wget: $out"

corrupt bundle_members
rc=0
out=$("$BIN" bundle export x 2>"$tmp/err") || rc=$?
[ "$rc" -ne 0 ] || fail "export of an unreadable bundle_members table exited 0: $out"
[ -z "$out" ] || fail "partial manifest on stdout: $out"
grep -q "package database" "$tmp/err" || fail "no worded refusal: $(cat "$tmp/err")"

# Unnamed export reads the installed tables instead.
fresh_prefix
corrupt kegs
rc=0
out=$("$BIN" bundle export 2>"$tmp/err") || rc=$?
[ "$rc" -eq 1 ] || fail "unnamed export over an unreadable kegs table exited $rc: $(cat "$tmp/err")"
[ -z "$out" ] || fail "partial manifest on stdout: $out"
grep -q "package database" "$tmp/err" || fail "no worded refusal: $(cat "$tmp/err")"
if grep -q "DatabaseError" "$tmp/err"; then
  fail "raw error name instead of words: $(cat "$tmp/err")"
fi

echo "  ✓ bundle export refuses a database it cannot read"
