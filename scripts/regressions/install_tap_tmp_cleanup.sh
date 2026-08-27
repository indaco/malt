#!/usr/bin/env bash
# Regression: a successful third-party tap install must leave
# $PREFIX/tmp/ empty — no `tap_download*` archive should survive.
#
# A previous build aliased the same 512-byte buffer for both the
# staging-archive path and the per-binary `bin/<name>` path inside
# the post-extract walker. The deferred cleanup ran against an
# overwritten slice, so every successful tap install leaked an
# archive into $PREFIX/tmp until the user ran `mt doctor --fix`.
#
# Usage: scripts/regressions/install_tap_tmp_cleanup.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, network
# access to api.github.com / raw.githubusercontent.com.

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
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Real binary tap that ships a single executable through the
# materializeRubyFormula path (the surface the leak lived on).
SLUG="indaco/tap/sley"
LOG="$PREFIX/install.log"
printf '▸ malt install %s\n' "$SLUG"
"$BIN" install "$SLUG" >"$LOG" 2>&1 || true

if ! grep -qE "installed$| installed " "$LOG"; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found" "$LOG"; then
    skip "$SLUG: transient classified failure; cannot assert tmp/ cleanup"
    exit 0
  fi
  tail -30 "$LOG" >&2
  fail "$SLUG: install neither succeeded nor produced a known transient error"
fi
pass "$SLUG: install succeeded"

LEFTOVER=$(find "$PREFIX/tmp" -maxdepth 1 -name 'tap_download*' 2>/dev/null || true)
if [[ -n "$LEFTOVER" ]]; then
  printf '%s\n' "$LEFTOVER" >&2
  fail "stale tap archive(s) survived a successful install"
fi
pass "$PREFIX/tmp is clean after successful install"

printf '\n✔ tap tmp/ cleanup regression passed\n'
