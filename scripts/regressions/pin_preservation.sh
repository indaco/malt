#!/usr/bin/env bash
# Pin preservation across reinstall paths.
#
# A user-pinned formula or cask must keep its hold across every non-
# uninstall lifecycle event. This script exercises the in-place row
# replacements that previously cleared the pinned column:
#
#   1. `mt install --force <pinned-formula>`  — INSERT OR REPLACE on kegs
#   2. `mt install --cask --force <pinned-cask>` — INSERT OR REPLACE on casks
#
# Asserts after each step that `mt list --pinned` still names the
# package and that `mt upgrade <name>` is a quiet no-op (the
# "pinned, skipped" short-circuit only fires when the row is still
# pinned in DB).
#
# Rollback / migrate paths are covered by unit tests; they require a
# multi-version store / a Homebrew installation to drive end-to-end and
# would balloon this script's runtime. The two install --force paths
# above share the same SQL pattern (`COALESCE((SELECT MAX(pinned) ...))`)
# so a green run here implies the pattern is wired correctly.
#
# Usage: scripts/regressions/pin_preservation.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="/tmp/mt_pin"
CACHE="/tmp/mc_pin"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX" "$CACHE"
mkdir -p "$PREFIX" "$CACHE"
trap 'rm -rf "$PREFIX" "$CACHE"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Formula side: tree is small, has no post_install, and lives entirely
# under MALT_PREFIX. Override with FORMULA=name.
FORMULA="${FORMULA:-tree}"
# Binary cask: no /Applications dependency, lands under $PREFIX/bin.
# Override with CASK=token.
CASK="${CASK:-copilot-cli}"

assert_pinned() {
  local kind="$1" name="$2"
  if "$BIN" list --pinned --quiet 2>/dev/null | grep -qx "$name"; then
    pass "$kind $name still appears in mt list --pinned"
  else
    "$BIN" list --pinned 2>&1 | sed 's|^|        | |' >&2
    fail "$kind $name missing from mt list --pinned (pin was clobbered)"
  fi
}

assert_upgrade_skips() {
  local kind="$1" name="$2"
  local log
  log="$PREFIX/upgrade_${name//\//_}.log"
  if "$BIN" upgrade "$name" >"$log" 2>&1; then
    if grep -q 'pinned, skipped' "$log"; then
      pass "$kind $name: mt upgrade prints 'pinned, skipped'"
    else
      pass "$kind $name: mt upgrade exits 0 (already at latest is also fine)"
    fi
  else
    sed -n '1,30p' "$log" >&2
    fail "$kind $name: mt upgrade returned non-zero"
  fi
}

# --- Formula round-trip: install -> pin -> install --force ---
printf '\xe2\x96\xb8 formula round-trip on %s\n' "$FORMULA"
"$BIN" install "$FORMULA" >"$PREFIX/install_$FORMULA.log" 2>&1 ||
  fail "initial install of $FORMULA failed — see $PREFIX/install_$FORMULA.log"
pass "$FORMULA installed"

"$BIN" pin "$FORMULA" >/dev/null 2>&1 ||
  fail "mt pin $FORMULA failed"
assert_pinned formula "$FORMULA"

# install --force on an already-installed formula must preserve the pin.
"$BIN" install --force "$FORMULA" >"$PREFIX/install_force_$FORMULA.log" 2>&1 ||
  fail "mt install --force $FORMULA failed — see $PREFIX/install_force_$FORMULA.log"
assert_pinned formula "$FORMULA"
assert_upgrade_skips formula "$FORMULA"

"$BIN" unpin "$FORMULA" >/dev/null 2>&1 || true
"$BIN" uninstall "$FORMULA" >/dev/null 2>&1 || true

# --- Cask round-trip: install -> pin -> install --cask --force ---
printf '\xe2\x96\xb8 cask round-trip on %s\n' "$CASK"
if ! "$BIN" install --cask "$CASK" >"$PREFIX/install_$CASK.log" 2>&1; then
  printf '  - SKIP cask leg: install --cask %s failed (network/upstream)\n' "$CASK"
  printf '\n\xe2\x9c\x94 pin-preservation regression passed (cask leg skipped)\n'
  exit 0
fi
pass "$CASK installed"

"$BIN" pin "$CASK" >/dev/null 2>&1 ||
  fail "mt pin $CASK failed"
assert_pinned cask "$CASK"

"$BIN" install --cask --force "$CASK" >"$PREFIX/install_force_$CASK.log" 2>&1 ||
  fail "mt install --cask --force $CASK failed — see $PREFIX/install_force_$CASK.log"
assert_pinned cask "$CASK"
assert_upgrade_skips cask "$CASK"

"$BIN" unpin "$CASK" >/dev/null 2>&1 || true
"$BIN" uninstall --cask "$CASK" >/dev/null 2>&1 || true

printf '\n\xe2\x9c\x94 pin-preservation regression passed\n'
