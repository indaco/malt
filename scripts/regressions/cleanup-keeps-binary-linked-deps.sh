#!/usr/bin/env bash
# Regression (defense-in-depth): `cleanup` (`purge --housekeeping`) must
# never delete a dependency that a still-installed package's Mach-O
# actually links, even when the `dependencies` table has lost the edge.
# `findOrphans` trusts the table alone, so a single dropped edge would
# otherwise let `runUnusedDeps` reap a live runtime dependency.
#
# The guard probes installed binaries (LC_LOAD_DYLIB into `opt/<name>/`)
# before reaping an orphan and keeps anything still linked. No CLI path
# seeds a corrupted-table-plus-live-linkage state in isolation, so the
# guard is a colocated `test {}` that builds a fake dependent binary,
# drops the edge, runs the scope, and asserts the dependency survives.
# This script builds the test binary and judges that test by name; it
# exits non-zero if the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in about a minute once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="runUnusedDeps keeps a dependency a still-installed keg's Mach-O links despite a missing edge"

if ! grep -Rqs -- "$FILTER" "$ROOT/src/cli/purge/scopes.zig"; then
  echo "FAIL: the cleanup binary-linkage guard test is missing from scopes.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin -Doptimize=ReleaseSafe >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the cleanup binary-linkage guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: cleanup reaped a dependency a binary still links" >&2
  exit 1
fi

echo "PASS: cleanup keeps dependencies that installed binaries still link"
