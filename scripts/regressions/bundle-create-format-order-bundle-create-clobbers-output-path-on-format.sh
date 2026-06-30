#!/usr/bin/env bash
# Regression: an explicit positional out_path for `bundle create` must win
# regardless of where `--format json` sits on the command line.
#
# The bug: cmdCreate derived the JSON default filename inside the `--format`
# parse arm, so `--format json` appearing after the positional path overwrote
# the user's filename with `Maltfile.json`. The default-filename choice was
# coupled to argument order instead of to "did the user give a path".
#
# Asserts both orderings honour the explicit path; runs the built binary
# against a throwaway workdir so no real keg is touched. No network.
#
# Exits 0 when the explicit path is honoured in both orderings, non-zero with a
# message naming the offending ordering otherwise.

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

cd "$tmp"

# Ordering A: path before flag (the broken case).
"$BIN" bundle create myfile --format json >/dev/null 2>&1 || true
[ -f myfile ] || {
  echo "FAIL: 'create myfile --format json' did not write myfile" >&2
  exit 1
}
[ -f Maltfile.json ] && {
  echo "FAIL: explicit path clobbered by Maltfile.json default (path before --format)" >&2
  exit 1
}
rm -f myfile

# Ordering B: flag before path (already worked) — guard against regression.
"$BIN" bundle create --format json myfile >/dev/null 2>&1 || true
[ -f myfile ] || {
  echo "FAIL: 'create --format json myfile' did not write myfile" >&2
  exit 1
}

echo "PASS: explicit out_path honoured regardless of --format position"
