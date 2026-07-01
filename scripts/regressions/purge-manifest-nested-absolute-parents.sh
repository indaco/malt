#!/usr/bin/env bash
# Regression: `purge --wipe --backup <absolute nested path>` must create the
# whole parent chain for the safety manifest, matching the relative case.
#
# The bug: the manifest writer created absolute parents with a single-level
# mkdir (createDirAbsolute) while relative parents went through a recursive
# createDirPath. A nested absolute --backup path with a missing grandparent
# therefore failed, aborting the wipe before it could write the safety net.
#
# Drives a real wipe against a throwaway prefix, pointing --backup at a nested
# absolute path whose grandparent does not exist, and asserts the manifest is
# written. No network; well under 30s.
#
# Exits 0 when the manifest is created, non-zero with a message otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
(cd "$ROOT" && zig build >/dev/null)

ROOTDIR="$(mktemp -d)"
trap 'rm -rf "$ROOTDIR"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1

PREFIX="$ROOTDIR/opt-malt"
mkdir -p "$PREFIX/store" "$PREFIX/Cellar"

# grandparent intentionally absent: $ROOTDIR/mani does not exist yet
manifest="$ROOTDIR/mani/a/backup.txt"

MALT_PREFIX="$PREFIX" "$BIN" purge --wipe --yes --backup "$manifest" >/dev/null 2>&1 || true

[ -s "$manifest" ] || {
  echo "FAIL: purge did not write the manifest to a nested absolute path ($manifest)" >&2
  exit 1
}

echo "ok: purge writes its backup manifest to a nested absolute path"
