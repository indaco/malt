#!/usr/bin/env bash
# Regression: when a name is installed as both a formula and a cask, `pin`,
# `unpin` and `rollback` must reach the cask with `--cask`, `upgrade` must read
# the cask's own pin, and a bare name must say it picked the formula. The pin
# used to be read and written keg-first, so a pinned cask was upgraded anyway
# and an unpinned one was held back by the formula's pin.
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
mkdir -p "$MALT_PREFIX/db" "$MALT_PREFIX/Cellar/box/1.0/bin" "$MALT_CACHE"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# A first backup materialises the schema so the seed rows have tables.
"$BIN" backup -o - >/dev/null 2>&1
DB="$MALT_PREFIX/db/malt.db"
[ -f "$DB" ] || fail "setup: no database created"
q() { sqlite3 "$DB" "$1"; }
q "INSERT INTO casks(token,name,version,url) VALUES('box','Box','2.0','https://e/x.dmg');
  INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) VALUES('box','box','1.0','abc','$MALT_PREFIX/Cellar/box/1.0');"
# keg pin / cask pin
pins() { echo "$(q "SELECT pinned FROM kegs WHERE name='box'")/$(q "SELECT pinned FROM casks WHERE token='box'")"; }

out=$("$BIN" pin --cask box 2>&1) || fail "pin --cask refused: $out"
[ "$(pins)" = 0/1 ] || fail "pin --cask did not pin only the cask (keg/cask = $(pins))"

out=$("$BIN" unpin --cask box 2>&1) || fail "unpin --cask refused: $out"
[ "$(pins)" = 0/0 ] || fail "unpin --cask did not clear only the cask (keg/cask = $(pins))"

out=$("$BIN" pin box 2>&1) || fail "bare pin failed: $out"
grep -q "Treating box as a formula" <<<"$out" || fail "bare pin: no collision warning: $out"
[ "$(pins)" = 1/0 ] || fail "bare pin did not pin only the formula (keg/cask = $(pins))"

# Offline, an unheld cask stops at its fetch, so only the skip line matters.
out=$("$BIN" --offline upgrade --cask --dry-run box 2>&1 || true)
if grep -q "is pinned, skipped" <<<"$out"; then fail "the formula's pin held the cask: $out"; fi

q "UPDATE kegs SET pinned=0; UPDATE casks SET pinned=1;"
out=$("$BIN" --offline upgrade --cask --dry-run box 2>&1 || true)
grep -q "box is pinned, skipped" <<<"$out" || fail "a pinned cask was not held: $out"

# The cask path's miss line; the keg path's ends "in the store" instead.
out=$("$BIN" rollback --cask --dry-run box 2>&1 || true)
grep -q "No previous version found for box$" <<<"$out" || fail "rollback --cask did not reach the cask: $out"

for v in pin rollback; do
  if out=$("$BIN" "$v" --cask --formula box 2>&1); then fail "$v accepted --cask with --formula"; fi
  grep -q "mutually exclusive" <<<"$out" || fail "$v --cask --formula: $out"
done

"$BIN" info box 2>&1 >/dev/null | grep -q "Treating box as a formula" || fail "bare info: no collision warning"
"$BIN" info --json box 2>/dev/null | python3 -m json.tool >/dev/null || fail "info --json stdout is not JSON"

echo "  ✓ pin, unpin and rollback reach a cask shadowed by a formula, and upgrade reads the cask's own pin"
