#!/usr/bin/env bash
# Regression guard for taps that keep `<name>.rb` at the repository root
# instead of under `Formula/` or `Casks/` (the older Homebrew layout
# still used by koekeishiya/felixkratz). The resolver probed only the
# two subdir paths, so a root-layout tap 404'd both and aborted with
# FormulaNotFound even though `brew install` resolves the same slug.
#
# Proves the fix end-to-end through the live raw probes, stopping at
# --dry-run before any archive download or keg materialisation:
#   1. `malt install <user>/<tap>/<formula>` resolves (no
#      `Tap formula/cask not found` / `FormulaNotFound` in the output).
#   2. The dry-run breadcrumb `Dry run: would install` fires, proving the
#      resolve path reached materialise rather than dying at the probe.
#
# Network is inherent: the bug lives in raw-tree probing, so this hits
# api.github.com (HEAD resolve) + raw.githubusercontent.com (two probes).
# It exports MALT_GITHUB_TOKEN from `gh auth token` to dodge the
# anonymous API cap, and SKIPs cleanly when neither token nor network is
# available.
#
# Usage: scripts/regressions/tap-root-layout-resolve-gh478.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; network to
# github (rate-limit-proofed via MALT_GITHUB_TOKEN when present).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_GITHUB_TOKEN="${MALT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
trap 'rm -rf "$PREFIX"' EXIT

SLUG="koekeishiya/formulae"
FORMULA="koekeishiya/formulae/yabai"

# Tap first; a network/rate-limit miss here is a SKIP, not a failure —
# the bug is in formula resolution, not in tapping.
if ! "$BIN" tap "$SLUG" >/dev/null 2>&1; then
  echo "SKIP: cannot reach github to tap (network/rate-limit)"
  exit 0
fi

out=$("$BIN" install "$FORMULA" --dry-run 2>&1 || true)

if printf '%s' "$out" | grep -qiE 'Tap formula/cask not found|FormulaNotFound'; then
  printf 'FAIL: root-layout tap formula did not resolve\n%s\n' "$out" >&2
  exit 1
fi

if ! printf '%s' "$out" | grep -q 'Dry run: would install'; then
  printf 'FAIL: dry-run breadcrumb missing — resolve path changed\n%s\n' "$out" >&2
  exit 1
fi

echo "OK: root-layout tap formula resolves through the raw probes"
