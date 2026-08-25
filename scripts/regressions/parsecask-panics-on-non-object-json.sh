#!/usr/bin/env bash
# Regression: a cask body whose JSON root is not an object must degrade to a
# reportable parse failure, never abort `malt` mid-command.
#
# The bug: parseCask reached straight into `parsed.value.object` after parsing
# the cask body into a `std.json.Value`. That union field access is safety
# checked in the ReleaseSafe builds malt ships, so any root that is an array,
# string, number, bool, or null killed the process with SIGABRT before the
# traversal guards below it — and before the `catch` every call site already
# has for `CaskError.ParseFailed`.
#
# The fix switches on the root tag and returns `ParseFailed` for a non-object
# root, one line above the existing guards.
#
# `info --cask <token> --offline` serves the on-disk API cache at any age, so a
# staged cache file drives the shipped code path end to end with no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/cask.zig"
TEST_NAME="parseCask rejects a JSON root that is not an object"

# A CLI-only check could go green for the wrong reason if the guard and its
# unit test were dropped together. Fail loudly instead.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the root-shape rejection test is missing from $SRC" >&2
  exit 1
fi

if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build malt" >&2
  exit 1
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/cache/api"

# Root shapes a mirror, a hostile tap, or a corrupted cache file can present.
# Each was a distinct inactive-union-field abort before the fix.
for body in '[]' '"x"' '42' 'null' 'true'; do
  printf '%s' "$body" >"$SANDBOX/cache/api/cask_ghostty.json"
  set +e
  MALT_PREFIX="$SANDBOX/prefix" MALT_CACHE="$SANDBOX/cache" \
    "$ROOT/zig-out/bin/malt" info --cask ghostty --offline >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: cask body '$body' aborted malt (exit $rc); parseCask does not check the JSON root tag" >&2
    exit 1
  fi
done

echo "PASS: a non-object cask body is reported as a parse failure, not an abort"
