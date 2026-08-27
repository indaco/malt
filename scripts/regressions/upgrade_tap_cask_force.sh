#!/usr/bin/env bash
# Regression: `mt upgrade --force <tap-cask>` re-downloads the DMG
# even when the recorded version matches the upstream version.
#
# Companion to `upgrade_tap_cask_idempotent.sh`: that script proves
# the routed path skips when versions match; this one proves the
# `--force` flag is threaded through and bypasses the skip. Easy to
# regress — `upgradeRoutedTapCask`'s version compare is guarded by
# `if (!force and ...)`; a missing `!force` clause would silently
# turn `--force` into a no-op for tap casks.
#
# This script asserts:
#   1. The version-match skip line does NOT surface — `--force` would
#      be a no-op if it did.
#   2. The forced upgrade emits the `Upgrading … -> …` line.
#   3. The forced upgrade reaches the terminal `installed` line.
#   4. The Caskroom directory and `.app` bundle both exist after the
#      forced upgrade — proof the install pipeline completed end-to-end.
#
# The triplet (no-skip + Upgrading + installed) uniquely characterises
# "the routed path took the proceed branch": skipping would emit the
# skip line and never reach Upgrading; an early failure would never
# reach `installed`. `ditto` preserves mtime from the DMG source, so
# a bundle-mtime assertion would be unreliable.
#
# Usage: scripts/regressions/upgrade_tap_cask_force.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, network
# access to GitHub raw + the upstream release host. macOS only.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
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
BUNDLE="Deck.app"
APP_PATH="$PREFIX/Applications/$BUNDLE"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot exercise --force"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
[[ -d "$APP_PATH" ]] || fail "${SLUG}: expected ${APP_PATH} after install"
pass "${SLUG}: installed"

FORCE_LOG="$PREFIX/upgrade_force_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade --force %s (logs \xe2\x86\x92 %s)\n' "$TOKEN" "$FORCE_LOG"
"$BIN" upgrade --force "$TOKEN" >"$FORCE_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$FORCE_LOG"; then
  skip "forced upgrade hit a classified network condition; cannot assert force-bypass"
  exit 0
fi

# Assertion 1: the version-match skip must NOT surface — `--force`
# would be a no-op if it did, exactly the regression we're guarding.
if grep -q "is already at latest version" "$FORCE_LOG"; then
  tail -30 "$FORCE_LOG" >&2
  fail "${TOKEN}: --force was swallowed (version-match skip still emitted)"
fi
pass "${TOKEN}: --force suppressed the version-match skip"

# Assertion 2: the routed-path proceed line surfaces. `output.info`
# prefixes lines with `> `, so the regex tolerates the optional
# decorator and any color/leading whitespace.
if ! grep -qE "Upgrading ${TOKEN} " "$FORCE_LOG"; then
  tail -30 "$FORCE_LOG" >&2
  fail "${TOKEN}: forced upgrade did not enter the upgrade-proceed path"
fi
pass "${TOKEN}: forced upgrade entered the upgrade-proceed path"

# Assertion 3: the terminal `installed` line — the install pipeline
# reached completion, not just the routing setup.
if ! grep -qE "${TOKEN} [^ ]+ installed" "$FORCE_LOG"; then
  tail -30 "$FORCE_LOG" >&2
  fail "${TOKEN}: forced upgrade did not complete an install"
fi
pass "${TOKEN}: forced upgrade reached the 'installed' completion line"

# Assertion 4: bundle + Caskroom both present after the forced
# upgrade. Either being missing means uninstall ran but the
# subsequent install bailed silently.
[[ -d "$APP_PATH" ]] || fail "${TOKEN}: app bundle missing after forced upgrade"
[[ -d "$PREFIX/Caskroom/${TOKEN}" ]] || fail "${TOKEN}: Caskroom missing after forced upgrade"
pass "${TOKEN}: app bundle and Caskroom both present after forced upgrade"

printf '\n\xe2\x9c\x94 upgrade-tap-cask --force regression passed\n'
