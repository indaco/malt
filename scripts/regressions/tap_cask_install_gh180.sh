#!/usr/bin/env bash
# Regression guard for third-party tap cask installs.
#
# Before the fix, `mt install <user>/<tap>/<cask>` collapsed every
# `resolveHeadCommit` failure — rate limit, 404, network, malformed
# JSON — into a blanket "refusing to install from a floating HEAD"
# message. The real cause was invisible without --debug.
#
# The fix widens `TapError` so each failure mode has its own tag, and
# honors `MALT_GITHUB_TOKEN` as a Bearer header on the `/commits/HEAD`
# call (lifting the 60/hr anonymous cap). The user-facing error now
# names the cause and the remediation.
#
# This script asserts two properties:
#   1. A known-404 tap input never surfaces the blanket message — it
#      must emit the new classified message naming the 'homebrew-'
#      prefix rule. This distinguishes a fixed binary from a pre-fix
#      one regardless of the runner's GitHub rate-limit state.
#   2. A real third-party tap install either succeeds or fails with a
#      classified error (rate limit, 404, network). The blanket string
#      must never resurface.
#
# Usage: scripts/regressions/tap_cask_install_gh180.sh
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
PREFIX="/tmp/mt_gh180"
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

# The original regression symptom. If this phrase appears in *any*
# install log below, we've re-introduced the opaque error surface.
BLANKET="refusing to install from a floating HEAD"

# ── Property 1: bogus tap produces a classified message ──────────────
#
# The distinguishing signal between fixed and pre-fix binaries. On
# a pre-fix binary this prints the blanket message; on a fixed binary
# it names the homebrew- prefix rule (the 404 branch of the classifier).
BOGUS_LOG="$PREFIX/install_bogus.log"
printf '▸ malt install malt-nobody-test/nope/nothing (expected: classified 404 message)\n'
"$BIN" install "malt-nobody-test/nope/nothing" >"$BOGUS_LOG" 2>&1 || true
if grep -q "$BLANKET" "$BOGUS_LOG"; then
  tail -30 "$BOGUS_LOG" >&2
  fail "bogus-tap: regression — opaque 'floating HEAD' error on 404"
fi
if ! grep -qE "homebrew-|rate limit|Network failure" "$BOGUS_LOG"; then
  tail -30 "$BOGUS_LOG" >&2
  fail "bogus-tap: expected a classified error message, got none"
fi
pass "bogus-tap: classified error emitted (no blanket message)"

# ── Property 2: real third-party tap candidates ──────────────────────
#
# Each spec is `<tap-slug>`. We accept either a successful install
# line or a classified error; only the blanket string is a regression.
#
# Each spec is `<tap-slug>:<expected-binary>`. The binary basename is
# what the install must symlink into $PREFIX/bin/. The longbridge cask
# is the original gh#180 reproduction — its archive ships a
# `longbridge` binary while the cask token is `longbridge-terminal`,
# so the cask DSL `binary "longbridge"` directive must be honoured.
declare -a CANDIDATES=(
  "longbridge/tap/longbridge-terminal:longbridge"
  "goreleaser/tap/goreleaser:goreleaser"
  "indaco/tap/sley:sley"
)

for spec in "${CANDIDATES[@]}"; do
  slug="${spec%:*}"
  bin="${spec##*:}"
  token="${slug##*/}"
  LOG="$PREFIX/install_${token}.log"
  printf '▸ malt install %s (logs → %s)\n' "$slug" "$LOG"
  "$BIN" install "$slug" >"$LOG" 2>&1 || true

  if grep -q "$BLANKET" "$LOG"; then
    tail -30 "$LOG" >&2
    fail "${slug}: regression — opaque 'floating HEAD' error returned"
  fi

  if grep -qE "installed$| installed " "$LOG"; then
    link="$PREFIX/bin/$bin"
    if [[ ! -L "$link" ]]; then
      tail -30 "$LOG" >&2
      fail "${slug}: install reported success but \$PREFIX/bin/${bin} is missing"
    fi
    target=$(readlink -f "$link" 2>/dev/null || readlink "$link")
    if [[ ! -x "$target" ]]; then
      fail "${slug}: \$PREFIX/bin/${bin} resolves to a non-executable target"
    fi
    pass "${slug}: installed → \$PREFIX/bin/${bin}"
  elif grep -qE "homebrew-|rate limit|Network failure|Tap formula/cask not found" "$LOG"; then
    skip "${slug}: reported a classified non-blanket error; continuing"
  else
    tail -30 "$LOG" >&2
    fail "${slug}: neither installed nor emitted a classified error"
  fi
done

printf '\n✔ gh180 third-party tap regression passed\n'
