#!/usr/bin/env bash
# Regression: a legacy v5-era cask row (with `tap = NULL`) gets its
# owning tap attributed on the first `mt upgrade <token>` so subsequent
# upgrades pre-route directly.
#
# Schema v6 added `casks.tap`. Fresh installs write the owning tap at
# `recordInstall` time, but rows that pre-date v6 stay NULL until the
# upgrade flow exercises the multi-tap fallback probe and the probe's
# success path calls `backfillCaskTap` to attribute the row.
#
# This script simulates a legacy install by UPDATE-ing an existing cask
# row's `tap` back to NULL, runs `mt upgrade`, and asserts:
#   1. `casks.tap` is no longer NULL.
#   2. The recorded tap label matches the install slug's owning tap.
#   3. A second `mt upgrade` emits the version-match skip line —
#      proving pre-routing kicked in instead of the probe loop.
#
# Usage: scripts/regressions/upgrade_tap_cask_legacy_backfill.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3
# on PATH, network access for the seeding install + upgrade fetch.
# macOS only (the cask installer relies on hdiutil / ditto).

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

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

SLUG="yuzeguitarist/deck/deckclip"
TOKEN="${SLUG##*/}"
EXPECTED_TAP="yuzeguitarist/deck"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed|failed to record installed cask" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot exercise backfill"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
pass "${SLUG}: installed"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after install"

installed_version=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
[[ -n "$installed_version" ]] ||
  fail "${TOKEN}: post-install row missing (install exited 0, dispatch contract broken)"
pass "${TOKEN}: post-install casks row present (version='${installed_version}')"

# Verify install wrote the tap automatically (the v6 contract).
post_install_tap=$(sqlite3 "$DB" "SELECT tap FROM casks WHERE token='${TOKEN}';")
[[ "$post_install_tap" == "$EXPECTED_TAP" ]] ||
  fail "${TOKEN}: fresh install should record tap='${EXPECTED_TAP}', got '${post_install_tap}'"
pass "${TOKEN}: fresh install wrote casks.tap='${EXPECTED_TAP}'"

# Simulate a legacy v5-era row: clear the tap column.
sqlite3 "$DB" "UPDATE casks SET tap = NULL WHERE token='${TOKEN}';"
legacy_tap=$(sqlite3 "$DB" "SELECT IFNULL(tap, 'NULL') FROM casks WHERE token='${TOKEN}';")
[[ "$legacy_tap" == "NULL" ]] ||
  fail "${TOKEN}: failed to simulate v5 legacy row (tap=${legacy_tap})"
pass "${TOKEN}: simulated v5 legacy row (tap=NULL)"

# First upgrade after the legacy row exists. The fallback probe must
# find the owning tap and backfill the column.
UP1_LOG="$PREFIX/upgrade1_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s (1st pass — triggers backfill, logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UP1_LOG"
"$BIN" upgrade "$TOKEN" >"$UP1_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$UP1_LOG"; then
  skip "first upgrade hit a classified network condition; cannot assert backfill"
  exit 0
fi

# Assertion: the tap column is now attributed.
backfilled_tap=$(sqlite3 "$DB" "SELECT IFNULL(tap, 'NULL') FROM casks WHERE token='${TOKEN}';")
if [[ "$backfilled_tap" == "NULL" ]]; then
  tail -30 "$UP1_LOG" >&2
  fail "${TOKEN}: backfill did not attribute the tap (still NULL after upgrade)"
fi
[[ "$backfilled_tap" == "$EXPECTED_TAP" ]] ||
  fail "${TOKEN}: backfill wrote wrong tap (got '${backfilled_tap}', expected '${EXPECTED_TAP}')"
pass "${TOKEN}: backfill wrote casks.tap='${EXPECTED_TAP}'"

# Second upgrade — pre-routing must kick in (no fallback probe needed)
# and the version-match path must emit the skip line.
UP2_LOG="$PREFIX/upgrade2_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s (2nd pass — pre-routes via backfilled tap, logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UP2_LOG"
"$BIN" upgrade "$TOKEN" >"$UP2_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$UP2_LOG"; then
  skip "second upgrade hit a classified network condition; cannot assert idempotence"
  exit 0
fi

if ! grep -q "is already at latest version" "$UP2_LOG"; then
  tail -30 "$UP2_LOG" >&2
  fail "${TOKEN}: pre-routed second upgrade did not emit the version-match skip"
fi
pass "${TOKEN}: pre-routed second upgrade emits 'is already at latest version'"

if grep -qE "Downloading|[0-9]+%" "$UP2_LOG"; then
  tail -30 "$UP2_LOG" >&2
  fail "${TOKEN}: pre-routed second upgrade emitted download progress"
fi
pass "${TOKEN}: pre-routed second upgrade skipped any artifact fetch"

printf '\n\xe2\x9c\x94 upgrade-tap-cask legacy-backfill regression passed\n'
