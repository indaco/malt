#!/usr/bin/env bash
# Regression: a key that answers the uninstall prompt must not dismiss a banner
# set while the prompt was armed. Runs the inline test through a root-level shim.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
shim="$root/.regress-banner-modal.$$.zig"
trap 'rm -f "$shim"' EXIT
printf 'test { _ = @import("src/tui/app.zig"); }\n' >"$shim"
filter='a banner set while the prompt is armed shows once the answer clears the prompt'
out=$(cd "$root" && env -u MALT_PREFIX -u MALT_CACHE \
  zig test "$shim" --test-filter "$filter" 2>&1) && rc=0 || rc=$?
# an unmatched filter still passes, so require the target test's name
if ! grep -Fq "app.test.$filter" <<<"$out"; then
  echo "FAIL: test '$filter' not found - guard removed or renamed" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "FAIL: answering the prompt dismisses a banner the user never saw" >&2
  echo "$out" >&2
  exit 1
fi
echo "ok: the banner survives the key that answers the prompt"
