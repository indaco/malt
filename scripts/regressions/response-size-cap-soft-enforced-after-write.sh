#!/usr/bin/env bash
# Regression: the response size cap must be enforced *before* the inner
# Allocating writer grows to hold the bytes, so no response body byte is ever
# committed past max_bytes.
#
# The bug: CountingWriter.drain delegated to the backing Allocating writer —
# which grows its heap buffer for the incoming chunk — and only then compared
# the running total against max_bytes. A response body (or a decompression
# bomb) was therefore allocated up to one drain/decompress window past the cap
# before error.WriteFailed -> error.ResponseTooLarge tripped, making the cap
# soft rather than the strict bound the surrounding transport docs imply.
#
# The fix counts the incoming bytes (countSplat) and refuses the over-cap
# chunk before delegating; sendFile clamps its source limit for the same
# reason. Peak allocation now stays at or below max_bytes.
#
# Two guards: a structural check that the bound test precedes the inner write
# in drain(), and the behavioural inline tests that drive drain() over a real
# Allocating writer and assert the committed length never exceeds the cap. Both
# are in-process: no network, well under the time budget.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

# 1) structural guard: inside fn drain(), the bound check must come before the
#    inner writer's drain delegation. If the order flips, the cap goes soft.
drain_body=$(awk '/fn drain\(w: \*std\.Io\.Writer/,/^        }$/' "$SRC")
check_line=$(grep -n 'countSplat\|max_bytes' <<<"$drain_body" | head -1 | cut -d: -f1 || true)
write_line=$(grep -n 'inner.vtable.drain' <<<"$drain_body" | head -1 | cut -d: -f1 || true)
if [ -z "$check_line" ] || [ -z "$write_line" ] || [ "$check_line" -gt "$write_line" ]; then
  echo "FAIL: CountingWriter.drain writes before enforcing max_bytes (soft cap)" >&2
  exit 1
fi

# 2) behavioural guard: the inline cap tests must pass. Rebuild the unit binary
#    so it reflects current source (Zig's cache keeps a no-op rebuild cheap),
#    then run the whole suite — zig 0.16 has no reliable per-test filter.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: response cap unit test failed — bytes committed past max_bytes" >&2
  printf '%s\n' "$OUT" | grep -iE "CountingWriter|failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: response size cap enforced before the write"
