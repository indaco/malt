#!/usr/bin/env bash
# Regression: the `chmod` DSL builtin must mask a formula-supplied mode down to
# the permission bits, not narrow it through i32/u16. A mode arrives as an i64;
# values outside i32 range, negative values, or values past mode_t (u16) hit a
# checked cast that aborts the whole `mt` process in a safe build — a malformed
# formula could crash malt mid-evaluation instead of degrading.
#
# No CLI subcommand drives the builtin without a network install, and a real
# cast panic aborts the test runner, so a standalone ReleaseSafe `zig test`
# harness drives chmod with an out-of-range mode against a temp keg file. The
# harness must reach its assertion without aborting; if chmod narrows the mode
# the @intCast aborts and `zig test` dies by signal (exit > 128).
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The harness imports the builtin via a repo-relative path, so it must sit at the
# repo root: the builtin's sibling imports (`../values.zig`, `../sandbox.zig`)
# only resolve from inside the source tree's module boundary.
HARNESS="$ROOT/.chmod-mode-cast-regression.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const fileutils = @import("src/core/dsl/builtins/fileutils.zig");

// An i64 mode well outside i32 range: the old cast chain aborted here.
test "chmod masks an out-of-range mode instead of narrowing" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const keg = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];
    const file = try std.fs.path.join(alloc, &.{ keg, "x" });
    defer alloc.free(file);
    (try std.Io.Dir.createFileAbsolute(io, file, .{})).close(io);

    const v = try fileutils.chmod(.{
        .allocator = alloc,
        .io = io,
        .environ = std.process.Environ.empty,
        .cellar_path = keg,
        .malt_prefix = keg,
    }, null, &.{ .{ .int = 9999999999 }, .{ .string = file } });
    try std.testing.expect(v == .nil);
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: chmod masks an out-of-range mode instead of narrowing through i32"
else
  echo "FAIL: chmod aborted on an out-of-range mode (narrowed instead of masked)" >&2
  exit 1
fi
