#!/usr/bin/env bash
# Regression: `mt upgrade` announces a backward version move and still
# performs it.
#
# `mt upgrade` follows the tap: when upstream moves backward (a yanked
# release), it walks the keg down. That is intended — `mt rollback` makes it
# cheap to undo — but it used to happen silently, visible only in a dry run
# nobody reads. The move is now announced, with both versions named and
# `mt rollback` pointed at as the undo. It is a warning, not a refusal.
#
# Fixture: install a real formula, then rewind its recorded version to a
# value the comparator reads as strictly newer than upstream. The next
# `mt upgrade` therefore sees a backward move. We assert BOTH halves — the
# warning appeared AND the keg was upgraded to the upstream version — because
# a warning that also blocked would be the failure this feature exists to
# avoid. A second run under `--force` pins that the flag did not become a
# consent gate: the warning is identical with or without it.
#
# Usage: scripts/regressions/upgrade-backward-move-warns.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network access for the seeding install and the upgrade's API fetch.

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

# MALT_PREFIX kept short (Mach-O in-place patching budget).
PREFIX="/tmp/mt_bwd"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE CI
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  \xe2\x8a\x98 SKIP: %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

is_network_blip() { grep -qiE "rate limit|Network failure|Could not resolve|timed out|No bottle available|Could not fetch" "$1"; }

# Light formula: no deps, lands fast, has a stable bottle.
NAME="${NAME:-tree}"
DB="$PREFIX/db/malt.db"

INSTALL_LOG="$PREFIX/install.log"
printf '\xe2\x96\xb8 seeding with mt install %s (logs \xe2\x86\x92 %s)\n' "$NAME" "$INSTALL_LOG"
if ! "$BIN" install "$NAME" >"$INSTALL_LOG" 2>&1; then
  if is_network_blip "$INSTALL_LOG"; then
    skip "$NAME: seed install hit a classified network condition"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "$NAME: seed install failed for an unclassified reason"
fi
[[ -f "$DB" ]] || fail "expected DB at $DB after install"

UPSTREAM=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ -n "$UPSTREAM" ]] || fail "$NAME: post-install keg row missing"
pass "$NAME installed at upstream version '${UPSTREAM}'"

# Rewind the recorded version to one that reads as strictly newer than any
# real upstream, so the next upgrade is a provable backward move. `9999` as
# the leading numeric run outranks every real first component.
FAKE="9999.0"
run_backward() {
  local log="$1"
  shift
  sqlite3 "$DB" "UPDATE kegs SET version='${FAKE}' WHERE name='${NAME}';"
  set +e
  "$BIN" upgrade "$@" "$NAME" >"$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

# --- 0. Dry run over a backward move: warns, changes nothing -----------
DRY_LOG="$PREFIX/upgrade_dry.log"
printf '\xe2\x96\xb8 mt upgrade --dry-run %s over a rewound version (logs \xe2\x86\x92 %s)\n' "$NAME" "$DRY_LOG"
run_backward "$DRY_LOG" --dry-run || {
  if is_network_blip "$DRY_LOG"; then
    skip "dry-run hit a classified network condition"
    exit 0
  fi
  tail -30 "$DRY_LOG" >&2
  fail "$NAME: dry-run exited non-zero over a backward move"
}
grep -qi "moving backward" "$DRY_LOG" || fail "$NAME: --dry-run did not warn on a backward move"
DRY_NOW=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ "$DRY_NOW" == "$FAKE" ]] ||
  fail "$NAME: --dry-run changed the keg version ('${DRY_NOW}') — dry run must not upgrade"
pass "$NAME: --dry-run warns and leaves the keg untouched"

# --- 1. Plain backward move: warns AND upgrades ------------------------
UP_LOG="$PREFIX/upgrade.log"
printf '\xe2\x96\xb8 mt upgrade %s over a rewound version (logs \xe2\x86\x92 %s)\n' "$NAME" "$UP_LOG"
run_backward "$UP_LOG" || {
  if is_network_blip "$UP_LOG"; then
    skip "upgrade hit a classified network condition; cannot assert the move"
    exit 0
  fi
  tail -30 "$UP_LOG" >&2
  fail "$NAME: upgrade exited non-zero over a backward move"
}
pass "$NAME: upgrade exited 0 over a backward move"

grep -qi "moving backward" "$UP_LOG" ||
  fail "$NAME: no backward-move warning printed ('$(grep -i backward "$UP_LOG" || true)')"
grep -q "$FAKE" "$UP_LOG" || fail "$NAME: warning did not name the installed version '${FAKE}'"
grep -q "$UPSTREAM" "$UP_LOG" || fail "$NAME: warning did not name the upstream version '${UPSTREAM}'"
grep -qi "rollback" "$UP_LOG" || fail "$NAME: warning did not point at 'mt rollback'"
pass "$NAME: backward move announced, naming both versions and the undo"

# The move actually happened: the keg is back at upstream, not stuck at FAKE.
NOW=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ "$NOW" == "$UPSTREAM" ]] ||
  fail "$NAME: keg is at '${NOW}', expected upstream '${UPSTREAM}' — the warning blocked the move"
pass "$NAME: keg walked back to upstream '${UPSTREAM}' (warned, not blocked)"

# --- 2. Same move under --force: warning is unchanged ------------------
# Pins that --force was not overloaded into a downgrade-consent gate.
FORCE_LOG="$PREFIX/upgrade_force.log"
printf '\xe2\x96\xb8 mt upgrade --force %s over a rewound version (logs \xe2\x86\x92 %s)\n' "$NAME" "$FORCE_LOG"
run_backward "$FORCE_LOG" --force || {
  if is_network_blip "$FORCE_LOG"; then
    skip "forced upgrade hit a classified network condition"
    exit 0
  fi
  tail -30 "$FORCE_LOG" >&2
  fail "$NAME: forced upgrade exited non-zero over a backward move"
}
grep -qi "moving backward" "$FORCE_LOG" ||
  fail "$NAME: --force suppressed the backward-move warning"
pass "$NAME: --force leaves the warning intact (not a consent gate)"

printf '\n\xe2\x9c\x94 upgrade backward-move warning regression passed\n'
