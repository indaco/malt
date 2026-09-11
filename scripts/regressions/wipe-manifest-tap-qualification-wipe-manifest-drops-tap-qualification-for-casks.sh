#!/usr/bin/env bash
# Regression: the wipe manifest is the one backup guaranteed to be needed, so
# it must carry exactly the rows `mt backup` writes. `purge --wipe --backup`
# used to dump casks as bare tokens (losing the `<tap>/` prefix that lets
# `mt restore` reach a third-party tap) and dropped auto-start services
# entirely - and the drift only surfaced after the prefix was gone.
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

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

P="$tmp/prefix"
mkdir -p "$P/db" "$P/Cellar"
: >"$P/Cellar/marker"
# A first backup materialises the schema so the seed rows have tables.
MALT_PREFIX="$P" "$BIN" backup -o - >/dev/null 2>&1
sqlite3 "$P/db/malt.db" "
  INSERT INTO casks (token, name, version, url, tap) VALUES
    ('foo', 'Foo', '1.0', 'https://x/foo.dmg', 'acme/tools'),
    ('bar', 'Bar', '2.0', 'https://x/bar.dmg', 'homebrew/cask');
  INSERT INTO services (name, keg_name, plist_path, auto_start)
    VALUES ('svc', 'svc', '/svc.plist', 1);"

MALT_PREFIX="$P" "$BIN" backup --versions --services -o "$tmp/b.txt" >/dev/null 2>&1 ||
  fail "mt backup failed on the seeded prefix"
MALT_PREFIX="$P" "$BIN" purge --wipe --backup="$tmp/m.txt" --yes >/dev/null 2>&1 ||
  fail "wipe failed on the seeded prefix"

grep -q '^cask acme/tools/foo@1.0$' "$tmp/m.txt" ||
  fail "wipe manifest lost tap qualification for a third-party cask"
grep -q '^cask bar@2.0$' "$tmp/m.txt" || fail "core cask must stay bare"
grep -q '^service svc$' "$tmp/m.txt" || fail "wipe manifest dropped an auto-start service"
diff <(grep -E '^(cask|service|formula) ' "$tmp/b.txt") \
  <(grep -E '^(cask|service|formula) ' "$tmp/m.txt") ||
  fail "wipe manifest diverges from mt backup"

printf '  ✓ wipe manifest matches mt backup, including tap-qualified casks and services\n'
