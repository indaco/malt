#!/usr/bin/env bash
# Full end-to-end regression for root-layout tap installs.
#
# Sibling of tap-root-layout-resolve-*.sh: where that one stops at
# --dry-run to prove the raw probes resolve, this one materialises the
# keg. It installs a tap whose `<name>.rb` lives at the repository root
# (the older Homebrew layout used by koekeishiya/felixkratz) all the way
# to a runnable binary — the path that 404'd to FormulaNotFound before
# the root-layout fallback probe existed.
#
# Asserts, against a live install of koekeishiya/formulae/yabai:
#   1. `malt install <user>/<tap>/<formula>` exits 0 (pre-fix it aborted
#      at resolve with FormulaNotFound).
#   2. The keg is materialised at $PREFIX/Cellar/yabai/<version>/.
#   3. $PREFIX/bin/yabai symlinks into the keg and is executable.
#   4. The installed binary runs `--version` and reports `yabai-v<version>`,
#      matching the version malt derived from the URL — proving the whole
#      resolve -> download -> patch -> link chain is sound, not just resolve.
#
# The expected version is read back from the keg, so an upstream tap bump
# never stales this script: it pins resolve/install/run *consistency*, not
# a hardcoded release.
#
# Usage: scripts/regressions/tap-root-layout-install-gh478.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; network to
# api.github.com / raw.githubusercontent.com / the yabai release asset
# (rate-limit-proofed via MALT_GITHUB_TOKEN when present).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_GITHUB_TOKEN="${MALT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
mkdir -p "$PREFIX"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

SLUG="koekeishiya/formulae"
FORMULA="koekeishiya/formulae/yabai"
TOKEN="yabai"
LOG="$PREFIX/install.log"

# Tapping is the network gate; a miss here is a SKIP, not a failure — the
# bug under test is formula resolution, not tapping.
if ! "$BIN" tap "$SLUG" >/dev/null 2>&1; then
  echo "SKIP: cannot reach github to tap (network/rate-limit)"
  exit 0
fi

printf '▸ malt install %s (logs → %s)\n' "$FORMULA" "$LOG"
"$BIN" install "$FORMULA" >"$LOG" 2>&1 || {
  tail -30 "$LOG" >&2
  fail "${FORMULA}: install exited non-zero (root-layout resolve regressed?)"
}

# Resolve must have reached materialise, not died at the probe.
if grep -qiE 'Tap formula/cask not found|FormulaNotFound' "$LOG"; then
  tail -30 "$LOG" >&2
  fail "${FORMULA}: install log shows the root-layout tap did not resolve"
fi

CELLAR_ROOT="$PREFIX/Cellar/${TOKEN}"
[[ -d "$CELLAR_ROOT" ]] || fail "${FORMULA}: no keg under \$PREFIX/Cellar/${TOKEN}"
# Single installed version — read it back rather than hardcoding a release.
VERSION=$(find "$CELLAR_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | head -1)
[[ -n "$VERSION" ]] || fail "${FORMULA}: could not determine installed version from the keg"
pass "${FORMULA}: keg materialised at \$PREFIX/Cellar/${TOKEN}/${VERSION}"

LINK="$PREFIX/bin/${TOKEN}"
[[ -L "$LINK" ]] || fail "${FORMULA}: \$PREFIX/bin/${TOKEN} symlink is missing"
TARGET=$(readlink -f "$LINK" 2>/dev/null || readlink "$LINK")
[[ -x "$TARGET" ]] || fail "${FORMULA}: \$PREFIX/bin/${TOKEN} resolves to a non-executable target"
pass "${FORMULA}: \$PREFIX/bin/${TOKEN} → ${TARGET#"$PREFIX/"}"

# Run the patched binary. Exit-zero with the matching version proves the
# cellar layout and the Mach-O patch are both sound (no dyld breakage).
VERSION_OUT=$("$LINK" --version 2>&1) || {
  printf '%s\n' "$VERSION_OUT" >&2
  fail "${FORMULA}: installed binary failed to run --version"
}
if [[ "$VERSION_OUT" != *"${TOKEN}-v${VERSION}"* ]]; then
  printf '%s\n' "$VERSION_OUT" >&2
  fail "${FORMULA}: --version output did not include ${TOKEN}-v${VERSION}"
fi
pass "${FORMULA}: binary runs and reports ${TOKEN}-v${VERSION}"

printf '\n✔ root-layout tap end-to-end install regression passed\n'
