#!/usr/bin/env bash
# Regression: `mt backup` round-trips the owning tap on third-party
# cask rows so `mt restore` reinstalls from the right tap.
#
# Pre-fix, `backup.zig` SELECTed `token, version` only. A tap cask
# (e.g. `yuzeguitarist/deck/deckclip`) wrote out as `cask deckclip` —
# losing the `yuzeguitarist/deck` ownership. On restore that bare
# token went through `mt install --cask deckclip`, hit the core
# Homebrew API, 404'd, and the package failed to re-install.
#
# The fix joins `casks.tap` into the SELECT and writes the qualified
# slug form `cask <user>/<repo>/<token>` for tap casks. The shape is
# the same one `mt install <user>/<repo>/<token>` already routes
# through `installTapFormula`, so no restore-side changes are needed.
#
# This script asserts the full round-trip:
#   1. Install a tap cask.
#   2. Run `mt backup` and verify the line carries the slug shape.
#   3. Uninstall the cask.
#   4. Run `mt restore <file>` and verify the cask is re-installed
#      from the owning tap (Caskroom directory present, casks.tap
#      reattributed).
#
# Usage: scripts/regressions/backup_restore_tap_cask.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3
# on PATH, network access. macOS only.

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
SNAP="$PREFIX/snap.txt"

# ── Install ────────────────────────────────────────────────────────
INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot exercise round-trip"
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
pass "${SLUG}: installed"

# ── Backup ─────────────────────────────────────────────────────────
BACKUP_LOG="$PREFIX/backup.log"
"$BIN" backup --output "$SNAP" >"$BACKUP_LOG" 2>&1 ||
  fail "backup command failed: $(tail -5 "$BACKUP_LOG")"
[[ -f "$SNAP" ]] || fail "backup did not produce $SNAP"
pass "backup wrote $SNAP"

# Assertion: the qualified slug shape is in the file.
if ! grep -qE "^cask ${SLUG}\$" "$SNAP"; then
  cat "$SNAP" >&2
  fail "backup did not record qualified slug 'cask ${SLUG}'"
fi
pass "backup line carries the qualified slug 'cask ${SLUG}'"

# Negative: the unqualified bare-token form must not also appear,
# otherwise restore would attempt it and hit a core-API 404.
if grep -qE "^cask ${TOKEN}\$" "$SNAP"; then
  cat "$SNAP" >&2
  fail "backup also wrote the unqualified bare-token form"
fi
pass "backup did not duplicate as bare-token form"

# ── Uninstall + restore ────────────────────────────────────────────
"$BIN" uninstall "$TOKEN" >>"$BACKUP_LOG" 2>&1 ||
  fail "uninstall failed: $(tail -5 "$BACKUP_LOG")"
[[ ! -d "$PREFIX/Caskroom/${TOKEN}" ]] ||
  fail "Caskroom still present after uninstall"
pass "${TOKEN}: uninstalled cleanly"

RESTORE_LOG="$PREFIX/restore.log"
printf '\xe2\x96\xb8 mt restore %s (logs \xe2\x86\x92 %s)\n' "$SNAP" "$RESTORE_LOG"
"$BIN" restore "$SNAP" >"$RESTORE_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$RESTORE_LOG"; then
  skip "restore hit a classified network condition; cannot assert round-trip"
  exit 0
fi

# Assertion: restore re-installed the cask from the owning tap.
if grep -qE "Could not fetch cask info|Cask '${TOKEN}' not found" "$RESTORE_LOG"; then
  tail -30 "$RESTORE_LOG" >&2
  fail "restore failed against the core API — backup never carried the tap"
fi

[[ -d "$PREFIX/Caskroom/${TOKEN}" ]] ||
  fail "Caskroom missing after restore: ${PREFIX}/Caskroom/${TOKEN}"
pass "${TOKEN}: restore re-installed via the tap path"

# Verify the DB row also got the tap re-attributed (the recordInstall
# path writes it; this catches a regression where restore would
# silently install via a different code path that doesn't set tap).
DB="$PREFIX/db/malt.db"
restored_tap=$(sqlite3 "$DB" "SELECT IFNULL(tap, 'NULL') FROM casks WHERE token='${TOKEN}';")
[[ "$restored_tap" == "$EXPECTED_TAP" ]] ||
  fail "${TOKEN}: post-restore tap='${restored_tap}', expected '${EXPECTED_TAP}'"
pass "${TOKEN}: post-restore casks.tap='${EXPECTED_TAP}'"

printf '\n\xe2\x9c\x94 backup/restore tap-cask round-trip regression passed\n'
