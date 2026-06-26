#!/usr/bin/env bash
# Regression: the copy/move DSL builtins must confine their SOURCE path to the
# keg, not only their destination.
#
# The bug: `mv`/`cp`/`cp_r` validated only the destination argument and passed
# the source straight to `renameAbsolute`/`copyFileAbsolute`. A formula could
# `mv` an out-of-keg file into the keg (rename unlinks the original), or
# `cp`/`cp_r` an arbitrary readable file — or a keg-planted symlink pointing
# outside — into the keg and `.read` it back, exfiltrating its contents. The
# destination guard says where bytes land; it says nothing about where bytes
# come from.
#
# No CLI subcommand exposes a raw copy/move builtin in isolation, so the guard
# is exercised by colocated `test {}` blocks that plant the out-of-keg source
# (direct path and via symlink), call the builtin, and assert both rejection
# and that nothing escaped or was read in. This script builds the colocated
# test binary and runs those tests by name; it exits non-zero if a guard
# regresses or a test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s once the test binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/dsl/builtins/fileutils.zig"

# The guards live in colocated `test {}` blocks; if any is ever deleted the
# name filter below would match nothing and silently pass. Fail loudly instead.
FILTERS=(
  "mv refuses to move a source from outside the keg"
  "cp refuses to copy a source from outside the keg"
  "cp refuses to read through a source symlink out of the keg"
)
for F in "${FILTERS[@]}"; do
  if ! grep -Rqs -- "$F" "$SRC"; then
    echo "FAIL: source-confinement guard test missing: $F" >&2
    exit 1
  fi
done

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite and judge only
# these guards' lines: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
for F in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$F" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: source-confinement guard test did not run: $F" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: a copy/move builtin read or moved an out-of-keg source: $F" >&2
    exit 1
  fi
done

echo "PASS: cp/mv/cp_r source paths confined to the keg"
