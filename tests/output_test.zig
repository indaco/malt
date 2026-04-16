//! malt — ui/output tests
//! Pinpoint coverage for `output.jsonStr`, the helper every CLI command uses
//! to emit JSON-safe string values. Verifies the RFC 8259 escape contract on
//! adversarial inputs and round-trips the result through std.json to prove
//! the bytes are accepted by a strict parser.

const std = @import("std");
const testing = std.testing;
const output = @import("malt").output;
const io_mod = @import("malt").io_mod;

fn encode(s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try output.jsonStr(&aw.writer, s);
    return aw.toOwnedSlice();
}

test "jsonStr leaves plain ASCII alone" {
    const got = try encode("openssl@3");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"openssl@3\"", got);
}

test "jsonStr emits empty quoted string for empty input" {
    const got = try encode("");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"\"", got);
}

test "jsonStr escapes the seven RFC 8259 short-form characters" {
    const got = try encode("a\"b\\c\nd\re\tf\x08g\x0ch");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\\bg\\fh\"", got);
}

test "jsonStr emits \\u00XX for control characters below 0x20" {
    const got = try encode("\x01\x1f");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"\\u0001\\u001f\"", got);
}

test "jsonStr passes UTF-8 bytes through unchanged" {
    // emoji, accented letter — outside the escape set, must round-trip.
    const got = try encode("café 🍺");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"café 🍺\"", got);
}

// Regression: under the test runner, `io_mod.stdoutFile()` must resolve to
// stderr. The runner owns fd 1 for its IPC; any byte on it wedges the
// build runner in `read()`. If this assertion breaks, `zig build test`
// starts deadlocking again.
test "stdoutFile redirects to stderr under the test runner" {
    try testing.expectEqual(std.Io.File.stderr().handle, io_mod.stdoutFile().handle);
}

// Regression (paired with the helper above): exercising a call site that
// previously deadlocked — `stdoutWriteAll` of a multi-KB payload — must
// complete without hanging and must not land on fd 1.
test "stdoutWriteAll through the redirected path completes without blocking" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 'x');
    io_mod.stdoutWriteAll(&buf);
}

test "jsonStr output round-trips through std.json parser" {
    const inputs = [_][]const u8{
        "name with \"quote\"",
        "C:\\path\\to\\file",
        "line\nbreak",
        "\t\rmixed\x05controls",
        "",
        "café 🍺",
    };
    for (inputs) |s| {
        const encoded = try encode(s);
        defer testing.allocator.free(encoded);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(s, parsed.value.string);
    }
}
