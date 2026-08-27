#!/usr/bin/env bash
# Regression: a legacy v5-era cask row (`tap = NULL`) that is behind upstream
# still gets upgraded by a **bulk** `mt upgrade` (no package names).
#
# Why: the legacy-backfill regression covers this row only on the *named* path,
# so a bulk-path regression leaves the suite green. A NULL tap reads as core, so
# this is exactly the row a core-keyed pre-filter can drop — silently, exit 0.
#
# Asserts positively (the recorded version MOVED), never on absence of output,
# so a skipped cask fails loudly.
#
# Usage: scripts/regressions/upgrade-bulk-null-tap-cask.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network for the seeding install + upgrade fetch. macOS only (the cask
# installer relies on hdiutil / ditto).

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
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE CI
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  \xe2\x8a\x98 SKIP: %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

is_network_blip() { grep -qE "rate limit|Network failure|Could not resolve|timed out" "$1"; }

SLUG="yuzeguitarist/deck/deckclip"
TOKEN="${SLUG##*/}"
SEEDED="0.0.0"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (seeding, logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed|failed to record installed cask" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot exercise the bulk path"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
pass "${SLUG}: installed"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after install"

real_version=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
[[ -n "$real_version" ]] ||
  fail "${TOKEN}: post-install row missing (install exited 0, dispatch contract broken)"
pass "${TOKEN}: post-install casks row present (version='${real_version}')"

# Simulate a legacy v5-era row that is also behind upstream: clear the tap and
# rewind the version so the bulk walk has real work to do for this token.
sqlite3 "$DB" "UPDATE casks SET tap = NULL, version = '${SEEDED}' WHERE token='${TOKEN}';"
legacy_tap=$(sqlite3 "$DB" "SELECT IFNULL(tap, 'NULL') FROM casks WHERE token='${TOKEN}';")
[[ "$legacy_tap" == "NULL" ]] ||
  fail "${TOKEN}: failed to simulate v5 legacy row (tap=${legacy_tap})"
pass "${TOKEN}: simulated outdated v5 legacy row (tap=NULL, version=${SEEDED})"

# The run under test: bulk `mt upgrade`, no names — the branch the named-path
# backfill regression never reaches.
UP_LOG="$PREFIX/upgrade_bulk.log"
printf '\xe2\x96\xb8 mt upgrade (bulk, no names — logs \xe2\x86\x92 %s)\n' "$UP_LOG"
set +e
"$BIN" upgrade >"$UP_LOG" 2>&1
up_exit=$?
set -e

if is_network_blip "$UP_LOG"; then
  skip "bulk upgrade hit a classified network condition; cannot assert the walk"
  exit 0
fi

[[ $up_exit -eq 0 ]] || {
  tail -30 "$UP_LOG" >&2
  fail "${TOKEN}: bulk upgrade exited ${up_exit}"
}
pass "bulk upgrade exited 0"

# The invariant: the bulk walk carried the NULL-tap cask through to a real
# upgrade. A pre-filter that drops the row leaves the seeded version in place.
final_version=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
if [[ "$final_version" == "$SEEDED" ]]; then
  tail -30 "$UP_LOG" >&2
  fail "${TOKEN}: bulk upgrade silently skipped the NULL-tap cask (version still ${SEEDED}, exit 0)"
fi
pass "${TOKEN}: bulk upgrade moved the NULL-tap cask off ${SEEDED} (now '${final_version}')"

[[ "$final_version" == "$real_version" ]] ||
  fail "${TOKEN}: bulk upgrade landed '${final_version}', expected upstream '${real_version}'"
pass "${TOKEN}: bulk upgrade landed the upstream version '${real_version}'"

printf '\n\xe2\x9c\x94 upgrade bulk NULL-tap cask regression passed\n'
