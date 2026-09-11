#!/usr/bin/env bash
# Regression: a store entry that does not contain the requested keg must be
# refused, not installed.
#
# The bug: `materializeWithCellar` looked for `store/<sha>/<name>/<version>`,
# then for a `<version>_<rev>` sibling, and on a miss silently fell back to
# cloning the whole store entry. A malformed or mislabelled bottle therefore
# landed in `Cellar/<name>/<version>` with its real payload nested one or two
# directories down, got receipted and snapshotted into the relocated-store
# cache, and was reported as a successful install with nothing linkable at
# the keg root.
#
# Two arms, both offline:
#   1. the entry-root fallback stays gone;
#   2. the cellar integration suite, which pins that a missing name dir and a
#      name dir with no matching version both fail before anything is cloned.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# --- Arm 1: the fallback cannot come back ------------------------------------
if grep -Fq -- "break :blk store_entry" src/core/cellar.zig; then
  echo "FAIL: materializeWithCellar still falls back to the store entry root" >&2
  exit 1
fi

# --- Arm 2: the refusal holds at runtime -------------------------------------
BIN="$ROOT/zig-out/test-bin/cellar_test"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/malt-reg-kegsrc.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
if ! MALT_PREFIX="$SCRATCH" "$BIN" >"$SCRATCH/log" 2>&1; then
  echo "FAIL: a store entry without the requested keg was cloned instead of refused" >&2
  tail -n 30 "$SCRATCH/log" >&2
  exit 1
fi

echo "OK: store entry without <name>/<version> is refused, not cloned"
