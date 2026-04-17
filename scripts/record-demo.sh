#!/usr/bin/env bash
#
# Record the README demo gif via VHS.
#
# All setup (throwaway /tmp/mt prefix, dev build on PATH, env vars) happens
# in this wrapper — *before* vhs starts — so none of it appears in the
# recording. scripts/demo.tape itself contains only the visible `malt`
# commands. This sidesteps VHS Hide/Show entirely.
#
# Usage:
#   ./scripts/record-demo.sh            # builds if needed, records, cleans up
#   KEEP_PREFIX=1 ./scripts/record-demo.sh   # leave /tmp/mt in place afterwards
#
# Requires:
#   - vhs  (brew install vhs)
#   - zig-out/bin/malt built (the script will build it if missing)

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v vhs >/dev/null 2>&1; then
  echo "error: vhs not found. Install with: brew install vhs" >&2
  exit 1
fi

if [[ ! -x zig-out/bin/malt ]]; then
  echo "==> Building release malt binary..."
  zig build -Doptimize=ReleaseSafe
fi

# Throwaway prefix. 7 bytes, safely under malt's 13-byte Mach-O patch budget
# (see src/cli/install.zig:24 and scripts/e2e/test_smoke_install.sh).
PREFIX=/tmp/mt

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"

# Put the dev build first so bare `malt` resolves to zig-out/bin/malt inside
# the recorded shell. VHS inherits this PATH from the parent process.
export PATH="$PWD/zig-out/bin:$PATH"

# Start from a clean slate.
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

cleanup() {
  if [[ "${KEEP_PREFIX:-0}" == "1" ]]; then
    echo "==> Leaving $PREFIX in place (KEEP_PREFIX=1)"
  else
    rm -rf "$PREFIX"
  fi
}
trap cleanup EXIT

echo "==> Recording docs/demo.gif..."
vhs scripts/demo.tape

echo "==> Done: docs/demo.gif"
