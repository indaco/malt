//! malt — ui/output tests
//! Pinpoint coverage for `output.jsonStr`, the helper every CLI command uses
//! to emit JSON-safe string values. Verifies the RFC 8259 escape contract on
//! adversarial inputs and round-trips the result through std.json to prove
//! the bytes are accepted by a strict parser.

const std = @import("std");
const testing = std.testing;
const output = @import("malt").output;

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
