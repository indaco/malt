#!/usr/bin/env bash
# Regression: an in-process DSL filesystem builtin must not write through a
# keg-confined symlink to a file outside the keg.
#
# The bug: `sandbox.validatePath` only inspects the literal path string, while
# the write-path builtins opened with `O_CREAT|O_WRONLY|O_TRUNC` and no
# `O_NOFOLLOW`. A formula could plant `keg/pwn -> /outside/victim`, then write
# `keg/pwn` — the literal check passed and the kernel followed the link,
# truncating an arbitrary file as the user running malt.
#
# No CLI subcommand exposes a raw write builtin in isolation, so the guard is
# exercised by a focused unit test that plants the symlink, calls the builtin,
# and asserts both rejection and that the out-of-keg file is byte-for-byte
# untouched. This script builds the colocated test binary and runs that test by
# name; it exits non-zero if the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s once the test binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="write refuses to follow a symlink out of the keg"

# The guard lives in a colocated `test {}` block; if it is ever deleted the
# name filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/core/dsl/builtins/pathname.zig"; then
  echo "FAIL: the symlink-follow guard test is missing from pathname.zig" >&2
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
  echo "FAIL: the symlink-follow guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a DSL write builtin followed a keg-confined symlink out of the keg" >&2
  exit 1
fi

echo "PASS: keg-confined symlink not followed to an out-of-keg write"
