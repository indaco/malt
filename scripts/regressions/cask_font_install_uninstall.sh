#!/usr/bin/env bash
# Regression: font casks install into and uninstall from the user Fonts
# directory across the parsing/placement edges the install-font analysis
# identified. A future change to the cask pipeline must not silently break
# fonts, so this exercises real casks end to end:
#
#   font-fira-code         nested sources (ttf/…)  — nested-path resolution
#   font-hack-nerd-font    bare sources            — nerd-font baseline
#   font-meslo-lg-nerd-font bare, large-N (76)     — loop / manifest / perf
#
# For each cask the observable is the placed glyph: install must land at
# least one .ttf under $MALT_PREFIX/Fonts and record a .malt-fonts manifest
# in the Caskroom; uninstall must remove every placed glyph again. Pure
# upstream/network failures (DownloadFailed, sha drift, TLS) are tolerated
# as skips; a font cask that installs yet places nothing — or an uninstall
# that orphans glyphs — fails hard, because that is the regression.
#
# Upgrade-replace finding (the analysis's upgrade-replace question): `mt
# upgrade` routes a cask through uninstall→install atomically (upgradeCask
# and upgradeRoutedTapCask), so the manifest-driven unlink runs on upgrade
# and stale glyphs from a prior version — including renamed files — are
# cleaned before the new version is placed. Verified clean in code; not a gap.
#
# Usage: scripts/regressions/cask_font_install_uninstall.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt; network to
# formulae.brew.sh / github.com. Honors $MALT_GITHUB_TOKEN to dodge the
# anonymous GitHub API rate limit (falls back to `gh auth token` if present).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

# Lift the anonymous GitHub API cap when a token is reachable.
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export MALT_GITHUB_TOKEN
fi

FONTS="$PREFIX/Fonts"

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

font_count() { find "$FONTS" -type f -name '*.ttf' 2>/dev/null | wc -l | tr -d ' '; }

# token:min_glyphs:label — min_glyphs is a drift-tolerant floor, well under
# the real upstream count, that still proves the path (nested resolution,
# bare baseline, large-N loop).
declare -a CASKS=(
  "font-fira-code:1:nested"
  "font-hack-nerd-font:1:bare"
  "font-meslo-lg-nerd-font:10:large-N"
)

tested_any=0
for spec in "${CASKS[@]}"; do
  token="${spec%%:*}"
  rest="${spec#*:}"
  min="${rest%%:*}"
  label="${rest##*:}"
  LOG="$PREFIX/install_${token}.log"
  printf '▸ malt install --cask %s (%s, logs → %s)\n' "$token" "$label" "$LOG"

  "$BIN" install --cask "$token" >"$LOG" 2>&1 || true

  # Tolerate unrelated transient failures so one flaky upstream does not
  # mask the rest. A genuine font-branch break does NOT match these.
  if grep -qE "Sha256Mismatch|DownloadFailed|OfflineRequired|Failed to (download|fetch)" "$LOG"; then
    skip "${token}: install reported a non-regression failure; continuing"
    continue
  fi

  placed=$(font_count)
  if ((placed < min)); then
    tail -20 "$LOG" >&2
    fail "${token}: install placed ${placed} glyph(s) in \$PREFIX/Fonts (expected ≥ ${min}) — font branch regression"
  fi

  manifest=$(find "$PREFIX/Caskroom/${token}" -name '.malt-fonts' 2>/dev/null | head -1)
  [[ -n "$manifest" ]] || fail "${token}: no .malt-fonts manifest under Caskroom/${token}"

  "$BIN" uninstall "$token" >"$PREFIX/uninstall_${token}.log" 2>&1 ||
    fail "${token}: uninstall failed — $(tail -1 "$PREFIX/uninstall_${token}.log")"

  remaining=$(font_count)
  ((remaining == 0)) ||
    fail "${token}: ${remaining} glyph(s) orphaned in \$PREFIX/Fonts after uninstall"

  pass "${token}: ${placed} glyph(s) placed then removed (${label})"
  tested_any=1
done

((tested_any == 1)) ||
  fail "no font cask could be tested — check network / \$MALT_GITHUB_TOKEN"

printf '\n✔ font cask install/uninstall regression passed\n'
