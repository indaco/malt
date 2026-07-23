#!/usr/bin/env bash
# Regression: `mt upgrade <tap-cask>` announces a backward version move and
# still performs it — the cask twin of upgrade-backward-move-warns.sh.
#
# The warning is emitted from a shared helper at all three version-compare
# sites; the formula site is proven elsewhere. This pins the routed tap-cask
# site (`upgradeRoutedTapCask`), reached when a tap cask's recorded version
# reads as newer than upstream. Casks mostly land in the comparator's
# `incomparable` arm (no warning), so we force a provable backward move by
# rewinding the recorded version to one that outranks any real upstream.
#
# Asserts BOTH halves — the warning appeared AND the cask walked back to the
# upstream version — because a warning that also blocked is the failure this
# feature exists to avoid.
#
# Usage: scripts/regressions/upgrade-tap-cask-backward-move-warns.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network access to GitHub raw + the upstream release host. macOS only.

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
PREFIX="/tmp/mt_cbwd"
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

is_network_blip() { grep -qiE "rate limit|Network failure|Could not resolve|timed out|Failed to (install|download)|Sha256Mismatch|DownloadFailed|Tap formula/cask not found" "$1"; }

# A stable third-party tap cask malt is known to install (shared with
# upgrade_tap_cask_force.sh).
SLUG="yuzeguitarist/deck/deckclip"
TOKEN="${SLUG##*/}"
BUNDLE="Deck.app"
APP_PATH="$PREFIX/Applications/$BUNDLE"
DB="$PREFIX/db/malt.db"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if is_network_blip "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
[[ -d "$APP_PATH" ]] || fail "${SLUG}: expected ${APP_PATH} after install"
[[ -f "$DB" ]] || fail "expected DB at $DB after install"

UPSTREAM=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
[[ -n "$UPSTREAM" ]] || fail "${TOKEN}: post-install casks row missing"
pass "${TOKEN}: installed at upstream version '${UPSTREAM}'"

# Rewind the recorded version so the next upgrade is a provable backward
# move. '9999.0' outranks every real first component.
FAKE="9999.0"
sqlite3 "$DB" "UPDATE casks SET version='${FAKE}' WHERE token='${TOKEN}';"

UP_LOG="$PREFIX/upgrade_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s over a rewound version (logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UP_LOG"
"$BIN" upgrade "$TOKEN" >"$UP_LOG" 2>&1 || {
  if is_network_blip "$UP_LOG"; then
    skip "upgrade hit a classified network condition; cannot assert the move"
    exit 0
  fi
  tail -30 "$UP_LOG" >&2
  fail "${TOKEN}: upgrade exited non-zero over a backward move"
}

grep -qi "moving backward" "$UP_LOG" ||
  fail "${TOKEN}: no backward-move warning printed"
grep -q "$FAKE" "$UP_LOG" || fail "${TOKEN}: warning did not name installed '${FAKE}'"
grep -q "$UPSTREAM" "$UP_LOG" || fail "${TOKEN}: warning did not name upstream '${UPSTREAM}'"
grep -qi "rollback" "$UP_LOG" || fail "${TOKEN}: warning did not point at 'mt rollback'"
pass "${TOKEN}: backward move announced, naming both versions and the undo"

# The move actually happened: the cask is back at upstream, not stuck at FAKE.
NOW=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
[[ "$NOW" == "$UPSTREAM" ]] ||
  fail "${TOKEN}: cask is at '${NOW}', expected upstream '${UPSTREAM}' — the warning blocked the move"
[[ -d "$APP_PATH" ]] || fail "${TOKEN}: app bundle missing after the backward move"
pass "${TOKEN}: cask walked back to upstream '${UPSTREAM}' (warned, not blocked)"

printf '\n\xe2\x9c\x94 upgrade tap-cask backward-move warning regression passed\n'
