#!/usr/bin/env bash
# Regression: `mt upgrade` against a tap-installed cask is idempotent —
# a second invocation with no upstream change MUST NOT re-download the
# DMG.
#
# Pre-fix, `upgradeTapCaskFallback` called `installTapFormula` with a
# hardcoded `force = true`, bypassing every "already installed" guard
# downstream. The user-visible effect: every `mt upgrade <tap-cask>`
# fetched the full DMG, mounted it, and copied the app bundle, even
# when nothing had changed.
#
# Root cause: the `casks` table had no `tap` column, so the upgrade
# entry point couldn't pre-route by ownership the way `upgradeFormula`
# does for `kegs.tap`. The fix adds the column (schema v5 → v6),
# records the owning tap on install / on first fallback probe, and
# pre-routes to `upgradeRoutedTapCask` whenever it's known. The routed
# path fetches the tap's `Casks/<token>.rb`, compares versions, and
# short-circuits with `is already at latest version` before any DMG
# fetch starts.
#
# This script asserts the second consecutive upgrade:
#   1. Emits the version-match skip line.
#   2. Does NOT print the `Upgrading … -> …` line (that only fires
#      when the routed path proceeds past the skip).
#   3. Does NOT mention `Downloading` / a percentage progress marker
#      (no DMG fetch happened).
#   4. Leaves the installed app bundle's mtime unchanged across the
#      two invocations.
#
# Usage: scripts/regressions/upgrade_tap_cask_idempotent.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, network
# access to GitHub raw + the upstream release host. macOS only.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_upidem"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# A third-party tap cask shipping a DMG. Same candidate as
# tap_cask_dmg_gh136.sh — keeping the surface stable across regressions
# minimises external flakiness.
SLUG="yuzeguitarist/deck/deckclip"
TOKEN="${SLUG##*/}"
BUNDLE="Deck.app"
APP_PATH="$PREFIX/Applications/$BUNDLE"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot assert idempotence"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
[[ -d "$APP_PATH" ]] || fail "${SLUG}: expected ${APP_PATH} after install"
pass "${SLUG}: installed"

# Snapshot mtime before the first upgrade. macOS `stat -f %m` returns
# the unix epoch seconds for the directory's mtime — stable across
# read-only `mt upgrade` invocations.
mtime_before=$(stat -f %m "$APP_PATH" 2>/dev/null || stat -c %Y "$APP_PATH")

# ── First upgrade ───────────────────────────────────────────────────
#
# Tolerated outcomes: either the version matches (the typical case
# since we just installed) and we get the skip line, OR the upstream
# tap has bumped between our install and this upgrade (rare but
# possible) and we get an actual upgrade. Both are fine — the assertion
# we care about is the SECOND upgrade being a no-op.
UP1_LOG="$PREFIX/upgrade1_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s (1st pass, logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UP1_LOG"
"$BIN" upgrade "$TOKEN" >"$UP1_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$UP1_LOG"; then
  skip "first upgrade hit a classified network condition; cannot assert idempotence"
  exit 0
fi

# ── Second upgrade (the idempotence assertion) ──────────────────────
UP2_LOG="$PREFIX/upgrade2_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s (2nd pass, logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UP2_LOG"
"$BIN" upgrade "$TOKEN" >"$UP2_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$UP2_LOG"; then
  skip "second upgrade hit a classified network condition; cannot assert idempotence"
  exit 0
fi

# Assertion 1: skip line must surface.
if ! grep -q "is already at latest version" "$UP2_LOG"; then
  tail -30 "$UP2_LOG" >&2
  fail "${TOKEN}: second upgrade did not emit the version-match skip"
fi
pass "${TOKEN}: second upgrade emits 'is already at latest version'"

# Assertion 2: routed-path proceed line must NOT surface.
if grep -qE "^Upgrading ${TOKEN} " "$UP2_LOG"; then
  tail -30 "$UP2_LOG" >&2
  fail "${TOKEN}: second upgrade proceeded past the skip"
fi
pass "${TOKEN}: second upgrade did not start an upgrade run"

# Assertion 3: no DMG download markers. The progress bar prints `%`
# lines via the bar renderer, and the cask installer also writes
# "Downloading" before any large fetch.
if grep -qE "Downloading|[0-9]+%" "$UP2_LOG"; then
  tail -30 "$UP2_LOG" >&2
  fail "${TOKEN}: second upgrade printed a download progress marker"
fi
pass "${TOKEN}: second upgrade did not emit download progress"

# Assertion 4: the installed bundle's mtime is untouched.
mtime_after=$(stat -f %m "$APP_PATH" 2>/dev/null || stat -c %Y "$APP_PATH")
if [[ "$mtime_before" != "$mtime_after" ]]; then
  printf '   before=%s after=%s\n' "$mtime_before" "$mtime_after" >&2
  fail "${TOKEN}: app bundle mtime changed across upgrades"
fi
pass "${TOKEN}: app bundle mtime unchanged across two upgrades"

printf '\n\xe2\x9c\x94 upgrade-tap-cask-idempotent regression passed\n'
