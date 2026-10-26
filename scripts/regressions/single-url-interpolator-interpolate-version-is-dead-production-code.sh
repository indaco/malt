#!/usr/bin/env bash
# Regression: the install path must keep exactly one `#{version}` expander.
# A second one (the old first-occurrence-only `interpolateVersion`) drifted
# from `interpolateUrl` and left later occurrences unexpanded.
#
# Static: no build, no network, no temp state.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
args="$root/src/cli/install/args.zig"
fail=0

if hits=$(rg -n 'fn interpolateVersion\b' "$root/src" "$root/tests"); then
  echo "FAIL: dead interpolateVersion is back:" >&2
  echo "$hits" >&2
  fail=1
fi

# One needle definition in args.zig == one interpolator. rb_parse.zig keeps
# its own needle for validation only; it does not expand.
n=$(rg -c -F '"#" ++ "{version}"' "$args" || true)
if [ "${n:-0}" -ne 1 ]; then
  echo "FAIL: expected 1 #{version} needle in args.zig, found ${n:-0}:" >&2
  rg -n -F '"#" ++ "{version}"' "$args" >&2 || true
  fail=1
fi

rg -q 'pub fn interpolateUrl\(' "$args" ||
  {
    echo "FAIL: interpolateUrl missing from args.zig" >&2
    fail=1
  }

exit "$fail"
