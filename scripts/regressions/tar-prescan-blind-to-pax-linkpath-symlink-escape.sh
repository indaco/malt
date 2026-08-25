#!/usr/bin/env bash
# Regression: a tar.gz whose symlink target escapes the destination *only*
# via a pax `linkpath` override (the ustar linkname stays benign) must be
# rejected by malt's extract path.
#
# The bug: the tar pre-scan validated only the 100-byte ustar linkname and
# discarded pax extended headers. std.tar's extractor applies a pax
# `linkpath` over that field and symlinks it verbatim, so a tap-controlled
# archive could plant a symlink pointing outside the destination while the
# benign ustar linkname sailed past the guard.
#
# No CLI subcommand drives a raw archive extract in isolation, so the guard
# is exercised by a colocated `test {}` that builds such an archive in a temp
# dir and asserts `extractTarGz` returns `error.ExtractionFailed`. This script
# builds the test binary and judges that test by name; it exits non-zero if
# the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes in about a minute once the test binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="extractTarGz rejects a pax linkpath that escapes the destination"

# The guard lives in a colocated `test {}`; if it is ever deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/fs/archive.zig"; then
  echo "FAIL: the pax symlink-target guard test is missing from archive.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the pax symlink-target guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a pax linkpath override escaped the destination unchecked" >&2
  exit 1
fi

echo "PASS: pax linkpath symlink escape rejected"
