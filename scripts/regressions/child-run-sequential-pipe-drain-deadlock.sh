#!/usr/bin/env bash
# Regression: core/child.run must drain stdout and stderr concurrently. A child
# that floods one stream past the kernel pipe buffer (~64 KiB on Darwin) while
# the other stays open blocks in write(2); if run drains the streams one after
# the other the child never exits, the first drain never sees EOF, and malt
# hangs forever on the install path (runOrFail wraps hdiutil/ditto/codesign).
#
# child.zig imports only std, so it is pulled in as a standalone module and the
# shipped run() is exercised directly — no copy, no full build. The driver
# spawns `/bin/sh -c` (banned under src/ by the spawn invariant, fine here) to
# flood >64 KiB to stderr with stdout held open, under a hard timeout.
#
# Exits 0 when both pipes drain concurrently (child returns, full stderr
# captured), non-zero with a clear message when run deadlocks or captures short.
# No network; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/driver.zig" <<'ZIG'
const std = @import("std");
const child = @import("child");

pub fn main() !void {
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    // >64 KiB to stderr while stdout stays open until sh exits.
    const argv = [_][]const u8{ "/bin/sh", "-c", "yes | head -c 200000 1>&2" };
    var r = try child.run(t.io(), std.heap.page_allocator, &argv);
    defer r.deinit(std.heap.page_allocator);
    if (r.stderr.len < 200000) std.process.exit(3);
}
ZIG

if ! zig build-exe -femit-bin="$TMP/driver" \
  --dep child -Mmain="$TMP/driver.zig" \
  -Mchild="$ROOT/src/core/child.zig" >/dev/null 2>&1; then
  echo "FAIL: driver build error" >&2
  exit 2
fi

set +e
timeout 20 "$TMP/driver"
rc=$?
set -e

if [ "$rc" -eq 124 ]; then
  echo "FAIL: child.run deadlocked draining a >64KiB stderr stream" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "FAIL: child.run errored or captured short (rc=$rc)" >&2
  exit 1
fi

echo "PASS: child.run drained both pipes concurrently"
