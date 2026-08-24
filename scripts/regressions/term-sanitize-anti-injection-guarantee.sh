#!/usr/bin/env bash
# Regression: the terminal sanitizer promises a hostile formula's post_install
# output cannot rewrite scrollback or exfiltrate via terminal extensions. Three
# gaps broke that guarantee:
#   - passable() admitted every byte >= 0x80, so the 8-bit C1 introducers
#     (0x80..0x9F: CSI/OSC/DCS/ST) passed verbatim, re-opening OSC 52.
#   - a CSI buffered any non-final byte, replaying smuggled C0 (e.g. BEL) or ESC.
#   - csiAllowed keyed only on the final byte, so `CSI 3 J` erased scrollback.
#
# The sanitizer has no standalone CLI surface (it wraps child stdout/stderr), so
# a standalone ReleaseSafe `zig test` harness drives Sanitizer.feed/flush through
# a capturing sink and asserts on the emitted bytes: the three hostile inputs
# drop to nothing while legitimate UTF-8 (whose continuation bytes fall in the
# C1 range) and whitelisted SGR/erase sequences pass intact.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The harness imports the sanitizer via a repo-relative path, so it must sit at
# the repo root for the source tree's module boundary to resolve.
HARNESS="$ROOT/.term-sanitize-anti-injection-regression.$$.zig"
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

test "8-bit OSC 52 (C1 introducers) dropped" {
    var b: Buf = .{};
    defer b.deinit();
    try run("\x9d52;c;cHduZWQ=\x9c", &b);
    try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
}

test "BEL smuggled inside a CSI dropped" {
    var b: Buf = .{};
    defer b.deinit();
    try run("\x1b[\x07m", &b);
    try std.testing.expect(std.mem.indexOfScalar(u8, b.list.items, 0x07) == null);
}

test "CSI 3 J (erase scrollback) dropped" {
    var b: Buf = .{};
    defer b.deinit();
    try run("\x1b[3J", &b);
    try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
}

test "legit UTF-8 with C1-range continuation preserved" {
    // é=C3 A9, ✓=E2 9C 93 — the 0x9C continuation byte lands in the C1 range.
    var b: Buf = .{};
    defer b.deinit();
    try run("caf\xc3\xa9 \xe2\x9c\x93", &b);
    try std.testing.expectEqualStrings("caf\xc3\xa9 \xe2\x9c\x93", b.list.items);
}

test "whitelisted SGR + screen erase still pass" {
    var b: Buf = .{};
    defer b.deinit();
    try run("\x1b[31mX\x1b[0m\x1b[2J", &b);
    try std.testing.expectEqualStrings("\x1b[31mX\x1b[0m\x1b[2J", b.list.items);
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: sanitizer enforces its anti-injection guarantee"
else
  echo "FAIL: sanitizer leaked a C1/C0/scrollback sequence" >&2
  exit 1
fi
