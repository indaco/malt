#!/usr/bin/env bash
#
# Record the TUI feature demo gif via VHS -> docs/tui-demo.gif.
#
# Showcases the interactive dashboard end to end: Search (build a cross-query
# basket - add bat + bat-extras under 'bat', then redis under a second query -
# review it in the basket view, and install all three in one shot), Installed
# (detail pane), Services (start then stop the redis it just installed), and
# Doctor. All setup happens here -- *before* vhs starts -- so scripts/tui-demo.tape
# contains only what the viewer should see.
#
# The cache lives outside the throwaway prefix so the in-TUI installs run warm
# (fast, deterministic for a hosted asset) while the prefix starts empty. The
# demo installs bat, bat-extras, and redis on-screen; install only *registers*
# the launchd service (no auto-start), so redis starts out stopped and the
# Services tab then visibly starts and stops it.
#
# Usage:
#   ./scripts/record-tui-demo.sh            # builds if needed, records, cleans up
#   KEEP_PREFIX=1 ./scripts/record-tui-demo.sh   # leave the temp dirs in place
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

# Throwaway prefix. 7 bytes, safely under malt's Mach-O patch budget (matches
# scripts/record-demo.sh). The cache is a sibling so it survives the prefix wipe.
PREFIX=/tmp/mt-tui
CACHE=/tmp/mt-tui-cache

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"

# Put the dev build first so bare `malt`/`mt` resolve to zig-out/bin inside the
# recorded shell. VHS inherits this PATH from the parent process.
export PATH="$PWD/zig-out/bin:$PATH"
export MALT_NO_VERSION_NOTIFIER=1 # keep the update notice out of the recording

cleanup() {
  # Stop the service in case the run ended mid-demo, then drop the temp dirs.
  mt services stop redis >/dev/null 2>&1 || true
  if [[ "${KEEP_PREFIX:-0}" == "1" ]]; then
    echo "==> Leaving $PREFIX and $CACHE in place (KEEP_PREFIX=1)"
  else
    rm -rf "$PREFIX" "$CACHE"
  fi
}
trap cleanup EXIT

# Warm the cache with everything the demo installs (one cold install) so the
# in-TUI installs replay warm, then wipe the prefix so the recording starts from
# an empty store and installs bat, bat-extras, and redis on-screen.
echo "==> Warming cache: bat bat-extras redis"
rm -rf "$PREFIX" "$CACHE"
mkdir -p "$PREFIX"
malt install bat bat-extras redis >/dev/null
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

echo "==> Recording docs/tui-demo.gif..."
vhs scripts/tui-demo.tape

echo "==> Done: docs/tui-demo.gif"
echo "    Upload it to indaco/gh-assets as malt/tui-demo.gif for the README's"
echo "    Interactive dashboard section."
