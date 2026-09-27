//! malt — RFC 8259 string escaping for handwritten JSON output.
//!
//! Lives outside `ui/` because the leaves emit JSON too: the version-notifier
//! cache writes its state file with these, and a leaf reaching into the UI
//! layer for an escaper is the coupling the modularity constraint forbids.

const std = @import("std");

/// Write `s` to `w` as a JSON string literal — surrounding quotes plus RFC 8259
/// escapes for `"`, `\`, and control characters, DEL and UTF-8 C1 included.
/// Use this wherever handwritten JSON output embeds an identifier, tap name,
/// version string, file path, or anything else that might contain special characters.
pub fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const byte = s[i];
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (escape) |esc| {
            if (i > start) try w.writeAll(s[start..i]);
            try w.writeAll(esc);
            start = i + 1;
        } else {
            // Valid JSON as-is, but `--json` often lands on a TTY, where DEL
            // and a UTF-8 C1 (U+0080-U+009F, 0xC2 0x80-0x9F) act on it.
            const is_c1 = byte == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F;
            if (byte >= 0x20 and byte != 0x7f and !is_c1) continue;
            if (i > start) try w.writeAll(s[start..i]);
            const code: u8 = if (is_c1) s[i + 1] else byte;
            var hex_buf: [6]u8 = undefined;
            // `\u` + 4 hex digits = 6 bytes exactly; bufPrint cannot overflow a 6-byte buffer.
            const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{code}) catch unreachable;
            try w.writeAll(hex);
            if (is_c1) i += 1;
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

/// Write a `["a","b",...]` JSON array of RFC-8259-escaped strings to `w`.
pub fn jsonStringArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(",");
        try jsonStr(w, item);
    }
    try w.writeAll("]");
}

test "jsonStr escapes the characters that would otherwise break the document" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try jsonStr(&w, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", w.buffered());
}

test "jsonStr escapes the control bytes that have no short form" {
    // A tap name or path carrying a raw control byte must not be emitted
    // literally - consumers reject the document, and the value is attacker
    // influenced on the cask/tap paths.
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try jsonStr(&w, "a\x01b");
    try std.testing.expectEqualStrings("\"a\\u0001b\"", w.buffered());
}

test "jsonStr escapes DEL and UTF-8 C1 so a terminal never receives them raw" {
    // `--json` often lands on a TTY, where U+009B is a one-byte CSI.
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const s = "a\x7fb\xc2\x80c\xc2\x9bd\xc2\x9fe\xc2\xa0f\xc2";
    try jsonStr(&w, s);
    // NBSP (U+00A0) is printable and a lone trailing 0xC2 is no C1: both stay.
    try std.testing.expectEqualStrings("\"a\\u007fb\\u0080c\\u009bd\\u009fe\xc2\xa0f\xc2\"", w.buffered());

    // The decoded value is unchanged.
    var w2: std.Io.Writer = .fixed(&buf);
    try jsonStr(&w2, s[0 .. s.len - 1]);
    const decoded = try std.json.parseFromSlice([]const u8, std.testing.allocator, w2.buffered(), .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(s[0 .. s.len - 1], decoded.value);
}

test "jsonStringArray wraps each escaped element" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try jsonStringArray(&w, &.{ "one", "t\"wo" });
    try std.testing.expectEqualStrings("[\"one\",\"t\\\"wo\"]", w.buffered());
}
