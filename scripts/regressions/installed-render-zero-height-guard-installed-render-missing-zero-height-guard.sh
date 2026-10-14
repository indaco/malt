#!/usr/bin/env bash
# Regression: the Installed tab must paint nothing into a zero-height rect.
# Runs the one inline test through a root-level shim: the tab imports via `../`
# and cannot be compiled alone.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
shim="$root/.regress-installed-zero-height.$$.zig"
trap 'rm -f "$shim"' EXIT
printf 'test { _ = @import("src/tui/installed_tab.zig"); }\n' >"$shim"
filter='render on a zero-height rect paints nothing, even with the guard armed'
out=$(cd "$root" && env -u MALT_PREFIX -u MALT_CACHE \
  zig test "$shim" --test-filter "$filter" 2>&1) && rc=0 || rc=$?
# an unmatched filter still passes (only the shim's own test runs), so
# require the target test's name in the output
if ! grep -Fq "installed_tab.test.$filter" <<<"$out"; then
  echo "FAIL: test '$filter' not found - guard removed or renamed" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "FAIL: installed_tab.render paints into a zero-height rect" >&2
  echo "$out" >&2
  exit 1
fi
echo "ok: installed_tab.render is a no-op on a zero-height rect"
