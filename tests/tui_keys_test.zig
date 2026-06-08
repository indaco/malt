//! malt — integration tests for the `tui/keys.zig` keyboard decoder.
//!
//! Table-driven over byte slices: every supported key is asserted to decode to
//! the right `Key` with the right `consumed` count. Split-across-reads, lone
//! ESC, unknown sequences, Ctrl-C, and UTF-8 round out the cases. No PTY — the
//! decoder is a pure DFA, so byte slices are all it takes.

const std = @import("std");
const testing = std.testing;
const keys = @import("malt").tui_keys;

const Key = keys.Key;

fn keyEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .char => |c| std.mem.eql(u8, c.slice(), b.char.slice()),
        // Closed switch: a new payload-carrying arm forces a decision here.
        .up, .down, .left, .right, .enter, .space, .tab, .esc, .backspace, .ctrl_c, .page_up, .page_down, .home, .end, .unknown => true,
    };
}

fn expectKey(input: []const u8, want: Key, want_consumed: usize) !void {
    var d: keys.Decoder = .{};
    const r = d.decode(input);
    try testing.expect(r == .key);
    try testing.expectEqual(want_consumed, r.key.consumed);
    if (!keyEql(want, r.key.key)) {
        std.debug.print("key mismatch: want {any}, got {any}\n", .{ want, r.key.key });
        return error.KeyMismatch;
    }
}

test "single-byte keys decode with consumed == 1" {
    try expectKey("\r", .enter, 1);
    try expectKey("\n", .enter, 1);
    try expectKey(" ", .space, 1);
    try expectKey("\t", .tab, 1);
    try expectKey("\x7f", .backspace, 1); // DEL
    try expectKey("\x08", .backspace, 1); // BS
    try expectKey("\x03", .ctrl_c, 1); // raw mode delivers no SIGINT
}

test "printable ASCII decodes to char carrying the byte" {
    try expectKey("a", .{ .char = .{ .bytes = .{ 'a', 0, 0, 0 }, .len = 1 } }, 1);
    try expectKey("Z", .{ .char = .{ .bytes = .{ 'Z', 0, 0, 0 }, .len = 1 } }, 1);
    try expectKey("~", .{ .char = .{ .bytes = .{ '~', 0, 0, 0 }, .len = 1 } }, 1);
}

test "arrow keys decode from CSI with consumed == 3" {
    try expectKey("\x1b[A", .up, 3);
    try expectKey("\x1b[B", .down, 3);
    try expectKey("\x1b[C", .right, 3);
    try expectKey("\x1b[D", .left, 3);
}

test "home and end decode from both CSI variants" {
    try expectKey("\x1b[H", .home, 3);
    try expectKey("\x1b[F", .end, 3);
    try expectKey("\x1b[1~", .home, 4);
    try expectKey("\x1b[4~", .end, 4);
}

test "page up and page down decode with consumed == 4" {
    try expectKey("\x1b[5~", .page_up, 4);
    try expectKey("\x1b[6~", .page_down, 4);
}

test "unknown CSI sequence decodes to .unknown, fully consumed" {
    try expectKey("\x1b[Z", .unknown, 3); // shift-tab: complete but unmapped
    try expectKey("\x1b[3~", .unknown, 4); // delete: complete but unmapped
}

test "a lone ESC followed by a non-bracket byte decodes as esc, byte pushed back" {
    var d: keys.Decoder = .{};
    const r = d.decode("\x1bx");
    try testing.expect(r == .key);
    try testing.expect(keyEql(.esc, r.key.key));
    try testing.expectEqual(@as(usize, 1), r.key.consumed); // only the ESC
    // The 'x' was pushed back; re-feeding the remainder yields it.
    const r2 = d.decode("x");
    try testing.expect(r2 == .key);
    try testing.expect(keyEql(.{ .char = .{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1 } }, r2.key.key));
}

test "a CSI sequence split across two reads resumes correctly" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("\x1b") == .incomplete);
    const r = d.decode("[A");
    try testing.expect(r == .key);
    try testing.expect(keyEql(.up, r.key.key));
    try testing.expectEqual(@as(usize, 2), r.key.consumed); // only the new bytes
}

test "a page sequence split mid-stream resumes correctly" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("\x1b[5") == .incomplete);
    const r = d.decode("~");
    try testing.expect(r == .key);
    try testing.expect(keyEql(.page_up, r.key.key));
    try testing.expectEqual(@as(usize, 1), r.key.consumed);
}

test "flush surfaces a trailing lone ESC, then nothing" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("\x1b") == .incomplete);
    try testing.expect(keyEql(.esc, d.flush().?));
    try testing.expect(d.flush() == null); // buffer drained
}

test "two keys in one slice decode one at a time via consumed" {
    var d: keys.Decoder = .{};
    const r1 = d.decode("a\x1b[B");
    try testing.expect(r1 == .key);
    try testing.expect(keyEql(.{ .char = .{ .bytes = .{ 'a', 0, 0, 0 }, .len = 1 } }, r1.key.key));
    try testing.expectEqual(@as(usize, 1), r1.key.consumed);

    const r2 = d.decode("\x1b[B");
    try testing.expect(r2 == .key);
    try testing.expect(keyEql(.down, r2.key.key));
    try testing.expectEqual(@as(usize, 3), r2.key.consumed);
}

test "multi-byte UTF-8 decodes to a char carrying every byte" {
    // é = U+00E9 = 0xC3 0xA9 (2 bytes)
    try expectKey("\xc3\xa9", .{ .char = .{ .bytes = .{ 0xc3, 0xa9, 0, 0 }, .len = 2 } }, 2);
    // € = U+20AC = 0xE2 0x82 0xAC (3 bytes)
    try expectKey("\xe2\x82\xac", .{ .char = .{ .bytes = .{ 0xe2, 0x82, 0xac, 0 }, .len = 3 } }, 3);
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80 (4 bytes)
    try expectKey("\xf0\x9f\x98\x80", .{ .char = .{ .bytes = .{ 0xf0, 0x9f, 0x98, 0x80 }, .len = 4 } }, 4);
}

test "a UTF-8 char split across two reads resumes correctly" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("\xe2\x82") == .incomplete);
    const r = d.decode("\xac");
    try testing.expect(r == .key);
    try testing.expect(keyEql(.{ .char = .{ .bytes = .{ 0xe2, 0x82, 0xac, 0 }, .len = 3 } }, r.key.key));
    try testing.expectEqual(@as(usize, 1), r.key.consumed);
}

test "a stray UTF-8 continuation byte decodes to .unknown" {
    try expectKey("\x80", .unknown, 1);
}

test "an invalid UTF-8 lead byte decodes to .unknown" {
    try expectKey("\xff", .unknown, 1); // 0xf8–0xff are never valid leads
}

test "a bad UTF-8 continuation drains the lead alone and re-decodes the rest" {
    var d: keys.Decoder = .{};
    const r = d.decode("\xc3A"); // 0xc3 promises a continuation; 'A' is not one
    try testing.expect(r == .key);
    try testing.expect(keyEql(.unknown, r.key.key));
    try testing.expectEqual(@as(usize, 1), r.key.consumed); // only the bad lead
    // The 'A' was pushed back, so re-feeding the remainder yields it intact.
    const r2 = d.decode("A");
    try testing.expect(r2 == .key);
    try testing.expect(keyEql(.{ .char = .{ .bytes = .{ 'A', 0, 0, 0 }, .len = 1 } }, r2.key.key));
}

test "flush of a partial escape sequence yields unknown, then nothing" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("\x1b[5") == .incomplete); // partial page sequence
    try testing.expect(keyEql(.unknown, d.flush().?));
    try testing.expect(d.flush() == null);
}

test "a control byte inside a CSI sequence decodes to unknown" {
    try expectKey("\x1b[\x01", .unknown, 3); // not a param, intermediate, or final
}

test "empty input with an empty buffer is incomplete" {
    var d: keys.Decoder = .{};
    try testing.expect(d.decode("") == .incomplete);
}

test "ESC immediately followed by ESC: first is lone, second is buffered" {
    var d: keys.Decoder = .{};
    const r = d.decode("\x1b\x1b");
    try testing.expect(r == .key);
    try testing.expect(keyEql(.esc, r.key.key));
    try testing.expectEqual(@as(usize, 1), r.key.consumed); // first ESC only
    try testing.expect(d.decode("\x1b") == .incomplete); // second ESC awaits a follow-on
    try testing.expect(keyEql(.esc, d.flush().?)); // EOF resolves it
}
