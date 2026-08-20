#!/usr/bin/env bash
# Regression: the CSI whitelist admitted A/B/E/F with any count, so a child could
# emit `ESC[999A`, erase the line and repaint it -- a deterministic seek to any
# earlier row of the visible screen. H/f were banned to deny exactly that
# primitive; relative motion handed it back. Capping the count only prices the
# attack (small hops repeat, and any count clamps at the viewport edge), so
# vertical motion drops outright and CR remains the way to redraw a line.
#
# The sanitizer has no standalone CLI surface (it wraps child stdout/stderr), so
# a standalone ReleaseSafe `zig test` harness drives Sanitizer.feed/flush through
# a capturing sink and asserts on the emitted bytes. It checks both directions:
# every vertical form drops to nothing, and CR progress plus horizontal motion
# still pass byte-identically -- so deleting the whitelist does not make it pass.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The standalone harness proves the byte-level property directly, but it cannot
# notice the real tests being deleted, so guard their names too.
while IFS= read -r name; do
  if ! grep -Fqs -- "$name" "$ROOT/tests/term_sanitize_test.zig"; then
    echo "FAIL: the cursor motion test is missing from tests/term_sanitize_test.zig: $name" >&2
    exit 1
  fi
done <<'NAMES'
vertical cursor motion dropped
CR still redraws the child's own line
a seek split across feed() calls still drops
NAMES

# The harness imports the sanitizer via a repo-relative path, so it must sit at
# the repo root for the source tree's module boundary to resolve; $$ keeps
# concurrent runs from clobbering each other's file.
HARNESS="$ROOT/.relative-motion-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const ts = @import("src/ui/term_sanitize.zig");

const Buf = struct {
    list: std.ArrayList(u8) = .empty,

    fn sink(self: *Buf) ts.Sink {
        return .{ .ctx = self, .write_fn = writeFn };
    }
    fn writeFn(ctx: *anyopaque, bytes: []const u8) ts.SinkError!void {
        const self: *Buf = @ptrCast(@alignCast(ctx));
        self.list.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
    }
    fn deinit(self: *Buf) void {
        self.list.deinit(std.testing.allocator);
    }
};

fn run(input: []const u8, out: *Buf) !void {
    var s = ts.Sanitizer.init();
    try s.feed(input, out.sink());
    try s.flush(out.sink());
}

test "a seek across the viewport loses its motion" {
    // The line erase stays: the child owns the line it is writing. Only the
    // vertical seek onto rows malt printed is dropped.
    var b: Buf = .{};
    defer b.deinit();
    try run("\x1b[10A\x1b[2Kok: verified\x1b[10B", &b);
    try std.testing.expectEqualStrings("\x1b[2Kok: verified", b.list.items);
}

test "every vertical motion form drops" {
    const hostile = [_][]const u8{
        "\x1b[A", // default count: still another line
        "\x1b[1A", // one hop, repeatable to any distance
        "\x1b[9A",
        "\x1b[999A",
        "\x1b[1B",
        "\x1b[99B",
        "\x1b[9E",
        "\x1b[40F",
        "\x1b[99999999999999999999A", // wider than any integer the parser could hold
        "\x1b[0000000009A", // leading zeros hide the magnitude from a digit count
        "\x1b[1;999A",
        "\x9b9A", // the 8-bit CSI introducer must not be a second door
    };
    for (hostile) |bad| {
        var b: Buf = .{};
        defer b.deinit();
        try run(bad, &b);
        try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
    }
}

test "repeated small hops cannot accumulate into a seek" {
    // The reason a count cap was not enough: nine of these reached 81 rows.
    var b: Buf = .{};
    defer b.deinit();
    try run("\x1b[9A" ** 9, &b);
    try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
}

test "a seek split across write boundaries still drops" {
    // The child picks its own write boundaries; the params buffer spans them.
    var b: Buf = .{};
    defer b.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("a\x1b[9", b.sink());
    try s.feed("9", b.sink());
    try s.feed("Ab", b.sink());
    try s.flush(b.sink());
    try std.testing.expectEqualStrings("ab", b.list.items);
}

test "CR progress and horizontal motion still pass byte-identically" {
    const good = [_][]const u8{
        "50%\r100%", // in-place progress needs no CSI at all
        "\x1b[C",
        "\x1b[5C",
        "\x1b[40G",
        "\x1b[2K",
        "\x1b[0m",
        "\x1b[1;31m",
    };
    for (good) |ok| {
        var b: Buf = .{};
        defer b.deinit();
        try run(ok, &b);
        try std.testing.expectEqualStrings(ok, b.list.items);
    }
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: child output cannot reach another line"
else
  echo "FAIL: sanitized child output can still reach an earlier visible line" >&2
  exit 1
fi
