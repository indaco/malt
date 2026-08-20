//! malt — terminal escape-sequence sanitizer
//!
//! Filters bytes from an untrusted child process before they reach
//! the user's terminal. Permits printable ASCII + CR/LF/TAB + well-formed
//! UTF-8 (validated per byte position, so lone C1 controls in 0x80..0x9F
//! drop while real multibyte output passes) +
//! a whitelisted subset of CSI sequences, gated on the final byte AND
//! numeric-only parameters: SGR colours, horizontal cursor motion
//! (C/D/G), line erase (K), and visible-screen erase (J with no
//! param or 0/1/2). CR passes too, so a child can still redraw the
//! line it is writing.
//! Everything else — OSC (including clipboard-reading OSC 52), DCS,
//! SOS/PM/APC, 8-bit C1 introducers, absolute positioning (H/f),
//! cursor save/restore (s/u), vertical motion (A/B/E/F), scrollback
//! erase (CSI 3 J), other CSI commands, C0 controls,
//! stray/mid-sequence ESC, and any CSI carrying
//! a private prefix or intermediate byte (`CSI > 4 ; 2 m` is XTMODKEYS,
//! not SGR) — is dropped.
//!
//! Used to wrap post_install stdout/stderr so a hostile formula
//! cannot rewrite scrollback or exfiltrate via terminal extensions.

const std = @import("std");

/// Closed error set surfaced by `Sink.write_fn`. Every sink
/// implementation must collapse its failure modes into this set so
/// sanitizer callers can switch exhaustively instead of catching
/// `anyerror`.
pub const SinkError = error{WriteFailed};

/// Bytes-out callback. The sink is allowed to fail; the sanitizer
/// propagates that error to its caller.
pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) SinkError!void,

    pub fn write(self: Sink, bytes: []const u8) SinkError!void {
        return self.write_fn(self.ctx, bytes);
    }
};

/// CSI parameter buffer cap. Real SGR/cursor sequences rarely exceed
/// a handful of bytes; an attacker can still overflow, in which case
/// we drop the whole sequence at its final byte.
pub const csi_param_max: usize = 32;
pub const out_buf: usize = 256;

pub const Sanitizer = struct {
    state: State = .normal,
    csi_buf: [csi_param_max]u8 = undefined,
    csi_len: usize = 0,
    csi_overflow: bool = false,
    out_buf: [out_buf]u8 = undefined,
    out_len: usize = 0,
    // Pending UTF-8 sequence, so a continuation in 0x80..0x9F passes while a
    // lone C1 control is dropped.
    utf8: Utf8State = .{},

    const State = enum {
        normal,
        esc, // just saw ESC (0x1B)
        csi, // in ESC [ ... sequence
        osc, // in ESC ] ... ST  (always dropped)
        dcs, // DCS/SOS/PM/APC (always dropped)
        st_maybe, // inside OSC/DCS, just saw ESC — looking for ST's `\\`
    };

    pub fn init() Sanitizer {
        return .{};
    }

    /// Feed one chunk of input. Safe to call repeatedly; state is
    /// preserved across calls so a sequence split across chunks is
    /// still recognised.
    pub fn feed(self: *Sanitizer, input: []const u8, sink: Sink) !void {
        for (input) |b| try self.feedByte(b, sink);
    }

    /// Flush buffered passable bytes. Call at end-of-stream.
    pub fn flush(self: *Sanitizer, sink: Sink) !void {
        if (self.out_len > 0) {
            try sink.write(self.out_buf[0..self.out_len]);
            self.out_len = 0;
        }
    }

    fn feedByte(self: *Sanitizer, b: u8, sink: Sink) !void {
        switch (self.state) {
            .normal => {
                if (b == 0x1B) {
                    try self.flush(sink);
                    self.utf8 = .{};
                    self.state = .esc;
                } else if (self.utf8.remaining == 0) {
                    if (c1Target(b)) |target| {
                        // 8-bit C1 introducer: drop it and its payload just like
                        // the 7-bit ESC form, so an 8-bit terminal can't
                        // reconstruct the sequence the 7-bit path filters.
                        try self.flush(sink);
                        switch (target) {
                            .csi => self.beginCsi(),
                            else => self.state = target,
                        }
                    } else if (self.passable(b)) {
                        try self.emit(b, sink);
                    }
                } else if (self.passable(b)) {
                    // Mid-codepoint: a continuation byte passes; a stray
                    // non-continuation is reclassified and dropped by passable.
                    try self.emit(b, sink);
                }
            },
            .esc => switch (b) {
                '[' => self.beginCsi(),
                ']' => self.state = .osc,
                'P', 'X', '^', '_' => self.state = .dcs,
                // Two-byte ESC X: drop both (we already dropped ESC).
                else => self.state = .normal,
            },
            .csi => switch (b) {
                0x40...0x7E => {
                    // Final byte: replay only a clean, whitelisted sequence.
                    if (!self.csi_overflow and csiAllowed(b, self.csi_buf[0..self.csi_len])) {
                        try self.emit(0x1B, sink);
                        try self.emit('[', sink);
                        for (self.csi_buf[0..self.csi_len]) |p| try self.emit(p, sink);
                        try self.emit(b, sink);
                    }
                    self.state = .normal;
                },
                // A mid-CSI ESC aborts this sequence and starts a new one, so a
                // smuggled ESC can never be replayed with the final byte.
                0x1B => self.state = .esc,
                // Legal CSI parameter/intermediate byte.
                0x20...0x3F => if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = b;
                    self.csi_len += 1;
                } else {
                    self.csi_overflow = true; // too many params — drop at final byte
                },
                // C0 control or DEL inside a CSI is illegal; fail closed so the
                // whole sequence drops rather than replaying the byte.
                else => self.csi_overflow = true,
            },
            .osc, .dcs => switch (b) {
                0x07, 0x9C => self.state = .normal, // BEL or 8-bit ST terminates
                0x1B => self.state = .st_maybe, // 7-bit ST begins with ESC
                else => {}, // body byte: drop
            },
            .st_maybe => switch (b) {
                '\\' => self.state = .normal, // ESC \ = ST
                0x1B => {}, // another ESC: keep waiting
                else => self.state = .osc, // not ST; back into the body
            },
        }
    }

    fn emit(self: *Sanitizer, b: u8, sink: Sink) !void {
        if (self.out_len == self.out_buf.len) try self.flush(sink);
        self.out_buf[self.out_len] = b;
        self.out_len += 1;
    }

    fn beginCsi(self: *Sanitizer) void {
        self.state = .csi;
        self.csi_len = 0;
        self.csi_overflow = false;
    }

    fn passable(self: *Sanitizer, b: u8) bool {
        // CR is a stream byte here: child output uses it for in-place progress.
        return passableByte(b, &self.utf8) or b == '\r';
    }
};

/// Pending multibyte sequence. `lo`/`hi` bound the *next* byte, which is what
/// separates a well-formed encoding from an overlong, surrogate or
/// out-of-range one — a plain 0x80..0xBF range check cannot tell them apart.
const Utf8State = struct {
    remaining: u2 = 0,
    lo: u8 = 0x80,
    hi: u8 = 0xBF,
};

/// Unicode Table 3-7: the only leads that begin a well-formed sequence, each
/// with the range its successor byte must fall in. A length classifier is not
/// a substitute — it accepts 0xC0/0xC1 and 0xF5..0xF7, which are never legal.
fn leadState(b: u8) ?Utf8State {
    return switch (b) {
        0xC2...0xDF => .{ .remaining = 1, .lo = 0x80, .hi = 0xBF },
        0xE0 => .{ .remaining = 2, .lo = 0xA0, .hi = 0xBF },
        0xE1...0xEC => .{ .remaining = 2, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .remaining = 2, .lo = 0x80, .hi = 0x9F },
        0xEE...0xEF => .{ .remaining = 2, .lo = 0x80, .hi = 0xBF },
        0xF0 => .{ .remaining = 3, .lo = 0x90, .hi = 0xBF },
        0xF1...0xF3 => .{ .remaining = 3, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .remaining = 3, .lo = 0x80, .hi = 0x8F },
        else => null,
    };
}

/// Shared pass predicate. The pending-sequence state is what tells a real
/// continuation from a lone C1 control, so both callers must classify through
/// here rather than reimplement the rule.
///
/// Emission stays byte-at-a-time: every byte that passes is part of a
/// well-formed prefix, so a later rejection leaves a maximal subpart that a
/// strict decoder eats as one error rather than resyncing into it as C1.
fn passableByte(b: u8, st: *Utf8State) bool {
    if (st.remaining > 0) {
        if (b >= st.lo and b <= st.hi) {
            st.remaining -= 1;
            // Only the byte after the lead is range-restricted.
            st.lo = 0x80;
            st.hi = 0xBF;
            return true;
        }
        st.* = .{}; // ill-formed — reclassify below
    }
    return switch (b) {
        0x20...0x7E, '\n', '\t' => true,
        else => if (leadState(b)) |armed| blk: {
            st.* = armed;
            break :blk true;
        } else false, // C0 controls, DEL, continuation and invalid lead bytes
    };
}

/// Filter `buf` in place, returning the kept prefix.
///
/// Stricter than `Sanitizer` by design: text interpolated into malt's own
/// output has no legitimate reason to carry an escape, so there is no CSI
/// whitelist here and CR drops with the other C0 controls.
pub fn scrubInPlace(buf: []u8) []u8 {
    var out: usize = 0;
    var st: Utf8State = .{};
    for (buf) |b| {
        if (!passableByte(b, &st)) continue;
        buf[out] = b;
        out += 1;
    }
    return buf[0..out];
}

/// Maps an 8-bit C1 control introducer to the state that drops or filters
/// its payload, mirroring the 7-bit ESC forms. `null` for any other byte.
fn c1Target(b: u8) ?Sanitizer.State {
    return switch (b) {
        0x9B => .csi, // CSI  (ESC [)
        0x9D => .osc, // OSC  (ESC ])
        0x90, 0x98, 0x9E, 0x9F => .dcs, // DCS/SOS/PM/APC
        else => null,
    };
}

fn csiAllowed(final: u8, params: []const u8) bool {
    // The prefix is part of the opcode: `CSI > 4 ; 2 m` is XTMODKEYS, not SGR.
    // ':' stays for SGR subparameters (`CSI 4:3 m`).
    for (params) |p| switch (p) {
        '0'...'9', ';', ':' => {},
        else => return false,
    };
    return switch (final) {
        'm' => true, // SGR: colours, bold, underline
        // C/D move relative, G jumps to an absolute column; none leaves the line.
        'C', 'D', 'G' => true,
        // Vertical motion (A/B/E/F) joins H/f and s/u: each one puts the cursor
        // on a line malt wrote, where the permitted erase can repaint it. No
        // count is safe either, because the attack is net-zero (up, erase,
        // forge, back down), so only removing the reach closes it.
        'J' => eraseDisplayAllowed(params), // reject CSI 3 J (erase scrollback)
        'K' => true, // erase line
        else => false,
    };
}

// CSI J erases the visible screen; CSI 3 J also clears scrollback, which the
// sanitizer must not permit. Allow only the visible-screen variants: no
// param, or a single 0/1/2.
fn eraseDisplayAllowed(params: []const u8) bool {
    return switch (params.len) {
        0 => true, // CSI J
        1 => params[0] >= '0' and params[0] <= '2', // 0/1/2; reject 3 (scrollback)
        else => false, // multi-param forms are not whitelisted
    };
}

// ── inline unit tests: private classifier helpers ───────────────────
// Full feed()/flush() byte-stream behaviour lives in tests/term_sanitize_test.zig;
// these cover the file-private classifiers that the integration file can't reach.

test "csiAllowed whitelists SGR/horizontal motion, drops every way onto another line" {
    for ("mCDGK") |f| try std.testing.expect(csiAllowed(f, ""));
    // Absolute positioning (H/f), save/restore (s/u) and vertical motion
    // (A/B/E/F) all reach a line the child never wrote.
    for ("HfsuABEF") |f| try std.testing.expect(!csiAllowed(f, ""));
    // No count rehabilitates vertical motion; horizontal motion needs no cap
    // because it cannot leave the current line.
    for ([_][]const u8{ "", "1", "3", "999" }) |p| try std.testing.expect(!csiAllowed('A', p));
    try std.testing.expect(csiAllowed('C', "999"));
    try std.testing.expect(csiAllowed('G', "80"));
    // J is param-gated, not final-byte-only.
    try std.testing.expect(csiAllowed('J', "2"));
    try std.testing.expect(!csiAllowed('J', "3"));
}

test "csiAllowed rejects private-prefix and intermediate parameter bytes" {
    // The prefix is part of the opcode: `CSI > 4 ; 2 m` is XTMODKEYS, not SGR.
    for ([_][]const u8{ ">4;2", "?4", "<0;0;0", "=5" }) |p|
        try std.testing.expect(!csiAllowed('m', p));
    // Intermediates likewise: `CSI SP A` is SL (scroll left), not cursor up.
    try std.testing.expect(!csiAllowed('m', "0;1$"));
    try std.testing.expect(!csiAllowed('K', "!"));
    try std.testing.expect(!csiAllowed('A', " "));
    // Bytes either side of the accepted '0'..'9' ';' ':' run.
    try std.testing.expect(!csiAllowed('m', "/"));
    try std.testing.expect(!csiAllowed('m', "<"));
    // Numeric params, including SGR subparameters, stay allowed.
    try std.testing.expect(csiAllowed('m', "1;31"));
    try std.testing.expect(csiAllowed('m', "4:3"));
    try std.testing.expect(csiAllowed('C', "3"));
}

test "eraseDisplayAllowed permits only visible-screen variants" {
    for ([_][]const u8{ "", "0", "1", "2" }) |p| try std.testing.expect(eraseDisplayAllowed(p));
    // 3 clears scrollback; other/multi-param forms are not whitelisted.
    for ([_][]const u8{ "3", "9", "33", "3;4" }) |p| try std.testing.expect(!eraseDisplayAllowed(p));
}

test "c1Target maps 8-bit introducers to their drop/filter state" {
    try std.testing.expectEqual(Sanitizer.State.csi, c1Target(0x9B).?);
    try std.testing.expectEqual(Sanitizer.State.osc, c1Target(0x9D).?);
    for ([_]u8{ 0x90, 0x98, 0x9E, 0x9F }) |b| try std.testing.expectEqual(Sanitizer.State.dcs, c1Target(b).?);
    // ST (0x9C) is a terminator, not an introducer; ASCII and non-C1 bytes map to none.
    for ([_]u8{ 0x9C, 'A', 0x80, 0x1B }) |b| try std.testing.expect(c1Target(b) == null);
}

test "leadState arms only the leads Unicode Table 3-7 permits" {
    // Length classifiers accept these; only a table of legal leads rejects them.
    for ([_]u8{ 0xC0, 0xC1, 0xF5, 0xF6, 0xF7, 0xF8, 0xFD, 0xFF, 0x80, 0x9B, 0xBF }) |b|
        try std.testing.expect(leadState(b) == null);
    // Leads that constrain their successor byte, per Table 3-7.
    try std.testing.expectEqual(Utf8State{ .remaining = 1, .lo = 0x80, .hi = 0xBF }, leadState(0xC2).?);
    try std.testing.expectEqual(Utf8State{ .remaining = 2, .lo = 0xA0, .hi = 0xBF }, leadState(0xE0).?);
    try std.testing.expectEqual(Utf8State{ .remaining = 2, .lo = 0x80, .hi = 0x9F }, leadState(0xED).?);
    try std.testing.expectEqual(Utf8State{ .remaining = 3, .lo = 0x90, .hi = 0xBF }, leadState(0xF0).?);
    try std.testing.expectEqual(Utf8State{ .remaining = 3, .lo = 0x80, .hi = 0x8F }, leadState(0xF4).?);
}

test "every well-formed codepoint survives the lead table byte-identically" {
    // The table is hand-transcribed, so check it against an independent decoder
    // rather than hand-picked examples: for each lead, sweep the successor byte
    // (the only other position the table constrains) over a well-formed tail.
    // Only acceptance is asserted -- a rejected sequence still emits its
    // maximal subpart, so passthrough is not equivalent to validity.
    var buf: [4]u8 = undefined;
    for (0xC0..0x100) |lead| {
        inline for (.{ 2, 3, 4 }) |n| {
            for (0x80..0x100) |second| {
                var seq: [n]u8 = @splat(0x80); // well-formed tail
                seq[0] = @intCast(lead);
                seq[1] = @intCast(second);
                if (!std.unicode.utf8ValidateSlice(&seq)) continue;
                @memcpy(buf[0..n], &seq);
                try std.testing.expectEqualSlices(u8, &seq, scrubInPlace(buf[0..n]));
            }
        }
    }
}

test "passableByte rejects ill-formed leads and out-of-range continuations" {
    var st: Utf8State = .{};
    // An invalid lead must drop and leave the counter disarmed, so the C1
    // introducer behind it is still classified as an introducer.
    for ([_]u8{ 0xC0, 0xC1, 0xF5, 0xF6, 0xF7, 0xF8, 0xFF }) |b| {
        try std.testing.expect(!passableByte(b, &st));
        try std.testing.expectEqual(@as(u2, 0), st.remaining);
        try std.testing.expect(!passableByte(0x9B, &st));
    }
    // Overlong, surrogate and out-of-range forms all use continuation bytes in
    // 0x80..0xBF, so only the per-position bounds reject them.
    for ([_][2]u8{ .{ 0xE0, 0x80 }, .{ 0xED, 0xA0 }, .{ 0xF0, 0x80 }, .{ 0xF4, 0x90 } }) |seq| {
        st = .{};
        try std.testing.expect(passableByte(seq[0], &st));
        try std.testing.expect(!passableByte(seq[1], &st));
        try std.testing.expectEqual(@as(u2, 0), st.remaining);
    }
    // Only the second byte is range-restricted; the rest are plain continuations.
    st = .{};
    for ([_]u8{ 0xF0, 0x90, 0x80, 0x80 }) |b| try std.testing.expect(passableByte(b, &st));
    try std.testing.expectEqual(@as(u2, 0), st.remaining);
}

test "passableByte reclassifies the byte that broke a sequence" {
    // A truncated codepoint must not swallow the byte that follows it.
    var st: Utf8State = .{};
    try std.testing.expect(passableByte(0xE2, &st));
    try std.testing.expect(passableByte('a', &st)); // ASCII resumes immediately
    try std.testing.expectEqual(@as(u2, 0), st.remaining);
    // A fresh lead in the broken position arms a fresh sequence.
    st = .{};
    try std.testing.expect(passableByte(0xE2, &st));
    try std.testing.expect(passableByte(0xC3, &st));
    try std.testing.expectEqual(@as(u2, 1), st.remaining);
    try std.testing.expect(passableByte(0xA9, &st));
}

test "CR resets an armed sequence instead of counting as a continuation" {
    // `passable` ORs in CR after `passableByte`; the reset must still happen or
    // a CR mid-codepoint would leave the counter armed for the next byte.
    var s = Sanitizer.init();
    try std.testing.expect(s.passable(0xE2));
    try std.testing.expect(s.passable('\r'));
    try std.testing.expectEqual(@as(u2, 0), s.utf8.remaining);
    try std.testing.expect(!s.passable(0x9B));
}

test "passable drops lone C1 but passes UTF-8 continuation under an armed counter" {
    var s = Sanitizer.init();
    // Printable ASCII and whitespace pass; C0 and DEL drop.
    try std.testing.expect(s.passable('A'));
    try std.testing.expect(s.passable('\t'));
    for ([_]u8{ 0x00, 0x07, 0x7F }) |b| try std.testing.expect(!s.passable(b));
    // Lone C1 controls drop — no lead byte has armed the counter.
    for ([_]u8{ 0x80, 0x9B, 0x9C }) |b| try std.testing.expect(!s.passable(b));
    // A lead byte arms the counter so its continuations pass, even in the C1
    // range (0x9C, 0x93 here), then a drained counter drops a lone C1 again.
    try std.testing.expect(s.passable(0xE2)); // lead of ✓ = E2 9C 93
    try std.testing.expect(s.passable(0x9C));
    try std.testing.expect(s.passable(0x93));
    try std.testing.expect(!s.passable(0x9C));
}

// ── inline unit tests: scrubInPlace ─────────────────────────────────

test "scrubInPlace drops ESC, other C0, DEL and CR but keeps TAB/LF" {
    var buf = "a\x1bb\x00c\x07d\x7fe\rf\tg\nh".*;
    try std.testing.expectEqualStrings("abcdef\tg\nh", scrubInPlace(&buf));
}

test "scrubInPlace keeps accented UTF-8 and emoji byte-identical" {
    const text = "Café ☕ déjà-vu 🚀";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    try std.testing.expectEqualStrings(text, scrubInPlace(buf[0..text.len]));
}

test "scrubInPlace drops lone C1 introducers but keeps them as continuations" {
    // 0x9B/0x9D are the 8-bit CSI/OSC forms; bare they must go.
    var lone = [_]u8{ 'a', 0x9B, 0x9D, 0x80, 'b' };
    try std.testing.expectEqualStrings("ab", scrubInPlace(&lone));
    // Inside ✓ (E2 9C 93) the same byte values are continuations and stay.
    var check = "x\u{2713}y".*;
    try std.testing.expectEqualStrings("x\u{2713}y", scrubInPlace(&check));
}

test "scrubInPlace drops a truncated multibyte lead and its stray bytes" {
    // Lead byte promising two continuations, followed by ASCII: the lead is
    // kept (it is a valid lead) but the counter unwinds so 'b' still passes.
    var buf = [_]u8{ 0xE2, 'a', 'b' };
    const got = scrubInPlace(&buf);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
    try std.testing.expectEqualStrings("ab", got[got.len - 2 ..]);
    // An invalid lead (0xFF) has no sequence length and drops outright.
    var bad = [_]u8{ 'a', 0xFF, 'b' };
    try std.testing.expectEqualStrings("ab", scrubInPlace(&bad));
}

test "scrubInPlace strips a whole OSC 52 clipboard payload of its controls" {
    var buf = "evil\x1b]52;c;ZXZpbA==\x07tail".*;
    const got = scrubInPlace(&buf);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0x07) == null);
    try std.testing.expect(std.mem.startsWith(u8, got, "evil"));
    try std.testing.expect(std.mem.endsWith(u8, got, "tail"));
}

test "scrubInPlace drops CR mid-codepoint without arming the next byte" {
    // CR is a C0 control here, so it both drops and disarms.
    var buf = [_]u8{ 0xE2, '\r', 0x9B, 'x' };
    try std.testing.expectEqualStrings("\xe2x", scrubInPlace(&buf));
}

test "scrubInPlace handles an empty buffer" {
    var buf: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), scrubInPlace(&buf).len);
}
