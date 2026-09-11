#!/usr/bin/env bash
# Regression: a Mach-O the relocation walk rewrote must reach the re-sign list.
#
# The bug: `walkMachOAndPatch` patched a binary's load commands in place and
# only then appended its path to the list `adHocSignAll` re-signs. That append
# was `catch continue`, so an allocation failure at that point left a file
# whose bytes no longer matched its ad-hoc code directory, with no entry in
# the re-sign list. The walk reported success, the keg was recorded, and on
# arm64 the kernel killed the binary at exec. The same shape existed one step
# earlier: an OOM while `patchPathsCollecting` collected overflow slots, after
# it had already written the file, was swallowed by the same blanket skip.
#
# The fix surfaces both post-write OOMs as `CellarError.OutOfMemory`, so the
# caller's errdefer wipes the half-relocated keg instead of installing it.
#
# The walk is file-private, so the guard is a colocated `test {}` block that
# sweeps `FailingAllocator.fail_index` over the walk. This script has two
# halves: a static check that the append no longer swallows its failure (the
# fast half), and a run of the colocated test binary that judges the sweep's
# line. Both are needed: the grep alone proves nothing about behaviour, and
# the test alone goes vacuously green if the test is renamed away.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes in about a minute. Cleans up its scratch prefix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/cellar.zig"

# Static half: the append must not swallow its failure.
if grep -qs -- 'modified_out.append(allocator, full_path) catch continue' "$SRC"; then
  echo "FAIL: walkMachOAndPatch still drops a mutated Mach-O when the append fails" >&2
  exit 1
fi

FILTER="walkMachOAndPatch never returns success having mutated a file it did not queue for re-signing"

# If the guard test is ever deleted the name filter would match nothing and
# silently pass. Fail loudly instead.
if ! grep -qs -- "$FILTER" "$SRC"; then
  echo "FAIL: append-failure sweep test missing from src/core/cellar.zig" >&2
  exit 1
fi

# Always rebuild: a stale binary from an earlier run cannot contain the guard.
BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# No `timeout`: macOS does not ship one and this runs in the CI job that
# does not install coreutils; the job's own time limit bounds a hang.
# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
OUT=$(MALT_PREFIX="$SCRATCH" "$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: append-failure sweep test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a mutated Mach-O can still be dropped from the re-sign list" >&2
  exit 1
fi

echo "PASS: a mutated Mach-O always reaches the re-sign list or aborts the materialize"
