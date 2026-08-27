#!/usr/bin/env bash
# Regression guard for tap formulas that omit `version "..."` and
# embed the tag in the URL.
#
# Homebrew treats `version` as optional: when the URL path encodes
# the tag (`/releases/download/<X>/...`, `/archive/refs/tags/<X>.<ext>`,
# `/archive/<X>.<ext>`), the version is derived. malt's tap parser
# previously rejected this shape as "unsupported Ruby DSL shape",
# blocking a large slice of third-party single-platform formulas
# (the `aeroxy/tap/ast-outline` shape).
#
# This script asserts the end-to-end install against a live tap whose
# formula has no `version` directive:
#   1. `malt install aeroxy/tap/ast-outline` exits 0.
#   2. The install log surfaces the derived version (`Found ast-outline 2.1.1`),
#      proving the parser took the URL-derivation branch rather than an
#      explicit-version branch.
#   3. The keg is materialised at `$PREFIX/Cellar/ast-outline/2.1.1/...`
#      and `$PREFIX/bin/ast-outline` symlinks into it.
#   4. The installed binary runs `--version` and reports `2.1.1`.
#
# `EXPECTED_VERSION` tracks the upstream tap's latest release — bump
# it when `aeroxy/ast-outline` cuts a new tag, since the formula
# always points at HEAD.
#
# Usage: scripts/regressions/tap_formula_url_version.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, network
# access to api.github.com / raw.githubusercontent.com /
# github.com/aeroxy/ast-outline release assets.

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
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

SLUG="aeroxy/tap/ast-outline"
TOKEN="ast-outline"
EXPECTED_VERSION="2.1.1"
LOG="$PREFIX/install.log"

printf '▸ malt install %s (logs → %s)\n' "$SLUG" "$LOG"
"$BIN" install "$SLUG" >"$LOG" 2>&1 || {
  tail -30 "$LOG" >&2
  fail "${SLUG}: install exited non-zero"
}

# The diagnostic line proves the URL-derivation branch fired: a
# pre-fix binary returned `Cannot parse tap formula (unsupported
# Ruby DSL shape)` and never reached the "Found …" line.
if ! grep -qE "Found ${TOKEN} ${EXPECTED_VERSION}" "$LOG"; then
  tail -30 "$LOG" >&2
  fail "${SLUG}: install log missing the derived 'Found ${TOKEN} ${EXPECTED_VERSION}' line"
fi
pass "${SLUG}: parser derived version ${EXPECTED_VERSION} from URL"

CELLAR="$PREFIX/Cellar/${TOKEN}/${EXPECTED_VERSION}"
if [[ ! -d "$CELLAR" ]]; then
  fail "${SLUG}: expected keg directory ${CELLAR} is missing"
fi
pass "${SLUG}: keg materialised at \$PREFIX/Cellar/${TOKEN}/${EXPECTED_VERSION}"

LINK="$PREFIX/bin/${TOKEN}"
if [[ ! -L "$LINK" ]]; then
  fail "${SLUG}: \$PREFIX/bin/${TOKEN} symlink is missing"
fi
TARGET=$(readlink -f "$LINK" 2>/dev/null || readlink "$LINK")
if [[ ! -x "$TARGET" ]]; then
  fail "${SLUG}: \$PREFIX/bin/${TOKEN} resolves to a non-executable target"
fi
pass "${SLUG}: \$PREFIX/bin/${TOKEN} → ${TARGET#"$PREFIX/"}"

# Run the installed binary. Any exit-zero with the expected version
# string proves the cellar layout and the binary's interpreter are
# both sound (codesign-friendly, no dyld breakage).
VERSION_OUT=$("$LINK" --version 2>&1) || {
  printf '%s\n' "$VERSION_OUT" >&2
  fail "${SLUG}: installed binary failed to run --version"
}
if ! grep -qE "${EXPECTED_VERSION}\$|${EXPECTED_VERSION} " <<<"$VERSION_OUT"; then
  printf '%s\n' "$VERSION_OUT" >&2
  fail "${SLUG}: --version output did not include ${EXPECTED_VERSION}"
fi
pass "${SLUG}: binary runs and reports ${EXPECTED_VERSION}"

printf '\n✔ tap-formula URL-derived version regression passed\n'
