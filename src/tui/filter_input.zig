//! malt — `/`-activated filter line for `mt tui`.

const std = @import("std");
const scroll_list = @import("scroll_list.zig");

/// Bound on a filter string. A package-name filter never approaches this; the
/// cap exists so the buffer is fixed and the editor never allocates.
pub const max_len = 64;

/// The active tab's filter text. Fixed buffer, no allocation; the shell owns
/// the edit lifecycle (`/` to start, Enter commits, Esc clears).
pub const Filter = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Filter) []const u8 {
        return self.buf[0..self.len];
    }

    /// Append a rune's raw bytes. A rune that would not fit whole is dropped
    /// rather than split — a half-rune would corrupt the line and the frame.
    pub fn push(self: *Filter, bytes: []const u8) void {
        if (self.len + bytes.len > max_len) return;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Delete the last whole rune: drop trailing UTF-8 continuation bytes, then
    /// the lead byte, so a multibyte char is never half-deleted.
    pub fn backspace(self: *Filter) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        while (i > 0 and self.buf[i] & 0xc0 == 0x80) i -= 1;
        self.len = i;
    }

    pub fn clear(self: *Filter) void {
        self.len = 0;
    }
};

/// Render the filter line. The `filter:` label is always shown so the
/// affordance is visible; `/` activates editing, which adds a caret (`_`, since
/// the real cursor is hidden). Truncated to `cols`. Returns a prefix of `buf`.
pub fn render(buf: []u8, text: []const u8, editing: bool, cols: u16) []const u8 {
    var len: usize = 0;
    const put = struct {
        fn f(b: []u8, l: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - l.*);
            @memcpy(b[l.*..][0..n], s[0..n]);
            l.* += n;
        }
    }.f;
    put(buf, &len, "filter: ");
    put(buf, &len, text);
    if (editing) put(buf, &len, "_");
    return scroll_list.truncate(buf[0..len], cols);
}

test "push appends a rune and slice reflects it" {
    var f: Filter = .{};
    f.push("a");
    f.push("\xc3\xa9"); // é
    try std.testing.expectEqualStrings("a\xc3\xa9", f.slice());
}

test "push drops a rune that would not fit whole rather than splitting it" {
    var f: Filter = .{};
    // Fill to one byte below the cap.
    while (f.len < max_len - 1) f.push("x");
    f.push("\xc3\xa9"); // 2 bytes, only 1 free → rejected whole, no split, no panic
    try std.testing.expectEqual(@as(usize, max_len - 1), f.len);
}

test "backspace removes a whole multibyte rune" {
    var f: Filter = .{};
    f.push("a");
    f.push("\xc3\xa9");
    f.backspace();
    try std.testing.expectEqualStrings("a", f.slice());
    f.backspace();
    try std.testing.expectEqualStrings("", f.slice());
    f.backspace(); // empty is a no-op
    try std.testing.expectEqual(@as(usize, 0), f.len);
}

test "render keeps the filter label visible; caret only while editing" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("filter: ab_", render(&buf, "ab", true, 80));
    try std.testing.expectEqualStrings("filter: ab", render(&buf, "ab", false, 80));
    // The label persists even with no filter, so the affordance is discoverable.
    try std.testing.expectEqualStrings("filter: ", render(&buf, "", false, 80));
}

test "render truncates to the column budget" {
    var buf: [128]u8 = undefined;
    const out = render(&buf, "abcdef", true, 3); // "fil" — 3 visible cols
    try std.testing.expectEqual(@as(usize, 3), out.len);
}
