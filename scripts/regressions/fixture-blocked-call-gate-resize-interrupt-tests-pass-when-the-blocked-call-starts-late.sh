#!/usr/bin/env bash
# The resize fixture must signal only a blocked call and fail when none was hit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
f="$ROOT/src/testing/resize_interrupt.zig"
[[ -f "$f" ]] || {
  echo "FAIL: $f missing" >&2
  exit 1
}
tmp=$(mktemp -d)
trap 'command rm -rf "$tmp"' EXIT
# The late-caller tests are the guard: a timed fixture lets them pass vacuously.
grep -q 'test "late' "$f" || {
  echo "FAIL: late-caller fixture test missing" >&2
  exit 1
}
if ! out=$(zig test "$f" --cache-dir "$tmp/c" 2>&1); then
  echo "FAIL: resize fixture does not catch a late blocked call:" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi
echo "PASS: resize fixture gates signals on a blocked call"
