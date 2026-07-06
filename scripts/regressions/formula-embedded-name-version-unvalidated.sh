#!/usr/bin/env bash
# Regression: a formula whose embedded JSON `name` or `version` carries a path
# separator or `..` must be rejected at parse time, before either field becomes
# an on-disk directory component.
#
# The bug: parseFormula copied `name` and `version` verbatim out of the formula
# JSON with no predicate between parse and use. Both are interpolated as raw
# path components downstream — the keg/cellar dir `Cellar/<name>/<version>`, the
# receipt, the opt symlink, the service label. The fetch-time name screen only
# guards the *requested* name; the JSON's own fields are independent values that
# never re-pass it, so a compromised or third-party tap could steer a write
# outside the prefix.
#
# The fix adds one charset-agnostic path-component guard in parseFormula, at the
# single ingestion choke point, rejecting `.`/`..`, an embedded `/` or `..`, or
# a NUL in `name` or a present `version` (real names/versions carry `@`/`+`/dots
# and still pass; an empty version stays legitimate). `full_name` is left alone
# because it is legitimately tap-qualified with `/`.
#
# No CLI surface drives parseFormula offline without standing up a local tap,
# and the guard fires before any download, so it is exercised by the colocated
# inline unit tests (`lib_tests`). This script builds and runs only that binary:
# it stays well under 30s and needs no network. A pass means every inline test —
# including the guard — held; a regression flips that binary to a non-zero exit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/formula.zig"
TEST_NAME="parseFormula rejects path separators in embedded name or version"

# If the guard or its test is ever dropped, the unit binary would go green
# vacuously. Fail loudly instead: both the predicate and the test must be
# present in the source.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the embedded name/version guard test is missing from $SRC" >&2
  exit 1
fi
if ! grep -Fqs -- "isPathComponent" "$SRC"; then
  echo "FAIL: the parseFormula path-component guard is missing from $SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source — a prebuilt lib_tests
# could predate the guard. Zig's cache makes a no-op rebuild cheap, so this
# stays well under the time budget.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the inline suite and judge by its
# exit code. Pre-fix, parseFormula accepts the traversal payloads the guard test
# feeds it, so that test fails and the binary exits non-zero.
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: formula embedded name/version path separators accepted at parse time" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: formula embedded name/version path separators rejected at parse time"
