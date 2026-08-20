//! malt — term_sanitize tests
//!
//! Exhaustive coverage of the escape-sequence state machine. Inputs
//! are byte literals; outputs are compared against expected byte
//! strings. State is preserved across feed() calls so split-across-
//! chunks inputs are also covered.

const std = @import("std");
const testing = std.testing;
const ts = @import("malt").term_sanitize;

const Buf = struct {
    list: std.ArrayList(u8) = .empty,

    fn sink(self: *Buf) ts.Sink {
        return .{ .ctx = self, .write_fn = writeFn };
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) ts.SinkError!void {
        const self: *Buf = @ptrCast(@alignCast(ctx));
        // Test buffer backed by testing.allocator: collapse an allocator
        // failure into the sink's single failure tag so the vtable stays
        // closed.
        self.list.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
    }

    fn deinit(self: *Buf) void {
        self.list.deinit(testing.allocator);
    }
};

fn check(input: []const u8, expected: []const u8) !void {
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed(input, buf.sink());
    try s.flush(buf.sink());
    try testing.expectEqualSlices(u8, expected, buf.list.items);
}

// Pin that `Sink.write_fn` returns a closed error set. A bare
// `anyerror` here would let a hostile sink raise arbitrary tags and
// defeat exhaustive switching at every caller.
test "Sink.write_fn declares a closed error set" {
    const FuncPtr = std.meta.fieldInfo(ts.Sink, .write_fn).type;
    const FnType = @typeInfo(FuncPtr).pointer.child;
    const RetT = @typeInfo(FnType).@"fn".return_type.?;
    const ErrSet = @typeInfo(RetT).error_union.error_set;
    try testing.expect(@typeInfo(ErrSet).error_set != null);
}

test "plain ASCII passes through" {
    try check("hello world", "hello world");
}

test "whitespace preserved" {
    try check("a\tb\nc\r\n", "a\tb\nc\r\n");
}

test "UTF-8 multibyte preserved" {
    // "café — 日本語"
    try check("caf\xc3\xa9 \xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", "caf\xc3\xa9 \xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e");
}

test "NUL dropped" {
    try check("a\x00b", "ab");
}

test "BEL dropped" {
    try check("a\x07b\x07c", "abc");
}

test "BS dropped" {
    try check("a\x08b", "ab");
}

test "stray ESC dropped with its follower" {
    // ESC followed by a non-special byte: drop both.
    try check("a\x1bZb", "ab");
}

// ── CSI SGR allowed ─────────────────────────────────────────────────

test "SGR colour passes" {
    try check("\x1b[31mred\x1b[0m", "\x1b[31mred\x1b[0m");
}

test "SGR with multiple params passes" {
    try check("\x1b[1;32;40mx", "\x1b[1;32;40mx");
}

// ── CSI cursor motion allowed ───────────────────────────────────────

test "cursor up passes" {
    try check("\x1b[3A", "\x1b[3A");
}

test "absolute cursor position dropped" {
    // H/f absolute positioning enables screen spoofing; progress output uses
    // relative motion only, so the sanitizer drops absolute positioning.
    try check("\x1b[10;20H", "");
    try check("\x1b[10;20f", "");
}

test "erase line passes" {
    try check("\x1b[2K", "\x1b[2K");
}

test "erase display screen variants pass" {
    try check("\x1b[J", "\x1b[J");
    try check("\x1b[0J", "\x1b[0J");
    try check("\x1b[1J", "\x1b[1J");
    try check("\x1b[2J", "\x1b[2J");
}

test "erase display unknown params dropped" {
    // Only the visible-screen variants are whitelisted; 3 (scrollback) and any
    // other/multi-param form fail closed.
    try check("a\x1b[4Jb", "ab");
    try check("a\x1b[3;4Jb", "ab");
}

test "save/restore cursor dropped" {
    // Save/restore aids screen spoofing and no in-repo output needs it; the
    // DEC ESC 7/8 form already drops, so drop the CSI form too.
    try check("a\x1b[sb\x1b[uc", "abc");
}

// ── CSI other commands dropped ──────────────────────────────────────

test "mode set CSI ? h dropped" {
    // ESC [ ? 1049 h — alt-screen toggle, not in allowlist
    try check("a\x1b[?1049hb", "ab");
}

test "mode reset CSI l dropped" {
    try check("a\x1b[?25lb", "ab");
}

test "scroll region CSI r dropped" {
    try check("a\x1b[1;24rb", "ab");
}

test "CSI 3 J erase scrollback dropped" {
    try check("a\x1b[3Jb", "ab");
}

// ── CSI private-prefix / intermediate forms dropped ─────────────────
// A whitelisted final byte does not identify the command: these all use one
// (m/K/A) yet are different commands with different side effects.

test "private-prefix CSI with a whitelisted final dropped" {
    // ESC [ > 4 ; 2 m — XTMODKEYS, rewrites modifier-key reporting.
    try check("a\x1b[>4;2mb", "ab");
    // ESC [ ? 4 m — XTQMODKEYS, makes the terminal report into stdin.
    try check("a\x1b[?4mb", "ab");
    try check("a\x1b[<0;0;0mb", "ab");
    try check("a\x1b[=5mb", "ab");
}

test "intermediate byte CSI with a whitelisted final dropped" {
    try check("a\x1b[0;1$mb", "ab");
    try check("a\x1b[!Kb", "ab");
    // ESC [ SP A is SL (scroll left), not cursor up.
    try check("a\x1b[ Ab", "ab");
}

test "numeric SGR subparameters still pass" {
    // CSI 4:3 m is a curly underline real build output emits.
    try check("a\x1b[4:3mb", "a\x1b[4:3mb");
}

test "byte just below the digit range dropped" {
    // '/' (0x2F) is a legal CSI intermediate one code point under '0'.
    try check("a\x1b[/mb", "ab");
}

test "private prefix via the 8-bit CSI introducer dropped" {
    // 0x9B reaches the same filter, so the C1 form must not be a way around it.
    try check("a\x9b>4;2mb", "ab");
    // A bare prefix with no digits is still not SGR.
    try check("a\x1b[>mb", "ab");
}

// ── anti-injection: 8-bit C1 introducers handled like 7-bit ─────────

test "8-bit CSI introducer routed through the CSI filter" {
    // 0x9B is the C1 form of ESC [ . Like the 7-bit path it filters: a
    // whitelisted SGR normalises to 7-bit and passes…
    try check("a\x9b31mXb", "a\x1b[31mXb");
    // …but scrollback erase via the 8-bit introducer is still dropped.
    try check("a\x9b3Jb", "ab");
}

test "8-bit OSC 52 clipboard attempt dropped" {
    // C1 OSC (0x9D) … C1 ST (0x9C): the 8-bit twin of ESC ] 52 … ST.
    try check("a\x9d52;c;cHduZWQ=\x9cb", "ab");
}

test "8-bit DCS dropped, 8-bit ST terminates" {
    try check("a\x90payload\x9cb", "ab");
}

test "lone C1 control dropped" {
    // 0x9C (ST) and 0x99 are C1 controls but not introducers: dropped outright.
    try check("a\x9cb\x99b", "abb");
}

// ── anti-injection: C0/ESC inside a CSI fails closed ────────────────

test "BEL smuggled inside a CSI drops the whole sequence" {
    try check("a\x1b[\x07mb", "ab");
}

test "ESC inside a CSI aborts it" {
    // Mid-CSI ESC restarts escape parsing; the first (aborted) CSI vanishes,
    // the second is a valid SGR that passes.
    try check("\x1b[3\x1b[31mX", "\x1b[31mX");
}

// ── UTF-8 preservation with C1-range continuation bytes ─────────────

test "UTF-8 codepoint with C1-range continuation preserved" {
    // ✓ = E2 9C 93; the 0x9C continuation byte overlaps the C1 range but must
    // pass because a lead byte is expecting it.
    try check("\xe2\x9c\x93", "\xe2\x9c\x93");
    // U+0080 = C2 80 — lowest C1 codepoint, continuation byte 0x80.
    try check("\xc2\x80", "\xc2\x80");
    // U+1F600 😀 = F0 9F 98 80 — 4-byte lead, continuation 0x98 in the C1 range.
    try check("\xf0\x9f\x98\x80", "\xf0\x9f\x98\x80");
    // U+265B ♛ = E2 99 9B — its trailing continuation byte is 0x9B, the C1 CSI
    // introducer. Mid-codepoint it must pass, never start a CSI.
    try check("\xe2\x99\x9b", "\xe2\x99\x9b");
}

test "incomplete UTF-8 lead is flushed when a control follows" {
    // A truncated codepoint (lead with no continuation) followed by ESC: the
    // lead byte still emits, the escape is parsed fresh (dropped here).
    try check("x\xe2\x1b[?25ly", "x\xe2y");
}

test "invalid UTF-8 lead does not arm the continuation counter" {
    // C0/C1 and F5..F7 are never legal leads, yet a length classifier hands
    // them a 1- and 3-byte window. The lead must drop and the C1 introducer
    // behind it must still reach the CSI/OSC filter.
    try check("a\xc0\x9b>4;2mb", "ab");
    try check("a\xc1\x9b>4;2mb", "ab");
    // 'm' terminates the CSI the introducer opened, so the tail is plain text.
    try check("a\xf5\x9b\x9dmb", "ab");
    try check("a\xf6\x9b\x9dmb", "ab");
    try check("a\xf7\x9b\x9dmb", "ab");
    // A whitelisted CSI behind an invalid lead is still filtered, not smuggled.
    try check("\xc0\x9b1;31m", "\x1b[1;31m");
    // An invalid lead followed by an OSC introducer drops the whole payload.
    try check("a\xc0\x9d52;c;ZXZpbA==\x07b", "ab");
}

test "overlong sequence cannot carry an 8-bit C1 introducer" {
    // The continuation bytes below are all in 0x80..0xBF, so a range-only
    // check accepts them; only per-position bounds reject the encoding.
    try check("\xe0\x80\x9b>4;2m", "\xe0"); // overlong 3-byte
    try check("\xf0\x80\x80\x9b>4;2m", "\xf0"); // overlong 4-byte
    try check("\xed\xa0\x9b>4;2m", "\xed"); // UTF-16 surrogate
    try check("\xf4\x90\x9b\x9d", "\xf4"); // beyond U+10FFFF
}

test "well-formed boundary codepoints still pass byte-identically" {
    // Guards against fixing the bug by dropping multibyte output wholesale.
    try check("\xc2\x80", "\xc2\x80"); // U+0080, lowest 2-byte
    try check("\xdf\xbf", "\xdf\xbf"); // U+07FF, highest 2-byte
    try check("\xe0\xa0\x80", "\xe0\xa0\x80"); // U+0800, lowest 3-byte
    try check("\xed\x9f\xbf", "\xed\x9f\xbf"); // U+D7FF, last before surrogates
    try check("\xee\x80\x80", "\xee\x80\x80"); // U+E000, first after surrogates
    try check("\xef\xbf\xbf", "\xef\xbf\xbf"); // U+FFFF
    try check("\xf0\x90\x80\x80", "\xf0\x90\x80\x80"); // U+10000
    try check("\xf4\x8f\xbf\xbf", "\xf4\x8f\xbf\xbf"); // U+10FFFF, highest legal
    // U+D6C0: its own continuation byte is 0x9B, the 8-bit CSI introducer.
    try check("\xed\x9b\x80", "\xed\x9b\x80");
}

test "a dropped escape disarms a pending UTF-8 sequence" {
    // Without the reset, the introducer lands inside the lead's continuation
    // window and is emitted raw instead of opening a filtered CSI.
    try check("\xe2\x1bZ\x9b>4;2m", "\xe2");
    // ESC immediately followed by the 8-bit introducer: both drop as a two-byte
    // escape, so the parameters that follow are plain text.
    try check("\xe2\x1b\x9b>4;2m", "\xe2>4;2m");
    // A whitelisted CSI between the lead and the introducer must not rearm it.
    try check("\xe2\x1b[0m\x9b>4;2m", "\xe2\x1b[0m");
}

test "CR mid-codepoint disarms the sequence" {
    // Child progress output uses CR; it must not be mistaken for a continuation
    // nor leave the counter armed for whatever follows.
    try check("\xe2\ry", "\xe2\ry");
    try check("\xe2\r\x9b>4;2m", "\xe2\r");
}

test "an ill-formed sequence split across feed() calls still drops" {
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("\xed", buf.sink());
    try s.feed("\xa0", buf.sink());
    try s.feed("\x9b>4;2m", buf.sink());
    try s.flush(buf.sink());
    try testing.expectEqualSlices(u8, "\xed", buf.list.items);
}

// ── OSC always dropped ──────────────────────────────────────────────

test "OSC 52 clipboard attempt dropped" {
    // ESC ] 52;c;BASE64 ST — iTerm2 clipboard read/write
    try check("a\x1b]52;c;aGVsbG8=\x1b\\b", "ab");
}

test "OSC terminated by BEL dropped" {
    try check("a\x1b]0;window title\x07b", "ab");
}

test "OSC terminated by ST dropped" {
    try check("a\x1b]8;;https://example.com\x1b\\label\x1b]8;;\x1b\\b", "alabelb");
}

// ── DCS always dropped ──────────────────────────────────────────────

test "DCS always dropped" {
    try check("a\x1bP1$rm\x1b\\b", "ab");
}

test "APC always dropped" {
    try check("a\x1b_payload\x1b\\b", "ab");
}

test "PM always dropped" {
    try check("a\x1b^data\x1b\\b", "ab");
}

test "SOS always dropped" {
    try check("a\x1bXdata\x1b\\b", "ab");
}

// ── CSI overflow fails closed ───────────────────────────────────────

test "CSI with oversized params fails closed" {
    var big: [ts.csi_param_max + 10]u8 = undefined;
    @memset(&big, '1');
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "a\x1b[");
    try input.appendSlice(testing.allocator, big[0..]);
    try input.append(testing.allocator, 'm');
    try input.append(testing.allocator, 'b');
    try check(input.items, "ab");
}

// ── split-across-chunks: state preserved ───────────────────────────

test "CSI split across feed() calls is reassembled" {
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("hi \x1b[3", buf.sink());
    try s.feed("1mred\x1b[0m bye", buf.sink());
    try s.flush(buf.sink());
    try testing.expectEqualStrings("hi \x1b[31mred\x1b[0m bye", buf.list.items);
}

test "OSC split across chunks is dropped end-to-end" {
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("a\x1b]52;c;", buf.sink());
    try s.feed("PAYLOAD", buf.sink());
    try s.feed("\x1b\\b", buf.sink());
    try s.flush(buf.sink());
    try testing.expectEqualStrings("ab", buf.list.items);
}

test "UTF-8 codepoint split across feed() calls is reassembled" {
    // The real filter reads fixed-size chunks, so a multibyte codepoint will
    // straddle a boundary; the continuation counter must survive across calls.
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("caf\xc3", buf.sink()); // é lead only
    try s.feed("\xa9 \xe2\x9c", buf.sink()); // é continuation + ✓ lead+cont1
    try s.feed("\x93!", buf.sink()); // ✓ final continuation
    try s.flush(buf.sink());
    try testing.expectEqualStrings("caf\xc3\xa9 \xe2\x9c\x93!", buf.list.items);
}

test "8-bit OSC split across chunks is dropped end-to-end" {
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed("a\x9d52;c;", buf.sink());
    try s.feed("PAYLOAD", buf.sink());
    try s.feed("\x9cb", buf.sink()); // 8-bit ST terminates
    try s.flush(buf.sink());
    try testing.expectEqualStrings("ab", buf.list.items);
}

// ── defense-in-depth invariant over a hostile corpus ────────────────

test "no BEL or bare ESC survives a dense hostile control corpus" {
    const hostile =
        "\x1b[\x07m" ++ // BEL in CSI
        "\x9d52;c;x\x9c" ++ // 8-bit OSC 52
        "\x1b]0;title\x07" ++ // OSC BEL-terminated
        "\x9b3J" ++ // 8-bit CSI erase scrollback
        "\x1b[3J" ++ // 7-bit erase scrollback
        "\x00\x7f\x9c\x90p\x9c" ++ // NUL, DEL, stray ST, DCS
        "ok\x1b[31mX\x1b[0m\x1b[2Jy"; // legit SGR + screen erase
    var buf: Buf = .{};
    defer buf.deinit();
    var s = ts.Sanitizer.init();
    try s.feed(hostile, buf.sink());
    try s.flush(buf.sink());
    const out = buf.list.items;
    // No BEL leaks; every emitted ESC begins a whitelisted CSI (ESC [ …).
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null);
    for (out, 0..) |c, i| {
        if (c == 0x1B) try testing.expect(i + 1 < out.len and out[i + 1] == '[');
        try testing.expect(!(c >= 0x80 and c <= 0x9F)); // no C1 leak (corpus has no UTF-8)
        try testing.expect(c >= 0x20 or c == 0x1B); // no other C0 leak
    }
    // Legitimate output still passes through.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[31mX\x1b[0m") != null);
}

// ── empty + pathological inputs ─────────────────────────────────────

test "empty input yields empty output" {
    try check("", "");
}

test "bare ESC at end of input is dropped" {
    try check("abc\x1b", "abc");
}

test "bare ESC [ at end of input is dropped" {
    try check("abc\x1b[", "abc");
}
