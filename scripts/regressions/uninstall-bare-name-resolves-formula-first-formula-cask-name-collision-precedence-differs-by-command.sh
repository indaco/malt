#!/usr/bin/env bash
# Regression: a bare name installed as both a formula and a cask must resolve
# to the formula, as brew does, and `uninstall`, `reinstall` and `upgrade` must
# say so. `uninstall` used to pick the cask silently while `reinstall` and
# `upgrade` picked the formula, so two commands on one name acted on two
# different packages.
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
sqlite3 "$DB" "INSERT INTO casks(token,name,version,url) VALUES('box','Box','2.0','https://e/x.dmg');
  INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) VALUES('box','box','1.0','abc','$MALT_PREFIX/Cellar/box/1.0');"

out=$("$BIN" --offline uninstall --dry-run box 2>&1) || fail "bare uninstall failed: $out"
grep -q "would uninstall box 1.0" <<<"$out" || fail "bare name did not resolve to the formula: $out"
if grep -q "cask box" <<<"$out"; then fail "bare name resolved to the cask: $out"; fi
grep -q "Treating box as a formula" <<<"$out" || fail "uninstall: no collision warning: $out"

out=$("$BIN" --offline uninstall --cask --dry-run box 2>&1) || fail "uninstall --cask failed: $out"
grep -q "cask box 2.0" <<<"$out" || fail "--cask did not select the cask: $out"
if grep -q "Treating" <<<"$out"; then fail "--cask still warned: $out"; fi

out=$("$BIN" --offline uninstall --formula --dry-run box 2>&1) || fail "uninstall --formula failed: $out"
grep -q "would uninstall box 1.0" <<<"$out" || fail "--formula did not select the formula: $out"
if grep -q "Treating" <<<"$out"; then fail "--formula did not silence the warning: $out"; fi

# Offline, both stop at the fetch; the warning comes first, so the exit code is moot.
for v in reinstall upgrade; do
  out=$("$BIN" --offline "$v" --dry-run box 2>&1 || true)
  grep -q "Treating box as a formula" <<<"$out" || fail "$v: no collision warning: $out"
done

rows="$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='box'")$(sqlite3 "$DB" "SELECT count(*) FROM casks WHERE token='box'")"
[ "$rows" = 11 ] || fail "a dry run removed a row (kegs,casks = $rows)"
[ -d "$MALT_PREFIX/Cellar/box/1.0" ] || fail "a dry run removed the keg dir"

echo "  ✓ a bare name that is both a formula and a cask resolves formula-first and warns"
