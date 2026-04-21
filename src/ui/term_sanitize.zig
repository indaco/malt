//! malt — terminal escape-sequence sanitizer
//!
//! Filters bytes from an untrusted child process before they reach
//! the user's terminal. Permits printable ASCII + CR/LF/TAB + the
//! common UTF-8 continuation range + a whitelisted subset of CSI
//! escape sequences (SGR colours and cursor positioning). Everything
//! else — OSC (including clipboard-reading OSC 52), DCS, SOS/PM/APC,
//! other CSI commands, C0 controls, stray ESC — is dropped.
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
pub const CSI_PARAM_MAX: usize = 32;
pub const OUT_BUF: usize = 256;

pub const Sanitizer = struct {
    state: State = .normal,
    csi_buf: [CSI_PARAM_MAX]u8 = undefined,
    csi_len: usize = 0,
    csi_overflow: bool = false,
    out_buf: [OUT_BUF]u8 = undefined,
    out_len: usize = 0,

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
                    self.state = .esc;
                } else if (passable(b)) {
                    try self.emit(b, sink);
                }
                // else: drop silently
            },
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.csi_len = 0;
                    self.csi_overflow = false;
                },
                ']' => self.state = .osc,
                'P', 'X', '^', '_' => self.state = .dcs,
                // Two-byte ESC X: drop both (we already dropped ESC).
                else => self.state = .normal,
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7E) {
                    // Final byte: decide.
                    if (!self.csi_overflow and csiAllowed(b)) {
                        try self.emit(0x1B, sink);
                        try self.emit('[', sink);
                        for (self.csi_buf[0..self.csi_len]) |p| try self.emit(p, sink);
                        try self.emit(b, sink);
                    }
                    self.state = .normal;
                } else if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = b;
                    self.csi_len += 1;
                } else {
                    // Too many param bytes — fail-closed when the
                    // final byte arrives.
                    self.csi_overflow = true;
                }
            },
            .osc, .dcs => {
                if (b == 0x07) {
                    self.state = .normal; // BEL terminates OSC
                } else if (b == 0x1B) {
                    self.state = .st_maybe;
                }
                // else: drop
            },
            .st_maybe => {
                if (b == '\\') {
                    self.state = .normal;
                } else if (b == 0x1B) {
                    // Stay waiting.
                } else {
                    // Not ST; back into OSC/DCS body.
                    self.state = .osc;
                }
            },
        }
    }

    fn emit(self: *Sanitizer, b: u8, sink: Sink) !void {
        if (self.out_len == self.out_buf.len) try self.flush(sink);
        self.out_buf[self.out_len] = b;
        self.out_len += 1;
    }
};

fn passable(b: u8) bool {
    // Printable ASCII, common whitespace, and UTF-8 continuation /
    // leading bytes. UTF-8 is passed raw rather than validated —
    // the terminal will do its own validation, and stripping mid-
    // sequence would corrupt legitimate non-ASCII output.
    return (b >= 0x20 and b <= 0x7E) or
        b == '\n' or b == '\r' or b == '\t' or
        b >= 0x80;
}

fn csiAllowed(final: u8) bool {
    return switch (final) {
        'm' => true, // SGR: colours, bold, underline
        'A', 'B', 'C', 'D' => true, // cursor up/down/right/left
        'E', 'F' => true, // cursor next/prev line
        'G' => true, // cursor column
        'H', 'f' => true, // cursor position
        'J' => true, // erase display
        'K' => true, // erase line
        's', 'u' => true, // save/restore cursor
        else => false,
    };
}
