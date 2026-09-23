#!/usr/bin/env bash
# Regression: `mt purge --unused-deps` reaps a dependency keg nothing needs
# any more. Uninstall stops and unregisters a keg's launchd service before
# tearing down its files; autoremove reached the same kegs by another door
# and dropped only the Cellar dir and the kegs row.
#
# The bug: the services row, the rendered plist under var/malt/services and
# any loaded job survived the keg, so `services list` and `backup` kept
# advertising a service whose binary was gone.
#
# Offline: the prefix is built with sqlite3 - an orphan dependency keg plus
# the service registration an install would have left - and the binary's own
# purge scope does the work.

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

DB="$PREFIX/db/malt.db"
SVC="$PREFIX/var/malt/services/com.malt.dbusd"
# The keeper's label is spelled like the orphan's keg name - the one shape
# that makes a label-keyed teardown retire the wrong keg's service.
KEEP="$PREFIX/var/malt/services/dbusd"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$PREFIX/Cellar/dbusd/1.0/bin" \
  "$PREFIX/Cellar/keeper/1.0/bin" "$SVC" "$KEEP"
printf '#!/bin/sh\nexit 0\n' >"$PREFIX/Cellar/dbusd/1.0/bin/dbusd"
printf '<plist/>' >"$SVC/service.plist"
printf '<plist/>' >"$KEEP/service.plist"

# An orphan dependency keg with the registration its install would have left,
# beside a directly-installed keg whose own service must survive the pass.
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "INSERT INTO kegs(name,full_name,version,revision,store_sha256,cellar_path,install_reason)
  VALUES('dbusd','dbusd','1.0',0,'sha','$PREFIX/Cellar/dbusd/1.0','dependency'),
        ('keeper','keeper','1.0',0,'sha','$PREFIX/Cellar/keeper/1.0','direct');
  INSERT INTO services(name,keg_name,plist_path,auto_start,last_status)
  VALUES('com.malt.dbusd','dbusd','$SVC/service.plist',1,'registered'),
        ('dbusd','keeper','$KEEP/service.plist',1,'registered');" ||
  fail "could not seed the orphan keg and its service row"
pass "orphan dependency keg seeded beside a still-installed keg's service"

"$BIN" backup --services -o - >"$PREFIX/before.txt" 2>/dev/null ||
  fail "backup failed before the purge"
grep -q '^service com.malt.dbusd$' "$PREFIX/before.txt" ||
  fail "backup did not carry the orphan's service before the purge"
pass "backup carried the orphan's service before the purge"

"$BIN" purge --unused-deps --yes >"$PREFIX/purge.log" 2>&1 || {
  tail -20 "$PREFIX/purge.log" >&2
  fail "purge --unused-deps failed"
}
[[ -z $(sqlite3 "$DB" "SELECT 1 FROM kegs WHERE name='dbusd';") ]] ||
  fail "the orphan keg was not removed - the fixture no longer reproduces the scenario"
pass "orphan keg removed"

[[ -z $(sqlite3 "$DB" "SELECT name FROM services WHERE keg_name='dbusd';") ]] ||
  fail "the removed keg's service row survived autoremove"
pass "service row retired with the keg"

[[ ! -e "$SVC" ]] ||
  fail "the removed keg's plist directory survived at $SVC"
pass "rendered plist directory removed"

[[ -n $(sqlite3 "$DB" "SELECT name FROM services WHERE keg_name='keeper';") ]] ||
  fail "the still-installed keg's service row was retired too"
[[ -e "$KEEP/service.plist" ]] ||
  fail "the still-installed keg's rendered plist was deleted"
pass "the still-installed keg kept its service"

"$BIN" backup --services -o - >"$PREFIX/after.txt" 2>/dev/null ||
  fail "backup failed after the purge"
! grep -q '^service com.malt.dbusd$' "$PREFIX/after.txt" ||
  fail "backup still offers the removed keg's service"
pass "backup no longer offers the removed keg's service"

echo "PASS: autoremove retires the service registration of the orphan it removes"
