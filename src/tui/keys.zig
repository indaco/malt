//! malt — keyboard input decoder for `mt tui`.
//!
//! Leaf module: imports only `std`. A pure DFA that turns raw input bytes into
//! `Key` values without touching the terminal, so it is fully table-testable
//! without a PTY. The decoder owns a small fixed pending buffer so an escape
//! sequence split across two reads resumes on the next bytes; it never
//! allocates and never errors, so malformed input can never unwind past the
//! caller's `errdefer` terminal restore.

const std = @import("std");

const cap = 8; // longest sequence buffered before draining to `.unknown`

/// A printable character as its raw UTF-8 bytes (1–4). Display width is *not*
/// decoded here — that is the layout layer's job (matches `term_sanitize`'s
/// raw-UTF-8 stance).
pub const Char = struct {
    bytes: [4]u8,
    len: u3,

    pub fn slice(self: *const Char) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One decoded keypress. A closed tagged union: exhaustive `switch`es over it
/// take no `else`, so a future arm is a compile error until handled. `.unknown`
/// is a real event (a complete but unrecognised sequence), never an error.
pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    space,
    tab,
    esc,
    backspace,
    ctrl_c,
    page_up,
    page_down,
    home,
    end,
    char: Char,
    unknown,
};

/// Result of one `decode` call.
pub const Decoded = union(enum) {
    /// A decoded key plus how many bytes of *this* slice it consumed. Bytes
    /// carried over from a prior call are not re-counted.
    key: struct { key: Key, consumed: usize },
    /// The slice ended mid-sequence; the tail is buffered. Feed more bytes, or
    /// call `flush` at EOF to surface a lone ESC.
    incomplete,
};

/// A stream key decoder. Default-initialised (`.{}`); allocation-free.
pub const Decoder = struct {
    buf: [cap]u8 = undefined,
    len: usize = 0,

    /// Decode the first key in `bytes`, resuming any sequence buffered from a
    /// prior call. `consumed` counts only bytes from *this* slice, so the caller
    /// advances its own read buffer by it; carried-over prefix bytes are not
    /// re-counted. `.incomplete` means the slice ended mid-sequence and the tail
    /// is now buffered.
    pub fn decode(self: *Decoder, bytes: []const u8) Decoded {
        var i: usize = 0;
        while (i < bytes.len) {
            self.buf[self.len] = bytes[i];
            self.len += 1;
            i += 1;
            switch (recognize(self.buf[0..self.len])) {
                .done => |d| {
                    // Bytes past the key (a lone ESC's follow-on) are pushed
                    // back: not buffered, and excluded from `consumed` so the
                    // caller re-presents them on the next call.
                    const leftover = self.len - d.len;
                    self.len = 0;
                    return .{ .key = .{ .key = d.key, .consumed = i - leftover } };
                },
                .need_more => if (self.len == cap) {
                    // Buffer full with no match: drain it as one unknown event so
                    // a hostile stream can never overflow or stall the decoder.
                    self.len = 0;
                    return .{ .key = .{ .key = .unknown, .consumed = i } };
                },
            }
        }
        return .incomplete;
    }

    /// At EOF (no more bytes will arrive), surface a buffered tail: a lone ESC
    /// becomes `.esc`, any other partial sequence `.unknown`. Returns null when
    /// nothing is buffered. This is the only place a trailing ESC resolves,
    /// since a pure DFA cannot use the inter-byte timeout a PTY would.
    pub fn flush(self: *Decoder) ?Key {
        if (self.len == 0) return null;
        const lone_esc = self.len == 1 and self.buf[0] == 0x1b;
        self.len = 0;
        return if (lone_esc) .esc else .unknown;
    }
};

/// One DFA step over the accumulated prefix.
const Step = union(enum) {
    need_more,
    done: struct { key: Key, len: usize },
};

fn done(key: Key, len: usize) Step {
    return .{ .done = .{ .key = key, .len = len } };
}

fn char1(b: u8) Key {
    return .{ .char = .{ .bytes = .{ b, 0, 0, 0 }, .len = 1 } };
}

/// Classify the accumulated prefix `buf` (always ≥ 1 byte). Pure: same prefix →
/// same step, no I/O, never errors.
fn recognize(buf: []const u8) Step {
    const b0 = buf[0];
    if (b0 == 0x1b) return recognizeEsc(buf);
    if (b0 >= 0x80) return recognizeUtf8(buf);
    return switch (b0) {
        0x03 => done(.ctrl_c, 1), // raw mode delivers Ctrl-C as a byte, not SIGINT
        0x09 => done(.tab, 1),
        0x0a, 0x0d => done(.enter, 1), // LF or CR
        0x08, 0x7f => done(.backspace, 1), // BS or DEL
        0x20 => done(.space, 1),
        else => if (b0 >= 0x21 and b0 <= 0x7e) done(char1(b0), 1) else done(.unknown, 1),
    };
}

/// ESC and the bracketed CSI form. A non-`[` byte after ESC means the ESC was
/// lone (consumed alone; the byte is pushed back); SS3 (`ESC O …`) is out of
/// scope because the dashboard never enables application-cursor mode.
fn recognizeEsc(buf: []const u8) Step {
    if (buf.len == 1) return .need_more; // need the byte after ESC
    if (buf[1] != '[') return done(.esc, 1);
    if (buf.len == 2) return .need_more; // "ESC [" alone
    const last = buf[buf.len - 1];
    if (last >= 0x40 and last <= 0x7e) return done(csiKey(buf[2..]), buf.len); // final byte
    if (last >= 0x20 and last <= 0x3f) return .need_more; // param/intermediate
    return done(.unknown, buf.len); // malformed CSI byte
}

/// Map a CSI body (params + final byte) to a key. Unmapped-but-complete
/// sequences are `.unknown`, never errors, so unhandled keys are inert.
fn csiKey(body: []const u8) Key {
    const eql = std.mem.eql;
    if (eql(u8, body, "A")) return .up;
    if (eql(u8, body, "B")) return .down;
    if (eql(u8, body, "C")) return .right;
    if (eql(u8, body, "D")) return .left;
    if (eql(u8, body, "H") or eql(u8, body, "1~")) return .home;
    if (eql(u8, body, "F") or eql(u8, body, "4~")) return .end;
    if (eql(u8, body, "5~")) return .page_up;
    if (eql(u8, body, "6~")) return .page_down;
    return .unknown;
}

/// Accumulate a UTF-8 char by its lead-byte length; carry the raw bytes. Any
/// invalid lead or continuation drains the lead alone as `.unknown` and pushes
/// the rest back, so a bad byte never swallows the keys after it.
fn recognizeUtf8(buf: []const u8) Step {
    const want = std.unicode.utf8ByteSequenceLength(buf[0]) catch return done(.unknown, 1);
    const have = @min(buf.len, @as(usize, want));
    for (buf[1..have]) |c| {
        if (c < 0x80 or c > 0xbf) return done(.unknown, 1); // not a continuation
    }
    if (buf.len < want) return .need_more;
    var ch: Char = .{ .bytes = .{ 0, 0, 0, 0 }, .len = want };
    @memcpy(ch.bytes[0..want], buf[0..want]);
    return done(.{ .char = ch }, want);
}

test "Char.slice returns only the populated bytes" {
    const c: Char = .{ .bytes = .{ 0xc3, 0xa9, 0, 0 }, .len = 2 };
    try std.testing.expectEqualStrings("\xc3\xa9", c.slice());
}

test "recognize classifies the single-byte control and printable cases" {
    try std.testing.expectEqual(@as(usize, 1), recognize("\x03").done.len);
    try std.testing.expect(recognize("\x03").done.key == .ctrl_c);
    try std.testing.expect(recognize("\t").done.key == .tab);
    try std.testing.expect(recognize("\r").done.key == .enter);
    try std.testing.expect(recognize(" ").done.key == .space);
    try std.testing.expect(recognize("\x7f").done.key == .backspace);
    try std.testing.expect(recognize("a").done.key == .char);
    try std.testing.expect(recognize("\x01").done.key == .unknown); // a stray C0 control
}

test "recognizeEsc waits for the byte after ESC then resolves" {
    try std.testing.expect(recognize("\x1b") == .need_more);
    try std.testing.expect(recognize("\x1b[") == .need_more);
    try std.testing.expect(recognize("\x1bx").done.key == .esc); // lone ESC, 'x' pushed back
    try std.testing.expectEqual(@as(usize, 1), recognize("\x1bx").done.len);
}

test "csiKey maps the supported finals and is unknown otherwise" {
    try std.testing.expect(csiKey("A") == .up);
    try std.testing.expect(csiKey("1~") == .home);
    try std.testing.expect(csiKey("6~") == .page_down);
    try std.testing.expect(csiKey("Z") == .unknown);
}

test "an over-long escape sequence drains to unknown at the buffer cap" {
    var d: Decoder = .{};
    const r = d.decode("\x1b[1;2;3;4;5A"); // far longer than the param forms we map
    try std.testing.expect(r == .key);
    try std.testing.expect(r.key.key == .unknown);
    try std.testing.expectEqual(@as(usize, cap), r.key.consumed);
}
