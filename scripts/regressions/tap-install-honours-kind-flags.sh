#!/usr/bin/env bash
# Regression: `mt install --cask|--formula <user>/<tap>/<name>` must resolve
# only that kind: `--cask` reads `Casks/<name>.rb` even when the tap also
# ships `Formula/<name>.rb`, and `--formula` never falls back to `Casks/`.
#
# The bug: every tap install went through the formula-then-cask lookup, so
# both flags were ignored.
#
# Uses two live taps. dahlia/dojang ships both files: its formula builds
# from a source tag, its cask fetches a prebuilt release asset.
# voltiusapp/voltius ships only a cask. Dry runs only.
# Needs network; export MALT_GITHUB_TOKEN to stay clear of the anonymous cap.
#
# Usage: scripts/regressions/tap-install-honours-kind-flags.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.

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
trap 'rm -rf "$PREFIX"' EXIT

PKG="dahlia/dojang/dojang"

# The tap repo is not named homebrew-dojang, so register it explicitly.
if ! TAP_OUT=$("$BIN" tap dahlia/dojang --repo dahlia/dojang 2>&1); then
  # Only an unreachable forge is a skip; anything else is a real failure.
  if grep -qiE 'rate limit|network|timed out' <<<"$TAP_OUT"; then
    echo "SKIP: GitHub unreachable or rate-limited: $TAP_OUT"
    exit 0
  fi
  echo "FAIL: could not register the tap: $TAP_OUT" >&2
  exit 1
fi

CASK_OUT=$("$BIN" install --cask --dry-run "$PKG" 2>&1) || true
if ! grep -q '/releases/download/' <<<"$CASK_OUT"; then
  echo "FAIL: --cask did not resolve Casks/dojang.rb" >&2
  printf '%s\n' "$CASK_OUT" >&2
  exit 1
fi

# Without --cask the formula-first lookup still decides.
DEFAULT_OUT=$("$BIN" install --dry-run "$PKG" 2>&1) || true
if ! grep -q '/archive/refs/tags/' <<<"$DEFAULT_OUT"; then
  echo "FAIL: the default tap lookup no longer prefers Formula/" >&2
  printf '%s\n' "$DEFAULT_OUT" >&2
  exit 1
fi

# --formula must not fall back to a cask-only tap's Casks/ entry.
FORMULA_OUT=$("$BIN" install --formula --dry-run voltiusapp/voltius/voltius 2>&1) || true
if grep -q 'would install cask' <<<"$FORMULA_OUT"; then
  echo "FAIL: --formula fell back to Casks/voltius.rb" >&2
  printf '%s\n' "$FORMULA_OUT" >&2
  exit 1
fi
if ! grep -q 'not found' <<<"$FORMULA_OUT"; then
  echo "FAIL: --formula on a cask-only tap did not report the formula missing" >&2
  printf '%s\n' "$FORMULA_OUT" >&2
  exit 1
fi

echo "PASS: --cask and --formula pin a tap install to their own kind"
