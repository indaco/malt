#!/usr/bin/env bash
# Regression: a core (JSON API) formula whose `service` object only names
# the launchd label of a plist the formula installs itself gets a malt
# service lifted from that plist, on a fresh install and on upgrade,
# exactly like the tap / --local path. Before, a fresh install said
# nothing and registered nothing, and an upgrade blamed "a service block
# malt cannot read". Seeds a real install of dbus (network only there;
# one bottle, zero deps, a `SecureSocketWithKey` socket), asserts the row
# and the rendered plist, then hand-registers the previous version's row,
# rewinds the keg and asserts the upgrade re-registers without complaint.

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
# Keeps the developer's own service .env files out of the plist asserts.
export XDG_CONFIG_HOME="$PREFIX/xdg"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# dbus: zero deps, service object with a `name` and no `run`.
SEED="dbus"
DB="$PREFIX/db/malt.db"
SVC="$PREFIX/var/malt/services/com.malt.$SEED"

printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed - see $PREFIX/install.log"
pass "$SEED installed"

! grep -q "could not register service for $SEED" "$PREFIX/install.log" ||
  fail "fresh install refused the shipped plist: $(grep "could not register service" "$PREFIX/install.log")"
pass "fresh install did not refuse the shipped plist"

ROW=$(sqlite3 "$DB" "SELECT plist_path FROM services WHERE keg_name='$SEED';")
[[ "$ROW" == "$SVC/service.plist" ]] ||
  fail "fresh install registered no malt-rendered service (row: '$ROW')"
grep -q "<string>$PREFIX/opt/$SEED/bin/dbus-daemon</string>" "$SVC/service.plist" ||
  fail "rendered ProgramArguments[0] is not the keg's opt path"
grep -q '<key>SecureSocketWithKey</key>' "$SVC/service.plist" ||
  fail "the session bus socket was not carried into the rendered plist"
grep -q '<string>com.malt.dbus</string>' "$SVC/service.plist" ||
  fail "rendered plist does not carry malt's own label"
pass "service lifted from the shipped plist"

# Replace the registration with what a previous version left behind.
printf '<plist/>' >"$SVC/service.plist"
sqlite3 "$DB" "UPDATE services SET last_status='registered', schedule='stale' WHERE keg_name='$SEED';" ||
  fail "could not age the services row"

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

! grep -q "could not register service for $SEED" "$PREFIX/upgrade.log" ||
  fail "upgrade refused the shipped plist: $(grep "could not register service" "$PREFIX/upgrade.log")"
if grep -q "cannot read" "$PREFIX/upgrade.log"; then
  fail "upgrade still blames a service block malt cannot read"
fi
pass "upgrade did not refuse the shipped plist"

grep -q '<key>SecureSocketWithKey</key>' "$SVC/service.plist" ||
  fail "upgrade did not re-render the previous version's plist"
SCHED=$(sqlite3 "$DB" "SELECT schedule FROM services WHERE keg_name='$SEED';")
[[ "$SCHED" != "stale" ]] ||
  fail "upgrade did not refresh the previous version's row"
pass "upgrade re-registered the service from the new keg's plist"

echo "PASS: a core formula that ships its own plist gets a malt service lifted from it"
