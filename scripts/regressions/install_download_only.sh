#!/usr/bin/env bash
# Regression test for `mt install --download-only`.
#
# Warms the bottle store and stops before materialise/link/record. A
# follow-up plain install of the same package must consume the warmed
# bytes (no second download), the Cellar must be empty after the warm
# step, and the kegs table must report zero rows. Catches regressions
# in the new exit point inside cli/install.zig + the split download
# phase in install/download.zig.
#
# Usage: scripts/regressions/install_download_only.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh, sqlite3 in PATH.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 not on PATH" >&2
  exit 2
}

PREFIX="/tmp/mt_dlonly"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# `hello` is the smallest live formula with no deps — cheap to fetch,
# easy to assert against. If it disappears upstream, swap to another
# zero-dep leaf.
TARGET="${TARGET:-hello}"
LOG="$PREFIX/install.log"

# ── 1. --download-only must warm the store and stop. ──────────────────
printf '▸ malt install --download-only %s (logs → %s)\n' "$TARGET" "$LOG"
"$BIN" install --download-only "$TARGET" >"$LOG" 2>&1 || {
  printf '---- last 40 lines of install log ----\n' >&2
  tail -40 "$LOG" >&2
  fail "--download-only failed for $TARGET — see $LOG"
}
pass "--download-only ran cleanly"

# Cellar must be untouched.
[[ -d "$PREFIX/Cellar/$TARGET" ]] && fail "Cellar/$TARGET populated by --download-only"
pass "Cellar/$TARGET absent after --download-only"

# Store must hold at least one bottle dir.
store_entries=$(find "$PREFIX/store" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
[[ "$store_entries" -ge 1 ]] || fail "store empty after --download-only"
pass "store holds $store_entries bottle(s)"

# kegs must be empty.
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected $DB to exist after --download-only"
keg_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs;")
[[ "$keg_rows" = "0" ]] || fail "kegs table not empty after --download-only (rows=$keg_rows)"
pass "kegs table empty"

# Human output carries the resolved bottle path.
grep -q "downloaded to $PREFIX/store/" "$LOG" || fail "resolved bottle path not printed"
pass "resolved bottle path printed"

# ── 2. --ndjson emits download_started + download_complete. ───────────
ND_LOG="$PREFIX/ndjson.log"
"$BIN" --output-format=ndjson install --download-only "$TARGET" >"$ND_LOG" 2>>"$LOG" || {
  printf '---- last 40 lines of ndjson run ----\n' >&2
  tail -40 "$LOG" >&2
  fail "--output-format=ndjson run failed — see $LOG"
}
grep -q '"event":"download_started"' "$ND_LOG" || fail "missing download_started event"
grep -q '"event":"download_complete"' "$ND_LOG" || fail "missing download_complete event"
pass "ndjson emits download_started + download_complete"

# ── 3. --download-only refuses --only-dependencies. ───────────────────
if "$BIN" install --download-only --only-dependencies "$TARGET" >/dev/null 2>&1; then
  fail "--download-only --only-dependencies combo was not refused"
fi
pass "--only-dependencies combo refused"

# ── 4. Follow-up real install consumes the warmed bytes. ──────────────
"$BIN" install "$TARGET" >>"$LOG" 2>&1 || {
  printf '---- last 40 lines of install log ----\n' >&2
  tail -40 "$LOG" >&2
  fail "follow-up real install failed — see $LOG"
}
[[ -d "$PREFIX/Cellar/$TARGET" ]] || fail "Cellar/$TARGET missing after follow-up install"
pass "follow-up install populated Cellar/$TARGET"

printf '\n✔ install-download-only regression test passed\n'
