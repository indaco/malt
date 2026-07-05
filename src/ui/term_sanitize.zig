//! malt — terminal escape-sequence sanitizer
//!
//! Filters bytes from an untrusted child process before they reach
//! the user's terminal. Permits printable ASCII + CR/LF/TAB + valid
//! UTF-8 (tracked with a small continuation counter, so lone C1
//! controls in 0x80..0x9F drop while real multibyte output passes) +
//! a whitelisted subset of CSI sequences: SGR colours, relative
//! cursor motion (A–G/E/F), line erase (K), and visible-screen erase
//! (J with no param or 0/1/2).
//! Everything else — OSC (including clipboard-reading OSC 52), DCS,
//! SOS/PM/APC, 8-bit C1 introducers, absolute positioning (H/f),
//! cursor save/restore (s/u), scrollback erase (CSI 3 J), other CSI
//! commands, C0 controls, stray/mid-sequence ESC — is dropped.
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
    // Outstanding UTF-8 continuation bytes expected after a lead byte, so a
    // continuation in 0x80..0x9F passes while a lone C1 control is dropped.
    utf8_remaining: u2 = 0,

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
                    self.utf8_remaining = 0;
                    self.state = .esc;
                } else if (self.utf8_remaining == 0) {
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
        // A continuation byte passes only while a lead byte is still expecting
        // one; this is what tells a real 0x80..0x9F continuation from a lone C1
        // control (the 8-bit CSI/OSC/DCS/ST introducers we must drop).
        if (self.utf8_remaining > 0) switch (b) {
            0x80...0xBF => {
                self.utf8_remaining -= 1;
                return true;
            },
            else => self.utf8_remaining = 0, // truncated — reclassify below
        };
        return switch (b) {
            0x20...0x7E, '\n', '\r', '\t' => true,
            // UTF-8 lead byte: pass raw and arm the continuation counter. std
            // rejects continuation bytes and invalid leads (0xF8..0xFF), both of
            // which fall through to `false` — closing the lone-C1 hole.
            0x80...0xFF => blk: {
                const len = std.unicode.utf8ByteSequenceLength(b) catch break :blk false;
                self.utf8_remaining = @intCast(len - 1);
                break :blk true;
            },
            else => false, // C0 controls, DEL
        };
    }
};

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
    return switch (final) {
        'm' => true, // SGR: colours, bold, underline
        'A', 'B', 'C', 'D' => true, // cursor up/down/right/left
        'E', 'F' => true, // cursor next/prev line
        'G' => true, // cursor column
        // H/f absolute positioning and s/u save/restore enable screen
        // spoofing and no in-repo progress output uses them (relative motion
        // only); dropped, keeping save/restore uniformly out (ESC 7/8 already
        // drop as stray ESC).
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

test "csiAllowed whitelists SGR/relative motion, drops positioning + save/restore" {
    for ("mABCDEFGK") |f| try std.testing.expect(csiAllowed(f, ""));
    // Absolute positioning (H/f) and cursor save/restore (s/u) are spoofing aids.
    for ("Hfsu") |f| try std.testing.expect(!csiAllowed(f, ""));
    // J is param-gated, not final-byte-only.
    try std.testing.expect(csiAllowed('J', "2"));
    try std.testing.expect(!csiAllowed('J', "3"));
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
