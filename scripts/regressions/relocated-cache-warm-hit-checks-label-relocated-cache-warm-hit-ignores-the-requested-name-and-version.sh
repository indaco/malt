#!/usr/bin/env bash
# Regression: a relocated-cache snapshot must only be restored under the
# name/version it was taken as.
#
# The bug: `store-relocated/v<N>/<sha>` was keyed by bottle sha alone and
# carried no record of the label it was snapshotted under. The warm path in
# `materializeWithCellar` probed the cache before it ever resolved
# `store/<sha>/<name>/<version>`, so a tap that served one bottle sha under
# two labels got a correctly relocated, `.verified`-trusted keg of package A
# cloned into `Cellar/<B>/<ver>`, receipted and DB-recorded as package B -
# exactly the case the cold path refuses with `KegSourceMissing`.
#
# Two arms, both offline:
#   1. the label sidecar, its error and the eviction on mismatch stay in the
#      tree;
#   2. the cellar integration suite, which pins that a warm hit for a label
#      the snapshot was not taken under is refused and evicted.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# --- Arm 1: the label check cannot be silently removed -----------------------
if ! grep -Fq "LabelMismatch" src/core/relocated_store.zig; then
  echo "FAIL: RelocatedStoreError.LabelMismatch is gone" >&2
  exit 1
fi
if ! grep -Fq '.keg"' src/core/relocated_store.zig; then
  echo "FAIL: relocated_store no longer writes the <sha>.keg label mark" >&2
  exit 1
fi
if ! grep -Fq "LabelMismatch" src/core/cellar.zig; then
  echo "FAIL: the warm path no longer evicts on LabelMismatch" >&2
  exit 1
fi

# --- Arm 2: the refusal holds at runtime -------------------------------------
BIN="$ROOT/zig-out/test-bin/cellar_test"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/malt-reg-warmlabel.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
if ! MALT_PREFIX="$SCRATCH" "$BIN" >"$SCRATCH/log" 2>&1; then
  echo "FAIL: a relocated snapshot was restored under a name/version it was not taken as" >&2
  tail -n 30 "$SCRATCH/log" >&2
  exit 1
fi

echo "OK: warm hit refuses a label the snapshot was not taken under"
