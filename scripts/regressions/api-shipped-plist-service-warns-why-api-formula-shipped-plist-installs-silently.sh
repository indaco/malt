#!/usr/bin/env bash
# Regression: a core (JSON API) formula whose `service` object only names
# the launchd label of a plist the formula installs itself must be refused
# for that reason, on a fresh install and on upgrade, exactly like the
# tap / --local path. Before, a fresh install said nothing and an upgrade
# blamed "a service block malt cannot read". Seeds a real install of dbus
# (network only there; one bottle, zero deps), asserts the reason line and
# that no row was registered, then hand-registers the previous version's
# row, rewinds the keg and asserts the upgrade keeps the row and says why.

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

# dbus: zero deps, service object with a `name` and no `run`.
SEED="dbus"
DB="$PREFIX/db/malt.db"
REASON="could not register service for $SEED: formula ships its own plist, which malt does not adopt"

printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed - see $PREFIX/install.log"
pass "$SEED installed"

grep -qF "$REASON" "$PREFIX/install.log" ||
  fail "fresh install did not say why the service was refused"
pass "fresh install reported the refusal reason"

ROW=$(sqlite3 "$DB" "SELECT name FROM services WHERE keg_name='$SEED';")
[[ -z "$ROW" ]] ||
  fail "fresh install registered a service ($ROW)"
pass "no service row registered"

# Seed the registration a previous version would have left behind.
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

grep -qF "$REASON" "$PREFIX/upgrade.log" ||
  fail "upgrade did not say why the service was refused"
pass "upgrade reported the refusal reason"

grep -q "$SEED .*: kept the service registration from the previous version" "$PREFIX/upgrade.log" ||
  fail "upgrade did not say it kept the previous registration"
pass "upgrade reported the kept registration"

if grep -q "cannot read" "$PREFIX/upgrade.log"; then
  fail "upgrade still blames a service block malt cannot read"
fi
pass "upgrade no longer blames a parser gap"

ROW=$(sqlite3 "$DB" "SELECT name FROM services WHERE keg_name='$SEED';")
[[ -n "$ROW" ]] ||
  fail "upgrade retired the previous version's service registration"
pass "upgrade kept the previous version's row"

echo "PASS: a core formula that ships its own plist is refused for that reason"
