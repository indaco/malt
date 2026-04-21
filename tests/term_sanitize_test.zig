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

test "cursor position passes" {
    try check("\x1b[10;20H", "\x1b[10;20H");
}

test "erase line passes" {
    try check("\x1b[2K", "\x1b[2K");
}

test "save/restore cursor passes" {
    try check("\x1b[s\x1b[u", "\x1b[s\x1b[u");
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
    var big: [ts.CSI_PARAM_MAX + 10]u8 = undefined;
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
