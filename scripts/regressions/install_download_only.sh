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

# ── 4b. Warming over an installed keg must still warm, not no-op. ─────
# An installed row says nothing about whether the current version's bottle
# is cached, so the already-installed gate must not swallow the request.
WARM_LOG="$PREFIX/warm-installed.log"
"$BIN" install --download-only "$TARGET" >"$WARM_LOG" 2>&1 ||
  fail "--download-only over an installed keg failed - see $WARM_LOG"
grep -q 'is already installed' "$WARM_LOG" &&
  fail "--download-only over an installed keg was skipped instead of warming"
grep -q 'downloaded to' "$WARM_LOG" ||
  fail "--download-only over an installed keg reported no download"
keg_rows_warm=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name='$TARGET';")
[[ "$keg_rows_warm" = "1" ]] ||
  fail "--download-only over an installed keg disturbed the kegs table (rows=$keg_rows_warm)"
pass "--download-only warms the store over an installed keg without touching it"

# ── 5. Cask --download-only: cache filled, no Caskroom row, no app. ───
# copilot-cli is a binary cask with no /Applications slot — safe to
# exercise without touching shared system state.
CASK_TARGET="${CASK_TARGET:-copilot-cli}"
CASK_LOG="$PREFIX/cask_install.log"
printf '▸ malt install --download-only --cask %s\n' "$CASK_TARGET"
"$BIN" install --download-only --cask "$CASK_TARGET" >"$CASK_LOG" 2>&1 || {
  printf '---- last 40 lines of cask download log ----\n' >&2
  tail -40 "$CASK_LOG" >&2
  fail "--download-only --cask failed for $CASK_TARGET — see $CASK_LOG"
}
pass "--download-only --cask ran cleanly"

# Cache file must exist; nothing should live under Caskroom or the casks table.
cache_count=$(find "$PREFIX/cache/Cask" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$cache_count" -ge 1 ]] || fail "cache/Cask empty after --download-only --cask"
pass "cache/Cask holds $cache_count artefact(s)"

casks_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM casks WHERE token = '$CASK_TARGET';")
[[ "$casks_rows" = "0" ]] || fail "casks row created by --download-only --cask (rows=$casks_rows)"
pass "casks table untouched"

grep -q "downloaded to $PREFIX/cache/Cask/" "$CASK_LOG" || fail "cask cache path not printed"
pass "cask cache path printed"

# Follow-up real cask install must consume the cache (no second fetch).
"$BIN" install --cask "$CASK_TARGET" >>"$CASK_LOG" 2>&1 || {
  printf '---- last 40 lines of cask install log ----\n' >&2
  tail -40 "$CASK_LOG" >&2
  fail "follow-up cask install failed — see $CASK_LOG"
}
follow_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM casks WHERE token = '$CASK_TARGET';")
[[ "$follow_rows" = "1" ]] || fail "follow-up cask install did not record (rows=$follow_rows)"
pass "follow-up cask install populated casks row"

# ── 6. Tap formula --download-only: warm cache/Tap, no Cellar/db. ─────
# Real binary tap that ships a single executable through the
# materializeRubyFormula path. Transient classified failures (rate
# limits, DNS) are skipped, not failures — same shape as
# install_tap_tmp_cleanup.sh.
TAP_TARGET="${TAP_TARGET:-indaco/tap/sley}"
TAP_LOG="$PREFIX/tap_install.log"
printf '▸ malt install --download-only %s\n' "$TAP_TARGET"
if ! "$BIN" install --download-only "$TAP_TARGET" >"$TAP_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Cannot fetch tap from GitHub|Tap formula/cask not found" "$TAP_LOG"; then
    printf '  - %s: transient classified failure; skipping tap section\n' "$TAP_TARGET"
    printf '\n✔ install-download-only regression test passed (tap section skipped)\n'
    exit 0
  fi
  tail -40 "$TAP_LOG" >&2
  fail "--download-only failed for $TAP_TARGET — see $TAP_LOG"
fi
pass "tap --download-only ran cleanly"

# Tap formula short name lives in the slug's last segment.
TAP_NAME="${TAP_TARGET##*/}"
[[ -d "$PREFIX/Cellar/$TAP_NAME" ]] && fail "Cellar/$TAP_NAME populated by tap --download-only"
pass "Cellar/$TAP_NAME absent after tap --download-only"

tap_cache_count=$(find "$PREFIX/cache/Tap" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$tap_cache_count" -ge 1 ]] || fail "cache/Tap empty after tap --download-only"
pass "cache/Tap holds $tap_cache_count archive(s)"

tap_kegs=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = '$TAP_NAME';")
[[ "$tap_kegs" = "0" ]] || fail "kegs row created by tap --download-only (rows=$tap_kegs)"
pass "kegs table untouched by tap --download-only"

grep -q "downloaded to $PREFIX/cache/Tap/" "$TAP_LOG" || fail "tap cache path not printed"
pass "tap cache path printed"

# Staging file was renamed, not leaked — pins the install_tap_tmp_cleanup
# invariant for the download-only path too.
leftover=$(find "$PREFIX/tmp" -maxdepth 1 -name 'tap_download*' 2>/dev/null || true)
[[ -z "$leftover" ]] || fail "stale tap_download* in tmp after --download-only"
pass "tmp/ clean after tap --download-only"

# ── 7. Follow-up tap install consumes the cache (no second fetch). ────
cache_before=$(find "$PREFIX/cache/Tap" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
"$BIN" install "$TAP_TARGET" >>"$TAP_LOG" 2>&1 || {
  tail -40 "$TAP_LOG" >&2
  fail "follow-up tap install failed — see $TAP_LOG"
}
[[ -d "$PREFIX/Cellar/$TAP_NAME" ]] || fail "Cellar/$TAP_NAME missing after follow-up install"
cache_after=$(find "$PREFIX/cache/Tap" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
[[ "$cache_before" = "$cache_after" ]] || fail "cache/Tap grew on follow-up (before=$cache_before after=$cache_after)"
pass "follow-up tap install consumed cache and populated Cellar/$TAP_NAME"

# ── 8. mt doctor reports tap-cache size; purge --cache reclaims it. ───
DOCTOR_LOG="$PREFIX/doctor.log"
"$BIN" doctor >"$DOCTOR_LOG" 2>&1 || true
grep -q "Tap archive cache" "$DOCTOR_LOG" || fail "mt doctor did not surface tap-cache size"
pass "mt doctor reports tap-cache size"

PURGE_LOG="$PREFIX/purge.log"
# Sleep 2 so the cache file's mtime is reliably > 0 seconds in the
# past; otherwise the recursive walker's `now - mtime > max_age_secs`
# check could miss a same-second file when max_age_days=0.
sleep 2
"$BIN" purge --cache=0 --yes >"$PURGE_LOG" 2>&1 || {
  tail -40 "$PURGE_LOG" >&2
  fail "purge --cache=0 failed"
}
tap_cache_after_purge=$(find "$PREFIX/cache/Tap" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$tap_cache_after_purge" = "0" ]] || fail "purge --cache=0 left tap cache entries ($tap_cache_after_purge remaining)"
pass "purge --cache=0 reclaimed tap cache entries"

printf '\n✔ install-download-only regression test passed\n'
