#!/usr/bin/env bash
# Regression: a cask whose disk image ships only binaries was refused with
# "nothing malt can install", though zip and tarball casks of that shape install.
#
# Static guard plus unit run: the dmg path needs hdiutil, so the behaviour is
# pinned by the inline test; this script checks it and the call site exist.
#
# Usage: scripts/regressions/cask-binary-only-dmg-installs-binary-only-dmg-cask-has-nothing-to-install.sh
# Requirements: zig, grep. No network access required. Creates no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SRC=src/core/cask.zig
grep -q 'fn placeBinariesOnly' "$SRC" || fail "binary-only placement missing"
grep -q 'return self.placeBinariesOnly(mount_point' "$SRC" || fail "dmg path does not use it"
grep -q 'test "installDmg installs a disk image that ships only a binary"' "$SRC" ||
  fail "dmg test missing"

if [[ -n "${MALT_STATIC_ONLY:-}" ]]; then
  echo "OK: a binary-only disk image installs (static-only)"
  exit 0
fi

env -u MALT_PREFIX zig build test || fail "unit tests red"
echo "OK: a binary-only disk image installs"
