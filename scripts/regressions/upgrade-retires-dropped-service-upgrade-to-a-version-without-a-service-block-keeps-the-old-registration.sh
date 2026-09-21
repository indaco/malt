#!/usr/bin/env bash
# Regression: `mt upgrade` to a version that no longer declares a service
# block must retire the row and plist the previous version registered, and
# say so. Seeds a real install of a service-less formula (network only
# there), hand-registers the row + plist as the previous version would have,
# rewinds the keg so upgrade sees a bump, and asserts both are gone. The
# loaded-job arm (warn and keep) is covered by inline tests; bootstrapping a
# real launchd job here is not worth the flake.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# tree: zero deps, no service block.
SEED="tree"
DB="$PREFIX/db/malt.db"

printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed - see $PREFIX/install.log"
pass "$SEED installed"

# Seed the registration the previous version would have left behind.
SVC="$PREFIX/var/malt/services/com.malt.$SEED"
mkdir -p "$SVC"
printf '<plist/>' >"$SVC/service.plist"
sqlite3 "$DB" "INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
  VALUES('com.malt.$SEED', '$SEED', '$SVC/service.plist', 0, 'registered');" ||
  fail "could not seed the services row"

# Rewind the keg row and move the cellar dir to match, so the upgrade
# path sees a genuine version bump.
NEW_DIR=$(basename "$(find "$PREFIX/Cellar/$SEED" -mindepth 1 -maxdepth 1 -type d | head -1)")
mv "$PREFIX/Cellar/$SEED/$NEW_DIR" "$PREFIX/Cellar/$SEED/0.1"
sqlite3 "$DB" "UPDATE kegs SET version='0.1', revision=0, store_sha256='',
  cellar_path='$PREFIX/Cellar/$SEED/0.1' WHERE name='$SEED';" ||
  fail "could not rewind the keg row"
pass "previous-version service seeded, keg rewound to 0.1"

"$BIN" upgrade "$SEED" >"$PREFIX/upgrade.log" 2>&1 || {
  cat "$PREFIX/upgrade.log" >&2
  fail "upgrade failed"
}

ROW=$(sqlite3 "$DB" "SELECT name FROM services WHERE keg_name='$SEED';")
[[ -z "$ROW" ]] ||
  fail "upgrade kept the previous version's service registration ($ROW)"
pass "upgrade retired the stale services row"

[[ ! -e "$SVC" ]] ||
  fail "upgrade left the previous version's plist directory on disk ($SVC)"
pass "upgrade removed the stale plist directory"

grep -q "declares no service" "$PREFIX/upgrade.log" ||
  fail "upgrade retired the row silently"
pass "upgrade reported the retirement"

echo "PASS: upgrade retires a service registration the new version no longer declares"
