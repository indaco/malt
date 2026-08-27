#!/usr/bin/env bash
# Regression: `mt upgrade` against a tap-installed formula or cask.
#
# Up to v0.10.3, every installed package was looked up at
# `formulae.brew.sh/api/formula/<name>.json` (or `.../cask/<name>.json`).
# Anything from a third-party tap 404'd and the run aborted with:
#
#   ✗ Could not fetch formula info for <name>
#
# even though the package never lived on the core API. The fix routes
# tap-installed kegs (`kegs.tap` != `homebrew/core`) through the tap
# `.rb` path, and on a cask 404 falls back through every registered
# third-party tap before declaring the upgrade dead.
#
# This script asserts:
#   1. A synthetic tap keg row never produces the core-API error
#      message — the routing signal is the tap-side parser/resolver.
#   2. A real third-party tap formula install can be re-driven through
#      `mt upgrade` without the regression string surfacing.
#
# Usage: scripts/regressions/upgrade_tap_routing.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3 on
# PATH, network access for the seeding install.

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

# The pre-fix symptom. If this string surfaces for a tap-installed
# package, we've re-introduced the bug.
REGRESSION="Could not fetch formula info"
REGRESSION_CASK="Could not fetch cask info"

# ── Property 1: synthetic tap keg avoids the core-API error ──────────
#
# Seed a tap keg row directly so the test does not depend on a real
# tap install completing. The malformed tap label forces an early
# tap-side parse rejection — pre-fix, the same row would have walked
# straight into fetchFormula and printed the regression string.

# `mt list` only opens an existing DB; the install path is what
# bootstraps `$PREFIX/db/`. Mkdir + an `mt list` call kicks the schema
# init through the same code path malt itself uses.
mkdir -p "$PREFIX/db"
"$BIN" list >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after a list call"

sqlite3 "$DB" <<'SQL' || fail "could not seed synthetic tap keg row"
INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path)
VALUES ('regtap_baguette', 'tap-only/repo/regtap_baguette', '0.1',
        'tap-only-no-slash', 'sha-old', '/tmp/c/regtap_baguette/0.1');
SQL

SYNTH_LOG="$PREFIX/synthetic_upgrade.log"
printf '\xe2\x96\xb8 mt upgrade regtap_baguette (synthetic tap row, expect tap-side error)\n'
"$BIN" upgrade regtap_baguette >"$SYNTH_LOG" 2>&1 || true

if grep -q "$REGRESSION" "$SYNTH_LOG"; then
  tail -30 "$SYNTH_LOG" >&2
  fail "synthetic tap keg leaked the core-API error string"
fi
pass "synthetic tap keg: core-API error string not emitted"

if ! grep -q "Cannot parse tap" "$SYNTH_LOG"; then
  tail -30 "$SYNTH_LOG" >&2
  fail "synthetic tap keg: tap-side parse rejection missing"
fi
pass "synthetic tap keg: tap-side rejection emitted"

# Clean the synthetic row before the real install so list/migrate aren't confused.
sqlite3 "$DB" "DELETE FROM kegs WHERE name='regtap_baguette';"

# ── Property 2: real third-party tap formula upgrade end-to-end ──────
#
# `indaco/tap/sley` is a clean Go-binary tap: small archive, no deps,
# already exercised by other regressions. After install we drive the
# upgrade walker and assert the tap branch handles the row instead of
# falling through to fetchFormula.

SLUG="indaco/tap/sley"
TOKEN="sley"
INSTALL_LOG="$PREFIX/install_${TOKEN}.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$SLUG" "$INSTALL_LOG"
if ! "$BIN" install "$SLUG" >"$INSTALL_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|homebrew-" "$INSTALL_LOG"; then
    skip "${SLUG}: install hit a classified upstream condition; skipping upgrade leg"
    printf '\n\xe2\x9c\x94 upgrade-tap-routing regression passed (synthetic only)\n'
    exit 0
  fi
  tail -30 "$INSTALL_LOG" >&2
  fail "${SLUG}: install failed for an unclassified reason"
fi
pass "${SLUG}: installed"

UPGRADE_LOG="$PREFIX/upgrade_${TOKEN}.log"
printf '\xe2\x96\xb8 mt upgrade %s (logs \xe2\x86\x92 %s)\n' "$TOKEN" "$UPGRADE_LOG"
"$BIN" upgrade "$TOKEN" >"$UPGRADE_LOG" 2>&1 || true

if grep -q "$REGRESSION" "$UPGRADE_LOG"; then
  tail -30 "$UPGRADE_LOG" >&2
  fail "${SLUG}: upgrade leaked the core-API error string"
fi
if grep -q "$REGRESSION_CASK" "$UPGRADE_LOG"; then
  tail -30 "$UPGRADE_LOG" >&2
  fail "${SLUG}: upgrade leaked the core-API cask error string"
fi
pass "${SLUG}: upgrade did not surface the core-API error"

# A successful upgrade either re-installs at the fresh commit ("installed"),
# short-circuits because the pin hasn't moved ("already at latest tap commit"),
# or hits a classified network failure. Anything else means we routed
# somewhere unexpected.
if grep -qE "installed$| installed |already at latest tap commit" "$UPGRADE_LOG"; then
  pass "${SLUG}: upgrade reached the tap path and produced a routed outcome"
elif grep -qE "rate limit|Network failure|Could not resolve" "$UPGRADE_LOG"; then
  skip "${SLUG}: upgrade hit a classified network condition; routing is fine"
else
  tail -30 "$UPGRADE_LOG" >&2
  fail "${SLUG}: upgrade output does not show a tap-routed outcome"
fi

printf '\n\xe2\x9c\x94 upgrade-tap-routing regression passed\n'
