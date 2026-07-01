#!/usr/bin/env bash
# Regression: `backup -o <absolute nested path>` must create the whole parent
# chain, matching the relative case.
#
# The bug: writeToPath created absolute parents with a single-level mkdir
# (createDirAbsolute) while relative parents went through a recursive
# createDirPath. A nested absolute destination with a missing grandparent
# therefore failed with a generic leaf "Failed to create ..." error, while the
# identically-shaped relative path succeeded.
#
# Asserts both the absolute and relative nested destinations create their
# parents and write a non-empty file. Uses a throwaway tmp tree; no network.
#
# Exits 0 when parents are created in both cases, non-zero with a message
# naming the offending case otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1

# grandparent intentionally absent: $tmp/a does not exist yet
dest="$tmp/a/b/backup.txt"

if ! "$BIN" backup -o "$dest" >/dev/null 2>&1; then
  echo "FAIL: backup to absolute nested path did not create parents ($dest)" >&2
  exit 1
fi
[ -s "$dest" ] || {
  echo "FAIL: destination missing or empty ($dest)" >&2
  exit 1
}

# sanity: relative parity still holds
(cd "$tmp" && "$BIN" backup -o rel/c/backup.txt >/dev/null 2>&1 &&
  [ -s rel/c/backup.txt ]) ||
  {
    echo "FAIL: relative nested backup regressed" >&2
    exit 1
  }

echo "PASS: absolute and relative nested backup destinations both create parents"
