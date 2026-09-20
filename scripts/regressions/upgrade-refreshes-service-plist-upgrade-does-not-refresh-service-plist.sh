#!/usr/bin/env bash
# Regression: `mt upgrade` must regenerate a formula's launchd plist from
# the new version's service block, and it must not reset the services
# row's user-intent columns (auto_start, last_status) while doing so.
#
# The bug: the def -> ServiceSpec bridge lived only on the install path,
# so an upgrade swapped the keg and left the plist frozen at whatever the
# formula said at first install (argv, ExitTimeOut, KeepAlive, schedule).
# The naive fix - re-running register - would have reset auto_start via
# INSERT OR REPLACE, which is why this script checks both halves.
#
# Seeds a real install of a dependency-free service formula, poisons the
# registered plist and the row's user-intent columns, rewinds the keg row
# so upgrade sees a version bump, and asserts the plist was rewritten and
# the columns survived. Needs network for the seeding install (same
# contract as the other upgrade regressions).

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

# dnsmasq: zero deps, one service block whose argv carries a stable flag.
SEED="dnsmasq"
DB="$PREFIX/db/malt.db"

printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed - see $PREFIX/install.log"
PLIST=$(sqlite3 "$DB" "SELECT plist_path FROM services WHERE keg_name='$SEED';")
[[ -f "$PLIST" ]] || fail "install did not register a service plist for $SEED"
grep -q -- '--keep-in-foreground' "$PLIST" ||
  fail "seed plist lacks the expected argv - has the upstream service block changed?"
pass "$SEED installed with its service registered"

# Make staleness observable: poison the argv on disk and flip the row's
# user-intent columns to values only a user (or a running job) would set.
sed -i '' 's#--keep-in-foreground#--STALE-MARKER#' "$PLIST"
sqlite3 "$DB" "UPDATE services SET auto_start=1, last_status='running' WHERE keg_name='$SEED';" ||
  fail "could not poison the services row"

# Rewind the keg row and move the cellar dir to match, so the upgrade
# path sees a genuine version bump.
NEW_DIR=$(basename "$(find "$PREFIX/Cellar/$SEED" -mindepth 1 -maxdepth 1 -type d | head -1)")
mv "$PREFIX/Cellar/$SEED/$NEW_DIR" "$PREFIX/Cellar/$SEED/0.1"
sqlite3 "$DB" "UPDATE kegs SET version='0.1', revision=0, store_sha256='',
  cellar_path='$PREFIX/Cellar/$SEED/0.1' WHERE name='$SEED';" ||
  fail "could not rewind the keg row"
pass "plist poisoned, row flipped, keg rewound to 0.1"

"$BIN" upgrade "$SEED" >"$PREFIX/upgrade.log" 2>&1 || {
  cat "$PREFIX/upgrade.log" >&2
  fail "upgrade failed"
}

if grep -q STALE-MARKER "$PLIST"; then
  fail "upgrade left the service plist untouched"
fi
grep -q -- '--keep-in-foreground' "$PLIST" ||
  fail "regenerated plist lost the formula argv"
pass "upgrade regenerated the service plist"

ROW=$(sqlite3 "$DB" "SELECT auto_start||'/'||last_status FROM services WHERE keg_name='$SEED';")
[[ "$ROW" == "1/running" ]] ||
  fail "upgrade reset the services row's user-intent columns (got '$ROW', want '1/running')"
pass "auto_start and last_status survived the upgrade"

echo "PASS: upgrade regenerates the service plist and keeps auto_start/last_status"
