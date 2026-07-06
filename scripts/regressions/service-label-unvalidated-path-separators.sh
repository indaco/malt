#!/usr/bin/env bash
# Regression: a service whose `label` carries a path separator or `..` must be
# rejected at the validation gate, before it can become a directory name.
#
# The bug: plist.validate ran a battery of path-escape checks on every string
# that becomes a filesystem path — program_args[0], working_dir, the log paths —
# but the label only passed checkString (length + NUL). register then feeds the
# label straight into serviceDir → `<prefix>/var/malt/services/<label>` and
# createDirPath, so a label containing `/` or `..` writes the plist directory
# outside the services subtree — enough `../` segments escape the prefix into
# any writable dir. A compromised or third-party tap is the delivery vector.
#
# The fix adds a single-path-component guard on `label` inside validate, at the
# one gate every disk write and launchctl bootstrap flows through, rejecting an
# empty value, `.`/`..`, or an embedded `/` or `..` (charset-agnostic so real
# `com.malt.<name>` labels still pass).
#
# No CLI surface drives validate offline without standing up launchd, and the
# guard fires before any write, so it is exercised by the colocated inline unit
# tests (`lib_tests`). This script builds and runs only that binary: it stays
# well under 30s and needs no network. A pass means every inline test —
# including the label-rejection guard — held; a regression flips that binary to
# a non-zero exit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/services/plist.zig"
TEST_NAME="validate rejects path separators in label"

# If the guard or its test is ever dropped, the unit binary would go green
# vacuously. Fail loudly instead: both the predicate and the test must be
# present in the source.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the label-rejection guard test is missing from $SRC" >&2
  exit 1
fi
if ! grep -Fqs -- "isPathComponent" "$SRC"; then
  echo "FAIL: the validate label path-component guard is missing from $SRC" >&2
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
# exit code. Pre-fix, validate accepts the traversal label the guard test feeds
# it, so that test fails and the binary exits non-zero.
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: service label path separators accepted by validate" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: service label path separators rejected by validate"
