//! malt — keyboard input decoder for `mt tui`.
//!
//! Leaf module: imports only `std`. A pure DFA that turns raw input bytes into
//! `Key` values without touching the terminal, so it is fully table-testable
//! without a PTY. The decoder owns a small fixed pending buffer so an escape
//! sequence split across two reads resumes on the next bytes; it never
//! allocates and never errors, so malformed input can never unwind past the
//! caller's `errdefer` terminal restore.

const std = @import("std");

// Worst realistic SGR report `\x1b[<BBB;CCCC;RRRRM` is 17 bytes; 20 gives
// headroom, and anything longer still drains safely at the cap.
const cap = 20; // longest sequence buffered before draining to `.unknown`

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

/// One decoded SGR mouse report. Its own event so the keyboard `Key` union
/// stays pure — a click carries coordinates a key never does.
pub const Mouse = struct {
    button: u8, // SGR code: 0 = left, 64 = wheel-up, 65 = wheel-down
    col: u16, // 1-based cell column (matches layout's origin)
    row: u16, // 1-based cell row
    press: bool, // final 'M' = press, 'm' = release
};

/// Result of one `decode` call.
pub const Decoded = union(enum) {
    /// A decoded key plus how many bytes of *this* slice it consumed. Bytes
    /// carried over from a prior call are not re-counted.
    key: struct { key: Key, consumed: usize },
    /// A decoded mouse report, with the same `consumed` accounting as `key`.
    mouse: struct { mouse: Mouse, consumed: usize },
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
                .mouse => |m| {
                    // Same accounting as `.done`: an SGR report always ends on
                    // its final byte, so `m.len` spans the whole buffer.
                    const leftover = self.len - m.len;
                    self.len = 0;
                    return .{ .mouse = .{ .mouse = m.mouse, .consumed = i - leftover } };
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
    mouse: struct { mouse: Mouse, len: usize },
};

fn done(key: Key, len: usize) Step {
    return .{ .done = .{ .key = key, .len = len } };
}

fn mouseDone(m: Mouse, len: usize) Step {
    return .{ .mouse = .{ .mouse = m, .len = len } };
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
    if (last >= 0x40 and last <= 0x7e) { // final byte: CSI complete
        const body = buf[2..];
        if (body.len >= 1 and body[0] == '<') return mouseStep(body, buf.len);
        return done(csiKey(body), buf.len);
    }
    if (last >= 0x20 and last <= 0x3f) return .need_more; // param/intermediate
    return done(.unknown, buf.len); // malformed CSI byte
}

/// Classify an SGR mouse body (`<` params final). A trust boundary: the CSI
/// framing admits arbitrary param bytes, so any malformed body resolves to a
/// complete `.unknown` — never an error, never a mis-decoded key.
fn mouseStep(body: []const u8, len: usize) Step {
    return if (parseSgr(body)) |m| mouseDone(m, len) else done(.unknown, len);
}

/// Parse an SGR mouse body `<button;col;row(M|m)` into a `Mouse`, or `null` for
/// any malformed input. Allocation-free and overflow-safe: each field folds
/// into a `u16` with an overflow guard, so hostile params can only yield `null`.
fn parseSgr(body: []const u8) ?Mouse {
    if (body.len < 2 or body[0] != '<') return null;
    const press = switch (body[body.len - 1]) {
        'M' => true,
        'm' => false,
        else => return null, // wrong final byte
    };
    var fields = std.mem.splitScalar(u8, body[1 .. body.len - 1], ';');
    const button = parseU16(fields.next() orelse return null) orelse return null;
    const col = parseU16(fields.next() orelse return null) orelse return null;
    const row = parseU16(fields.next() orelse return null) orelse return null;
    if (fields.next() != null) return null; // extra field
    return .{
        .button = std.math.cast(u8, button) orelse return null,
        .col = col,
        .row = row,
        .press = press,
    };
}

/// Fold decimal digits into a `u16`; `null` on empty, non-digit, or overflow.
/// Deliberately stricter than `std.fmt.parseInt`, which accepts a leading `+`
/// and `_` separators — SGR params are pure digit runs, and this is a trust
/// boundary, so anything non-canonical must be rejected, not coerced.
fn parseU16(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var v: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const mul = @mulWithOverflow(v, 10);
        if (mul[1] != 0) return null;
        const add = @addWithOverflow(mul[0], @as(u16, c - '0'));
        if (add[1] != 0) return null;
        v = add[0];
    }
    return v;
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

test "flush resolves a buffered lone ESC as .esc and empties the decoder" {
    var d: Decoder = .{};
    try std.testing.expect(d.decode("\x1b") == .incomplete);
    try std.testing.expect(d.flush().? == .esc);
    try std.testing.expect(d.flush() == null); // tail consumed, decoder empty
}

test "flush surfaces a partial CSI tail as .unknown, never as a key" {
    var d: Decoder = .{};
    try std.testing.expect(d.decode("\x1b[") == .incomplete);
    try std.testing.expect(d.flush().? == .unknown);
}

test "flush with nothing buffered is null" {
    var d: Decoder = .{};
    try std.testing.expect(d.flush() == null);
}

test "csiKey maps the supported finals and is unknown otherwise" {
    try std.testing.expect(csiKey("A") == .up);
    try std.testing.expect(csiKey("1~") == .home);
    try std.testing.expect(csiKey("6~") == .page_down);
    try std.testing.expect(csiKey("Z") == .unknown);
}

test "an over-long escape sequence drains to unknown at the buffer cap" {
    var d: Decoder = .{};
    // All-param body with no final byte: it can never resolve, so the decoder
    // drains it as one `.unknown` every `cap` bytes (the hostile-stream backstop).
    const r = d.decode("\x1b[<9999;9999;9999;9999;9999");
    try std.testing.expect(r == .key);
    try std.testing.expect(r.key.key == .unknown);
    try std.testing.expectEqual(@as(usize, cap), r.key.consumed);
}

test "wheel-up SGR report decodes to a mouse event" {
    var d: Decoder = .{};
    const r = d.decode("\x1b[<64;12;5M");
    try std.testing.expect(r == .mouse);
    try std.testing.expectEqual(@as(u8, 64), r.mouse.mouse.button);
    try std.testing.expectEqual(@as(u16, 12), r.mouse.mouse.col);
    try std.testing.expectEqual(@as(u16, 5), r.mouse.mouse.row);
    try std.testing.expect(r.mouse.mouse.press);
    try std.testing.expectEqual(@as(usize, 11), r.mouse.consumed);
}

test "wheel-down SGR report decodes with button 65" {
    var d: Decoder = .{};
    const r = d.decode("\x1b[<65;12;5M");
    try std.testing.expect(r == .mouse);
    try std.testing.expectEqual(@as(u8, 65), r.mouse.mouse.button);
}

test "left press decodes press=true, left release press=false" {
    var dp: Decoder = .{};
    const p = dp.decode("\x1b[<0;40;12M");
    try std.testing.expect(p == .mouse);
    try std.testing.expectEqual(@as(u8, 0), p.mouse.mouse.button);
    try std.testing.expect(p.mouse.mouse.press);

    var dr: Decoder = .{};
    const rel = dr.decode("\x1b[<0;40;12m");
    try std.testing.expect(rel == .mouse);
    try std.testing.expect(!rel.mouse.mouse.press);
}

test "malformed SGR bodies resolve to a complete .unknown, never incomplete" {
    const cases = [_][]const u8{
        "\x1b[<0;a;12M", // non-digit param
        "\x1b[<0;99999;12M", // field overflow (> u16)
        "\x1b[<0;12M", // missing field
        "\x1b[<0;40;12X", // wrong final byte
        "\x1b[<M", // empty body after '<'
    };
    for (cases) |c| {
        var d: Decoder = .{};
        const r = d.decode(c);
        try std.testing.expect(r == .key); // complete, not .incomplete or .mouse
        try std.testing.expect(r.key.key == .unknown);
        try std.testing.expect(r.key.consumed > 0);
    }
}

test "an SGR report split across two reads resumes and decodes once" {
    var d: Decoder = .{};
    try std.testing.expect(d.decode("\x1b[<64;12;") == .incomplete);
    const r = d.decode("5M");
    try std.testing.expect(r == .mouse);
    try std.testing.expectEqual(@as(u8, 64), r.mouse.mouse.button);
    try std.testing.expectEqual(@as(usize, 2), r.mouse.consumed); // only this slice's bytes
}

test "arbitrary junk param bytes after '<' never panic and resolve to .unknown" {
    const junk = [_][]const u8{
        "\x1b[<;;;M",
        "\x1b[<-1;2;3M",
        "\x1b[< 0 ;1;2M",
        "\x1b[<0;;M",
        "\x1b[<0/1/2M",
        "\x1b[<0;1;2;3M", // extra field
    };
    for (junk) |c| {
        var d: Decoder = .{};
        const r = d.decode(c);
        try std.testing.expect(r == .key);
        try std.testing.expect(r.key.key == .unknown);
    }
}

test "canonical-looking but non-strict SGR bodies are rejected, not coerced" {
    // '+' (0x2b) is a CSI param byte, so it reaches the field parser where
    // std.fmt.parseInt would accept "+64"; the digit-only parse rejects it. A
    // button past u8 is caught by the cast. Both must be .unknown, never a Mouse.
    const cases = [_][]const u8{
        "\x1b[<+64;12;5M", // leading '+' — parseInt-lenient, SGR-invalid
        "\x1b[<300;12;5M", // button exceeds u8
    };
    for (cases) |c| {
        var d: Decoder = .{};
        const r = d.decode(c);
        try std.testing.expect(r == .key);
        try std.testing.expect(r.key.key == .unknown);
    }
}
