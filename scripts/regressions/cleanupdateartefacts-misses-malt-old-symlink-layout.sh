#!/usr/bin/env bash
# Regression: `version update --cleanup` must remove every self-update
# artefact in the post-migration layout — malt.old, mt.old, and
# .malt-update-* staging — when invoked through the `mt` symlink.
#
# The bug: an update from the legacy dual-regular-file layout swaps both
# binaries (producing malt.old AND mt.old) before migrating `mt` to a
# symlink. Cleanup only deleted `<resolved self>.old` = malt.old, so
# mt.old was orphaned forever and a second run claimed "Nothing to clean
# up." while it still sat on disk.
#
# Exits 0 when all artefacts are removed, non-zero naming the survivor.
# Fully offline; finishes well under 30s given a built binary.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# `zig build test` never rebuilds zig-out/bin/malt — build explicitly.
if [ ! -x "$ROOT/zig-out/bin/malt" ]; then
  (cd "$ROOT" && zig build)
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cp "$ROOT/zig-out/bin/malt" "$T/malt"
ln -s malt "$T/mt"
touch "$T/malt.old" "$T/mt.old" "$T/.malt-update-99999"

"$T/mt" version update --cleanup >/dev/null

status=0
for leftover in malt.old mt.old .malt-update-99999; do
  if [ -e "$T/$leftover" ]; then
    echo "FAIL: --cleanup left $leftover behind" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

# A clean second run pins the report path: pre-fix it printed
# "Nothing to clean up." while mt.old was still on disk.
second=$("$T/mt" version update --cleanup 2>&1)
if ! printf '%s' "$second" | grep -q "Nothing to clean up"; then
  echo "FAIL: second cleanup run still reported artefacts" >&2
  exit 1
fi

echo "OK: all update artefacts removed"
