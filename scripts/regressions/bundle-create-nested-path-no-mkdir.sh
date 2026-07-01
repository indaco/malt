#!/usr/bin/env bash
# Regression: `bundle create <nested path>` must create parent directories
# for both absolute and relative destinations.
#
# The bug: writeManifest did a bare createFile with no parent creation, so a
# nested output path whose parent was missing failed with no file written —
# the same defect already fixed for `backup -o` and `purge --backup`.
#
# Exits 0 when both nested destinations are created, non-zero with a message
# otherwise. No network; well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MALT_PREFIX="$tmp/p"
mkdir -p "$MALT_PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

# absolute nested destination: grandparent $tmp/abs is missing
abs="$tmp/abs/sub/Brewfile"
"$BIN" bundle create "$abs" >/dev/null 2>&1 || true
[ -f "$abs" ] || {
  echo "FAIL: bundle create did not create parents for an absolute nested path ($abs)" >&2
  exit 1
}

# relative nested destination, same shape
(cd "$tmp" && "$BIN" bundle create rel/sub/Brewfile >/dev/null 2>&1 && [ -f rel/sub/Brewfile ]) || {
  echo "FAIL: bundle create did not create parents for a relative nested path" >&2
  exit 1
}

echo "ok: bundle create writes nested absolute and relative destinations"
