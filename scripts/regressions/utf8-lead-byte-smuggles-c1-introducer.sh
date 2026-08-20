#!/usr/bin/env bash
# Regression: the sanitizer armed its UTF-8 continuation counter from a length
# classifier, which answers "how many bytes would this lead occupy" and never
# "is this a legal lead". Ill-formed leads (C0/C1, F5..F7) and ill-formed
# continuations (overlong, surrogate, beyond U+10FFFF) therefore opened a 1-3
# byte window in which the raw 8-bit C1 introducers 0x9B (CSI) and 0x9D (OSC)
# reached the terminal without ever passing the CSI whitelist or the OSC drop.
#
# The sanitizer has no standalone CLI surface (it wraps child stdout/stderr), so
# a standalone ReleaseSafe `zig test` harness drives Sanitizer.feed/flush and
# scrubInPlace directly and asserts on the emitted bytes. It checks both
# directions: no hostile form emits a byte in 0x80..0x9F, and legitimate UTF-8 --
# including a codepoint whose own continuation byte is 0x9B -- still passes
# byte-identically, so a blanket C1 drop does not make it pass.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The standalone harness proves the byte-level property directly, but it cannot
# notice the real tests being deleted, so guard their names too.
while IFS= read -r name; do
  if ! grep -Fqs -- "$name" "$ROOT/tests/term_sanitize_test.zig"; then
    echo "FAIL: the ill-formed UTF-8 test is missing from tests/term_sanitize_test.zig: $name" >&2
    exit 1
  fi
done <<'NAMES'
invalid UTF-8 lead does not arm the continuation counter
overlong sequence cannot carry an 8-bit C1 introducer
NAMES

# The harness imports the sanitizer via a repo-relative path, so it must sit at
# the repo root for the source tree's module boundary to resolve; $$ keeps
# concurrent runs from clobbering each other's file.
HARNESS="$ROOT/.utf8-lead-c1-regression.$$.zig"
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

fn expectNoC1(bytes: []const u8) !void {
    for (bytes) |b| try std.testing.expect(b < 0x80 or b > 0x9F);
}

const hostile = [_][]const u8{
    "\xC0\x9B>4;2m", // C0 is never a legal lead: armed 1 byte
    "\xC1\x9B>4;2m",
    "\xF5\x9B\x9D", // F5..F7 armed 3 bytes: two introducers at once
    "\xF6\x9B\x9D",
    "\xF7\x9B\x9D",
    "\xE0\x80\x9B", // overlong 3-byte
    "\xF0\x80\x80\x9B", // overlong 4-byte
    "\xED\xA0\x9B", // surrogate
    "\xF4\x90\x9B\x9D", // beyond U+10FFFF
};

test "no ill-formed sequence lets an 8-bit C1 introducer through" {
    for (hostile) |bad| {
        var b: Buf = .{};
        defer b.deinit();
        try run(bad, &b);
        try expectNoC1(b.list.items);

        var copy: [16]u8 = undefined;
        @memcpy(copy[0..bad.len], bad);
        try expectNoC1(ts.scrubInPlace(copy[0..bad.len]));
    }
}

test "an OSC 52 clipboard payload introduced by an invalid lead is dropped whole" {
    var b: Buf = .{};
    defer b.deinit();
    try run("\xC0\x9D" ++ "52;c;ZXZpbA==" ++ "\x07", &b);
    try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
}

test "legitimate UTF-8 still passes byte-identically" {
    // U+D6C0 is the case that matters: its continuation byte IS 0x9B, so a
    // blanket C1 drop would fail here.
    const good = [_][]const u8{ "\xC3\xA9", "\xF0\x9F\x8D\xBA", "\xED\x9B\x80", "Caf\xC3\xA9 \xE2\x98\x95" };
    for (good) |ok| {
        var b: Buf = .{};
        defer b.deinit();
        try run(ok, &b);
        try std.testing.expectEqualStrings(ok, b.list.items);

        var copy: [32]u8 = undefined;
        @memcpy(copy[0..ok.len], ok);
        try std.testing.expectEqualStrings(ok, ts.scrubInPlace(copy[0..ok.len]));
    }
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: ill-formed UTF-8 cannot smuggle an 8-bit C1 introducer"
else
  echo "FAIL: an ill-formed UTF-8 lead still opens a raw byte window" >&2
  exit 1
fi
