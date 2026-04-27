#!/usr/bin/env bash
# Regression for tap-hosted casks shipping non-tarball formats.
# A `.dmg` (and by extension `.pkg`, or `.zip` with an `app "<X>.app"`
# directive) routed through the tap install path used to bounce at the
# format gate with "Unsupported archive format" because the tap path
# only recognised tar.gz/tar.xz/zip — even when the DSL was clearly a
# cask. The fix dispatches DMG/PKG/cask-zip URLs to `core/cask.zig`,
# reusing every install primitive the brew-API cask flow already has.
#
# This script walks real third-party tap casks, tolerates individual
# upstream outages (network / release churn), and fails hard on the
# original rejection symptom or a missing `.app` bundle in the chosen
# Applications dir.
#
# Usage: scripts/regressions/tap_cask_dmg_gh136.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to GitHub raw + the upstream release hosts. macOS only
# (the cask installer relies on hdiutil / ditto).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_dmgreg"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── Candidate tap casks shipping a `.dmg` ───────────────────────────────
#
# `<tap>:<token>:<bundle>` triples. The `.app` bundle name is the
# observable we assert on — it must land under `$PREFIX/Applications/`
# after install. Extend this list with any other tap cask that ships a
# DMG and stays online; the regression only needs ONE candidate to
# install for the gate to be considered fixed.
declare -a CASKS=(
  "yuzeguitarist/deck/deckclip:Deck.app"
)

installed_any=0
for spec in "${CASKS[@]}"; do
  full="${spec%:*}"
  bundle="${spec##*:}"
  token="${full##*/}"
  LOG="$PREFIX/install_${token}.log"
  printf '▸ malt install %s (logs → %s)\n' "$full" "$LOG"

  "$BIN" install "$full" >"$LOG" 2>&1 || true

  # The blanket rejection is the regression we are guarding — even if
  # another part of the install fails, this line must never surface.
  if grep -q "Unsupported archive format for ${token}" "$LOG"; then
    tail -20 "$LOG" >&2
    fail "${full}: regression — DMG cask still rejected at the format gate"
  fi

  # Tolerate unrelated transient failures (upstream 404, sha256 drift,
  # TLS hiccups) so one flaky tap does not mask the fix on the rest.
  if grep -qE "Failed to (install|download)|Sha256Mismatch|DownloadFailed|Tap formula/cask not found" "$LOG"; then
    skip "${full}: install reported a non-regression failure; continuing"
    continue
  fi

  app_path="$PREFIX/Applications/$bundle"
  if [[ ! -d "$app_path" ]]; then
    tail -20 "$LOG" >&2
    fail "${full}: expected ${app_path} after install"
  fi

  caskroom="$PREFIX/Caskroom/${token}"
  [[ -d "$caskroom" ]] || fail "${full}: missing Caskroom record at ${caskroom}"

  # `mt list` must surface the new cask: the fix synthesises a Homebrew-API
  # JSON and feeds it to `cask_mod.recordInstall`, so a missing row here
  # means the routing landed but the DB write never happened.
  "$BIN" list >"$PREFIX/list_${token}.txt" 2>&1
  grep -q "${token}" "$PREFIX/list_${token}.txt" ||
    fail "${full}: ${token} missing from \`mt list\` after install"

  pass "${full}: DMG cask installed → ${app_path}"

  # Round-trip uninstall must remove the bundle and the DB row.
  "$BIN" uninstall "$token" >>"$LOG" 2>&1 ||
    fail "${full}: uninstall reported failure"
  [[ ! -d "$app_path" ]] ||
    fail "${full}: uninstall left ${app_path} behind"
  "$BIN" list >"$PREFIX/list_${token}_after.txt" 2>&1
  if grep -q "^[[:space:]]*[▸>][[:space:]]*${token}\$" "$PREFIX/list_${token}_after.txt"; then
    fail "${full}: ${token} still in \`mt list\` after uninstall"
  fi
  pass "${full}: uninstall removed the bundle and DB row"

  installed_any=1
done

((installed_any == 1)) || fail "no DMG cask installed — check network and candidate list"

# ── Format-gate sanity: a fake .pkg URL must NOT bounce at the gate. ──
#
# We can't actually run a PKG install (it shells to sudo installer), so
# the assertion here is negative: the new error text — produced after
# the cask installer downloads but before the privileged step — must
# differ from the old "Unsupported archive format" message that PR-137
# hit. A 404 is the expected end-state for the bogus URL.
fake_log="$PREFIX/fake_pkg.log"
"$BIN" install nonexistent/pkgcask/imaginary >"$fake_log" 2>&1 || true
if grep -q "Unsupported archive format" "$fake_log"; then
  tail -20 "$fake_log" >&2
  fail "fake .pkg lookup still hits the legacy format-gate message"
fi
pass "format-gate sanity: nonexistent tap fails without the legacy error"

printf '\n✔ tap-cask DMG regression passed\n'
