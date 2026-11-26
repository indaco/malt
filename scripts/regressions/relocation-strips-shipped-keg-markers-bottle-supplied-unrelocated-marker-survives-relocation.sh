#!/usr/bin/env bash
# Regression: relocation writes `.malt-unrelocated` only when it fails to
# rewrite a path. A bottle that ships that file at its keg root must not keep
# it, or the bottle author decides what doctor and `configure_php` report.
#
# Two legs:
#   1. static: `relocateKegTree` and `relocateUnbottledKeg` strip the keg
#      markers before they write any;
#   2. behaviour: the inline tests for this run and print OK (only
#      lib_tests runs inline tests of src/). Each one fails without the fix.
#
# MALT_STATIC_ONLY=1 runs leg 1 only. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/cellar.zig"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for head in 'fn relocateKegTree' 'pub fn relocateUnbottledKeg'; do
  body=$(awk -v h="^${head}[(]" '$0 ~ h{f=1} f{print} f&&/^}/{exit}' "$SRC")
  code=$(printf '%s\n' "$body" | grep -vE '^[[:space:]]*//' || true)
  printf '%s\n' "$code" | grep -qE '^[[:space:]]*stripKegMarkers\(io, cellar_path\);' ||
    fail "$head no longer strips keg markers; a shipped .malt-unrelocated survives"
  # The strip must run first, or it deletes the marker malt just wrote.
  strip_at=$(printf '%s\n' "$code" | grep -nE '^[[:space:]]*stripKegMarkers\(io, cellar_path\);' | head -1 | cut -d: -f1)
  write_at=$(printf '%s\n' "$code" | grep -nE 'write(UnrelocatedMarker|KegMarker|RelocStamp)\(' | head -1 | cut -d: -f1)
  [[ -z "$write_at" || "$strip_at" -lt "$write_at" ]] ||
    fail "$head strips keg markers after it writes its own"
done

if [[ "${MALT_STATIC_ONLY:-}" == 1 ]]; then
  echo "OK: both relocation entry points strip keg markers (static)"
  exit 0
fi

unset MALT_CACHE
LOG=""
trap 'command rm -rf ${LOG:+"$LOG"}' EXIT
LOG=$(mktemp -d /tmp/mt_shipped_marker.XXXXXX)

(cd "$ROOT" && env -u MALT_PREFIX zig build test-bin) >"$LOG/build" 2>&1 ||
  {
    tail -40 "$LOG/build"
    fail "could not build the test binaries"
  }
MALT_PREFIX=/tmp/malt-test-prefix "$ROOT/zig-out/test-bin/lib_tests" </dev/null >"$LOG/run" 2>&1 || true

for title in \
  "relocateKegTree drops a shipped unrelocated marker after a clean relocation" \
  "relocateUnbottledKeg drops markers the archive shipped" \
  "stripKegMarkers clears a marker under a keg path longer than 512 bytes" \
  "hoistSingleWrapperDir drops a marker the archive shipped inside the wrapper" \
  "hoistSingleWrapperDir never moves a marker out of the wrapper" \
  "relocateKegTree records its own count over a shipped directory of the marker's name" \
  "relocateKegTree records its own markers over read-only shipped directories" \
  "kegHasUnrelocatedPaths ignores a directory named like the marker"; do
  # A log line can split the runner line, so judge the whole block up to
  # the next progress line.
  block=$(awk -v t="test.$title..." '
    /^[0-9]+\/[0-9]+ /{ if (on) exit; on = index($0, t) > 0 }
    on { print }' "$LOG/run")
  [[ -n "$block" ]] || fail "test did not run: $title"
  printf '%s\n' "$block" | grep -qx 'OK\|.*\.\.\.OK' || fail "test failed: $block"
  printf '%s\n' "$block" | grep -q 'leaked' && fail "test leaked: $block"
done
echo "PASS: relocation never keeps a bottle-supplied unrelocated marker"
