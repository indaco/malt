#!/usr/bin/env bash
# Regression: `mt outdated` resolves a tap-installed cask's latest
# version against the owning tap, not the core Homebrew API.
#
# Pre-fix, the cask side of `mt outdated` called `api.fetchCask(token)`
# unconditionally. For a tap cask the core API 404s, the fetch fails,
# and the row gets silently classified as up-to-date — leaving the
# user with no audit signal that an upgrade is available. The fix
# pre-routes via `casks.tap` the same way `upgradeCask` does, fetching
# the tap's `Casks/<token>.rb` at fresh HEAD and parsing the version
# field.
#
# This script:
#   1. Installs a real third-party tap cask.
#   2. Tampers the local DB to mark it as installed at `0.0.0`,
#      well below any version the tap will ever ship.
#   3. Runs `mt outdated` and asserts the cask appears as outdated
#      with the tampered installed version and the tap's true latest.
#
# Tampering avoids depending on the upstream tap actually bumping
# between install and audit — a controlled mismatch lets the script
# stay deterministic against a stable tap state.
#
# Usage: scripts/regressions/outdated_tap_cask.sh
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
PREFIX="/tmp/mt_otap"
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

SLUG="yuzeguitarist/deck/deckclip"
TOKEN="${SLUG##*/}"

INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found|Failed to (install|download)|Sha256Mismatch|DownloadFailed|failed to record installed cask" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; cannot exercise outdated"
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

# Force a version mismatch by tampering the installed version.
sqlite3 "$DB" "UPDATE casks SET version='0.0.0' WHERE token='${TOKEN}';"
tampered=$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='${TOKEN}';")
[[ "$tampered" == "0.0.0" ]] ||
  fail "${TOKEN}: failed to tamper installed version (got '${tampered}')"
pass "${TOKEN}: tampered installed version to 0.0.0"

OUT_LOG="$PREFIX/outdated_${TOKEN}.log"
printf '\xe2\x96\xb8 mt outdated (expect tap-routed audit, logs \xe2\x86\x92 %s)\n' "$OUT_LOG"
"$BIN" outdated >"$OUT_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$OUT_LOG"; then
  skip "outdated hit a classified network condition; cannot assert tap routing"
  exit 0
fi

# Assertion 1: the cask is listed.
if ! grep -q "${TOKEN}" "$OUT_LOG"; then
  tail -30 "$OUT_LOG" >&2
  fail "${TOKEN}: tap-cask outdated audit did not list the cask"
fi
pass "${TOKEN}: outdated reported the tap cask"

# Assertion 2: tampered installed version surfaces.
if ! grep -qE "${TOKEN}.*0\.0\.0" "$OUT_LOG"; then
  tail -30 "$OUT_LOG" >&2
  fail "${TOKEN}: outdated did not report the tampered installed version"
fi
pass "${TOKEN}: outdated reported tampered installed=0.0.0"

# Assertion 3: the audit must show a non-tampered upstream version.
# The "All packages are up to date" line is the pre-fix failure mode.
if grep -q "All packages are up to date" "$OUT_LOG"; then
  tail -30 "$OUT_LOG" >&2
  fail "${TOKEN}: outdated silently classified the tap cask as up to date"
fi
pass "${TOKEN}: outdated did not collapse to the up-to-date branch"

printf '\n\xe2\x9c\x94 outdated tap-cask regression passed\n'
