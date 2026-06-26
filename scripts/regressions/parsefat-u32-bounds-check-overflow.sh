#!/usr/bin/env bash
# Regression: a fat header whose fat_arch offset+size overflows 32-bit
# arithmetic must be rejected with a clean ParseError.TruncatedFile, not a
# panic (safe builds) or an out-of-bounds slice (ReleaseFast).
#
# The bug: parseFat read the slice offset and size as u32 and computed both
# the bounds check (offset+size > data.len) and the slice expression in u32.
# A crafted offset+size summing past 0xFFFFFFFF wrapped to a small value: in
# Debug/ReleaseSafe the add panicked (integer overflow → SIGABRT, which the
# patcher's `catch` cannot contain — a DoS on a malicious-tap bottle); in
# ReleaseFast the wrapped sum passed the guard and produced an illegal
# start>end slice. The input is fully untrusted bottle bytes from a tap.
#
# The fix widens both fields to usize at the read site. Both are ≤ 2³², so
# their sum fits a 64-bit usize and the bounds check stays honest.
#
# No CLI surface drives parseFat offline without standing up a tap, so the
# guard is exercised by the colocated integration test in tests/macho_test.zig
# (the `macho_test` binary). This script builds and runs only that binary: it
# stays well under 30s and needs no network. Pre-fix the overflow test panics
# and aborts the binary (non-zero exit); post-fix it returns the expected
# error and the suite is green.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="tests/macho_test.zig"
TEST_NAME="parse rejects a fat slice whose offset+size overflows 32 bits"

# If the test is ever dropped, the binary would go green vacuously. Fail loudly.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the fat-slice overflow guard test is missing from $SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/macho_test"
# Always rebuild so the binary reflects current source — a prebuilt binary
# could predate the fix. Zig's cache makes a no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the suite and judge by exit code.
# Pre-fix, parseFat panics on the overflowing offset+size and the process is
# killed by a signal (exit > 128), so the suite exits non-zero.
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: parseFat panicked or admitted an out-of-bounds fat slice on u32 overflow" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic|overflow" >&2 || true
  exit 1
fi

echo "PASS: parseFat rejects a u32-overflowing fat slice with a clean error"
