#!/usr/bin/env bash
# Regression: FallbackLog.toJson escapes the tap-controlled `formula` and
# `detail` fields, so a post_install event stays valid JSON and carries no raw
# terminal control bytes.
#
# Inline tests run only in lib_tests, so the guard builds and runs that binary
# and judges each named test by its own output line.
#
# Usage: scripts/regressions/fallback-log-json-escape-fallback-log-tojson-emits-unescaped-fields.sh
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/dsl/fallback_log.zig"
NAMES=(
  "toJson escapes quote, backslash and newline in formula and detail"
  "toJson escapes terminal control bytes in detail"
)

for n in "${NAMES[@]}"; do
  grep -qF "test \"$n\"" "$SRC" || {
    echo "FAIL: guard test missing: $n" >&2
    exit 1
  }
done
if grep -qE 'writeAll\(entry\.(detail|formula)\)' "$SRC"; then
  echo "FAIL: toJson writes a tap-controlled field raw" >&2
  exit 1
fi

(cd "$ROOT" && env -u MALT_PREFIX -u MALT_CACHE zig build test-bin) || {
  echo "FAIL: could not build the test binaries" >&2
  exit 1
}

# Capture first: streaming into grep -q under pipefail can SIGPIPE the producer.
rc=0
out=$(cd "$ROOT" && env -u MALT_PREFIX -u MALT_CACHE ./zig-out/test-bin/lib_tests 2>&1) || rc=$?
for n in "${NAMES[@]}"; do
  line=$(printf '%s\n' "$out" | grep -F "test.$n..." || true)
  [[ "$line" == *OK ]] || {
    echo "FAIL: guard did not run green: $n (lib_tests rc=$rc)" >&2
    printf '%s\n' "$out" | tail -20 >&2
    exit 1
  }
done
echo "OK: FallbackLog.toJson escapes tap-controlled fields"
