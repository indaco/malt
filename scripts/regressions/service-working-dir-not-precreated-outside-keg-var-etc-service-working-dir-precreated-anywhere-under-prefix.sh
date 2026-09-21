#!/usr/bin/env bash
# Regression: a formula's `working_dir` must be pre-created only under its own
# keg, `<prefix>/var` (minus malt's own `var/malt` state) or `<prefix>/etc`.
#
# The bug: register mkdir'd `working_dir` unconditionally after plist.validate,
# and validate accepts any `..`-free absolute path anywhere under the prefix -
# the right boundary for naming a path in a plist, the wrong one for a malt-
# performed `mkdir -p`. A formula could point `working_dir` at `bin/<victim>`,
# `opt/<victim>` or `Cellar/<victim>/<ver>`, plant an empty directory there at
# install time, and the next `mt install <victim>` was refused by the linker's
# "existing directory" pre-check. No prefix escape; a formula-author-chosen
# denial of an unrelated formula.
#
# The fix gates the mkdir behind precreatableWorkingDir and leaves validate
# alone: the plist may still name the path, launchd reports the missing dir at
# start as before. Both registration entry points (API formula and tap/--local
# .rb) funnel through the same register, so one gate covers both.
#
# The behaviour is covered by tests/supervisor_pure_test.zig, which asserts
# both halves against a throwaway prefix: the refused set stays absent while
# registration still succeeds, and keg/var/etc are still created. This script
# builds and runs only that binary; no network. About 30 s warm, several
# minutes on a cold cache.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/services/supervisor.zig"
TEST="tests/supervisor_pure_test.zig"
TEST_NAME="register pre-creates a working dir only under the keg, var or etc"

# If the gate or its test is ever dropped, the test binary would go green
# vacuously. Fail loudly instead: both must be present in the source.
if ! grep -Fqs -- "fn precreatableWorkingDir" "$SRC"; then
  echo "FAIL: the working_dir pre-create gate is missing from $SRC" >&2
  exit 1
fi
if ! grep -Fqs -- "$TEST_NAME" "$TEST"; then
  echo "FAIL: the working_dir pre-create gate test is missing from $TEST" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Always rebuild so the binary reflects current source; Zig's cache keeps a
# no-op rebuild cheap.
if ! zig build test-bin >"$TMP/build.log" 2>&1; then
  cat "$TMP/build.log" >&2
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/supervisor_pure_test"
# The runner has no per-test filter; judge by the exit code and then confirm
# the gate test itself reported OK rather than being skipped.
MALT_PREFIX="$TMP/prefix" "$BIN" >"$TMP/run.log" 2>&1 && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]] || ! grep -Fq -- "${TEST_NAME}...OK" "$TMP/run.log"; then
  echo "FAIL: working_dir pre-create gate test did not pass (rc=$STATUS)" >&2
  grep -iE "failed|leaked|panic" "$TMP/run.log" >&2 || tail -20 "$TMP/run.log" >&2
  exit 1
fi

echo "PASS: working_dir is pre-created only under keg/var/etc"
