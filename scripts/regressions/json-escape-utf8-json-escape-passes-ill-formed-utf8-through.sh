#!/usr/bin/env bash
# Regression: jsonStr replaces ill-formed UTF-8 with U+FFFD, so --json output
# stays parseable, and keeps well-formed UTF-8 unchanged.
#
# Inline tests run only in lib_tests, so the guard builds and runs that binary
# and judges each named test by its own output line.
#
# Usage: scripts/regressions/json-escape-utf8-json-escape-passes-ill-formed-utf8-through.sh
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/json_escape.zig"
NAMES=(
  "jsonStr replaces ill-formed UTF-8"
  "jsonStr keeps well-formed UTF-8 unchanged"
  "jsonStr escapes DEL and UTF-8 C1 so a terminal never receives them raw"
)

for n in "${NAMES[@]}"; do
  grep -qF "test \"$n\"" "$SRC" || {
    echo "FAIL: guard test missing: $n" >&2
    exit 1
  }
done

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
echo "OK: jsonStr emits valid UTF-8 for ill-formed input"
