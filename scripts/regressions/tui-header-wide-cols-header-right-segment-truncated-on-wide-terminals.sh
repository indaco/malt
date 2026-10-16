#!/usr/bin/env bash
# Regression: the TUI header must keep its right segment and reset on any
# terminal width. A fixed scratch buffer clipped it past ~240 columns.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
name='render keeps the right segment and reset on a terminal wider than the scratch'
# The guard must exist, or a green lib_tests run proves nothing.
grep -qF "test \"$name\"" src/tui/header.zig ||
  {
    echo "FAIL: guard test missing from src/tui/header.zig" >&2
    exit 1
  }
# Inline tests only run inside lib_tests; a per-file binary cannot fail.
zig build test-bin >/dev/null 2>&1 ||
  {
    echo "FAIL: could not build lib_tests (zig build test-bin)" >&2
    exit 1
  }
OUT=$(env -u MALT_PREFIX -u MALT_CACHE "$root/zig-out/test-bin/lib_tests" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: header right segment truncated on a wide terminal" >&2
  printf '%s\n' "$OUT" | grep -iE 'failed|panic' >&2 || true
  exit 1
fi
echo "PASS: header keeps its right segment on wide terminals"
