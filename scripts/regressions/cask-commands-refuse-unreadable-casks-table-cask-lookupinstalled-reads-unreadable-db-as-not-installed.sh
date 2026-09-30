#!/usr/bin/env bash
# Regression: a `casks` table malt cannot read must never be read as "no such
# cask". `uninstall <name>` used to fall through to a same-named formula and
# remove it; `uninstall --cask`, `upgrade --cask`, `install --cask` and
# `rollback` called the cask absent, and install would fetch before hitting
# the same table. `uninstall --formula` is the way out and must still work.
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
sqlite3 "$DB" "INSERT INTO casks(token,name,version,url) VALUES('box','Box','1.0','https://e/x.dmg');
  INSERT INTO casks(token,name,version,url) VALUES('solo','Solo','1.0','https://e/s.dmg');
  INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) VALUES('box','box','1.0','abc','$MALT_PREFIX/Cellar/box/1.0');"

# Control: a healthy table resolves the cask when asked for it.
out=$("$BIN" --offline uninstall --cask --dry-run box 2>&1) || fail "control: uninstall --cask --dry-run failed: $out"
grep -q "cask box" <<<"$out" || fail "control: expected the cask: $out"

# Installed-cask artefacts `purge --stale-casks` must never read as orphans.
mkdir -p "$MALT_PREFIX/Caskroom/box/1.0" "$MALT_CACHE/Cask"
: >"$MALT_CACHE/Cask/box-1.0.dmg"

# Overwrite the table's b-tree pages; the schema stays, so only `step` fails.
ps=$(sqlite3 "$DB" "PRAGMA page_size;")
for pg in $(sqlite3 "$DB" "SELECT rootpage FROM sqlite_master WHERE tbl_name='casks' AND rootpage>0;"); do
  head -c "$ps" /dev/zero | LC_ALL=C tr '\0' '\377' |
    dd of="$DB" bs="$ps" seek=$((pg - 1)) conv=notrunc 2>/dev/null
done

# The scope cannot read the table, so purge fails and must keep the cask's files.
rc=0
out=$("$BIN" --offline purge --stale-casks --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "purge --stale-casks exited 0 over an unreadable casks table: $out"
[ -d "$MALT_PREFIX/Caskroom/box/1.0" ] || fail "purge --stale-casks removed an installed cask's Caskroom: $out"
[ -f "$MALT_CACHE/Cask/box-1.0.dmg" ] || fail "purge --stale-casks removed an installed cask's download: $out"
grep -q "casks table" <<<"$out" || fail "purge --stale-casks did not report the table: $out"

for cmd in "uninstall --dry-run box" "uninstall box" "uninstall --cask --dry-run box" \
  "upgrade --cask --dry-run box" "install --cask box" "rollback solo" "reinstall --cask box" \
  "bundle create $tmp/Brewfile"; do
  # shellcheck disable=SC2086 # word-split the subcommand on purpose
  if out=$("$BIN" --offline $cmd 2>&1); then
    fail "'$cmd' exited 0 over an unreadable casks table: $out"
  fi
  grep -q "package database" <<<"$out" || fail "'$cmd' did not report the database: $out"
done

# `--formula` never reads the damaged table, so the formula stays removable.
out=$("$BIN" --offline uninstall --formula --dry-run box 2>&1) || fail "uninstall --formula refused: $out"
grep -q "would uninstall box 1.0" <<<"$out" || fail "uninstall --formula did not preview the formula: $out"

[ -e "$tmp/Brewfile" ] && fail "bundle create wrote a Brewfile without the casks"
[ -d "$MALT_PREFIX/Cellar/box/1.0" ] || fail "same-named formula keg removed"
n=$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='box';")
[ "$n" = 1 ] || fail "same-named formula row removed"

echo "  ✓ cask commands refuse an unreadable casks table"
