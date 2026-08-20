#!/usr/bin/env bash
# Regression: the CSI whitelist keyed only on the final byte, so every buffered
# parameter byte was replayed verbatim. A private prefix or an intermediate byte
# changes which command a sequence is -- `CSI > 4 ; 2 m` is XTMODKEYS (it
# rewrites the terminal's modifier-key reporting), not SGR -- so a whitelisted
# final admitted a whole family of commands the whitelist never reviewed.
#
# The sanitizer has no standalone CLI surface (it wraps child stdout/stderr), so
# a standalone ReleaseSafe `zig test` harness drives Sanitizer.feed/flush through
# a capturing sink and asserts on the emitted bytes. It checks both directions:
# hostile private/intermediate forms drop to nothing, and legitimate numeric
# SGR/erase/motion still passes byte-identically -- so simply disabling the
# whitelist does not make it pass.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The standalone harness proves the byte-level property directly, but it cannot
# notice the real tests being deleted, so guard their names too.
while IFS= read -r name; do
  if ! grep -Fqs -- "$name" "$ROOT/tests/term_sanitize_test.zig"; then
    echo "FAIL: the CSI parameter test is missing from tests/term_sanitize_test.zig: $name" >&2
    exit 1
  fi
done <<'NAMES'
private-prefix CSI with a whitelisted final dropped
intermediate byte CSI with a whitelisted final dropped
private prefix via the 8-bit CSI introducer dropped
NAMES

# The harness imports the sanitizer via a repo-relative path, so it must sit at
# the repo root for the source tree's module boundary to resolve; $$ keeps
# concurrent runs from clobbering each other's file.
HARNESS="$ROOT/.csi-private-param-regression.$$.zig"
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

test "private-parameter and intermediate CSI forms drop" {
    const hostile = [_][]const u8{
        "\x1b[>4;2m", // XTMODKEYS: rewrites modifier-key reporting
        "\x1b[?4m", // XTQMODKEYS: terminal writes a report into stdin
        "\x1b[<0;0;0m",
        "\x1b[=5m",
        "\x1b[0;1$m",
        "\x1b[!K",
        "\x1b[ A", // SL (scroll left) smuggled under the cursor-up arm
    };
    for (hostile) |bad| {
        var b: Buf = .{};
        defer b.deinit();
        try run(bad, &b);
        try std.testing.expectEqual(@as(usize, 0), b.list.items.len);
    }
}

test "legitimate numeric sequences still pass byte-identically" {
    const good = [_][]const u8{
        "\x1b[0m",
        "\x1b[1;31m",
        "\x1b[4:3m", // SGR subparameters: curly underline
        "\x1b[2K",
        "\x1b[2J",
        "\x1b[3A",
    };
    for (good) |ok| {
        var b: Buf = .{};
        defer b.deinit();
        try run(ok, &b);
        try std.testing.expectEqualStrings(ok, b.list.items);
    }
}

test "text around a dropped sequence survives" {
    var b: Buf = .{};
    defer b.deinit();
    try run("ab\x1b[>4;2mcd", &b);
    try std.testing.expectEqualStrings("abcd", b.list.items);
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: CSI whitelist rejects non-numeric parameter bytes"
else
  echo "FAIL: CSI whitelist still replays private/intermediate parameter bytes" >&2
  exit 1
fi
