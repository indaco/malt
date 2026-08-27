#!/usr/bin/env bash
# Regression: a **bulk** `mt upgrade` (no package names) still refreshes a tap
# formula whose upstream HEAD moved while its version constant did not.
#
# Why: the tap path decides by HEAD sha, not by the `.rb` version, so sha-truth
# and version-truth disagree for exactly this row. Anything pre-filtering the
# bulk walk on version equality reads the keg current and drops it — "up to
# date", exit 0, unnoticed. The taint regression covers only the dry-run warm,
# where omitting the row is the correct answer, so it cannot catch this.
#
# Asserts positively (footer reports UPGRADED; tap sha advanced off the forced
# value), never on absence of output, so a skipped keg fails loudly.
#
# Usage: scripts/regressions/upgrade-bulk-tap-formula-head-move.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network access to the tap HEAD + its `.rb`.

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

# A stable third-party tap whose formula malt is known to fetch + parse
# (URL-derived version, proven by tap_formula_url_version.sh).
TAP="aeroxy/tap"
NAME="ast-outline"
FORCED_SHA="0000000000000000000000000000000000000000"

TAP_LOG="$PREFIX/tap.log"
if ! "$BIN" tap "$TAP" >"$TAP_LOG" 2>&1; then
  if is_network_blip "$TAP_LOG"; then
    skip "${TAP}: tap registration hit a classified network condition"
    exit 0
  fi
  tail -20 "$TAP_LOG" >&2
  fail "${TAP}: tap registration failed for an unclassified reason"
fi

INSTALL_LOG="$PREFIX/install_${NAME}.log"
printf '\xe2\x96\xb8 mt install %s/%s (seeding, logs \xe2\x86\x92 %s)\n' "$TAP" "$NAME" "$INSTALL_LOG"
if ! "$BIN" install "${TAP}/${NAME}" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed" "$INSTALL_LOG"; then
    skip "${NAME}: install hit a classified upstream condition; cannot exercise the bulk path"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${NAME}: install failed for an unclassified reason"
fi
pass "${TAP}/${NAME}: installed"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after install"

V=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ -n "$V" ]] ||
  fail "${NAME}: post-install keg row missing (install exited 0, dispatch contract broken)"
pass "${NAME}: post-install keg row present (version='${V}')"

# The keg is freshly installed, so installed version == upstream version. That
# is the precondition: version-truth says current, sha-truth must still refresh.
pass "${NAME}: version-current by construction (installed == upstream == '${V}')"

# Force the tap HEAD to look moved. Bogus cached sha so the real HEAD differs;
# stale etag so the conditional GET returns 200 (a fresh real sha) instead of
# 304 (which would fall back to the bogus cached sha and read as unchanged).
sqlite3 "$DB" "UPDATE taps SET commit_sha='${FORCED_SHA}', head_etag='W/\"stale-force-200\"' WHERE name='${TAP}';"
pass "${TAP}: forced a HEAD move (cached sha rewound, etag staled)"

# The run under test: bulk `mt upgrade`, no names.
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
  fail "bulk upgrade exited ${up_exit}"
}
pass "bulk upgrade exited 0"

# Bulk mode folds per-package outcomes into one summary footer, so the footer is
# the per-package observable here. Sha-truth must land this keg in `upgraded`.
FOOTER=$(grep -E '[0-9]+ checked' "$UP_LOG" | tail -1)
[[ -n "$FOOTER" ]] || {
  tail -30 "$UP_LOG" >&2
  fail "bulk upgrade printed no summary footer; cannot read the walk outcome"
}

upgraded=$(printf '%s' "$FOOTER" | grep -oE '[0-9]+ upgraded' | grep -oE '^[0-9]+')
uptodate=$(printf '%s' "$FOOTER" | grep -oE '[0-9]+ up to date' | grep -oE '^[0-9]+')
[[ -n "$upgraded" && -n "$uptodate" ]] || fail "could not parse footer: '${FOOTER}'"

# The invariant: sha moved → refresh. A version-truth pre-filter reports the keg
# current instead, which is the silent-at-exit-0 failure this guards.
[[ "$uptodate" -eq 0 ]] ||
  fail "${NAME}: bulk upgrade reported ${uptodate} keg(s) 'up to date' after a HEAD move — sha-truth lost to version-truth ('${FOOTER}')"
[[ "$upgraded" -ge 1 ]] ||
  fail "${NAME}: bulk upgrade refreshed nothing after a HEAD move ('${FOOTER}')"
pass "${NAME}: bulk upgrade re-materialised the keg on a sha-only move ('${FOOTER}')"

# The HEAD fetch really resolved: the forced sha was replaced by a real one.
final_sha=$(sqlite3 "$DB" "SELECT commit_sha FROM taps WHERE name='${TAP}';")
[[ "$final_sha" != "$FORCED_SHA" ]] ||
  fail "${TAP}: cached sha still the forced value — the HEAD fetch never resolved"
pass "${TAP}: cached sha advanced off the forced value"

# Sha-truth refresh, not a version bump: the keg stays at the same version.
final_v=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ "$final_v" == "$V" ]] ||
  fail "${NAME}: version moved '${V}' -> '${final_v}'; fixture no longer pins a sha-only move"
pass "${NAME}: keg still at '${V}' (a sha-only move, as the fixture intends)"

printf '\n\xe2\x9c\x94 upgrade bulk tap-formula HEAD-move regression passed\n'
