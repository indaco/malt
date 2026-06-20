//! malt — shared line-wrap primitive for `mt tui`.
//!
//! Leaf module: imports only `std`. Breaks a string into successive rows of at
//! most `width` columns, breaking at the last fitting space (hard-breaking a
//! single over-long token). Grapheme-naive — one byte ≈ one column, like the
//! rest of the TUI. One wrapping rule shared by `detail_pane` (field values) and
//! the footer help line, so the two can't drift apart.

const std = @import("std");

/// Iterator over the wrapped rows of a string. Each `next()` yields the next
/// row's bytes (leading spaces from the previous break trimmed) until exhausted.
pub const Iter = struct {
    rest: []const u8,
    width: usize,

    pub fn next(self: *Iter) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const take = wrapTake(self.rest, self.width);
        const chunk = self.rest[0..take];
        self.rest = trimLeading(self.rest[take..]);
        return chunk;
    }
};

/// Wrap `s` into rows of at most `width` columns. `width` is floored at one so a
/// degenerate width still makes progress instead of looping forever.
pub fn iter(s: []const u8, width: usize) Iter {
    return .{ .rest = s, .width = @max(@as(usize, 1), width) };
}

/// Bytes of `s` for one row of at most `max` columns: break at the last space
/// that fits, else hard-break at `max` (a single word wider than the row).
/// Grapheme-naive — one byte ≈ one column.
pub fn wrapTake(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var i = max;
    while (i > 0) : (i -= 1) if (s[i - 1] == ' ') return i; // include the break space
    return max; // no space in the window: hard break
}

fn trimLeading(s: []const u8) []const u8 {
    var r = s;
    while (r.len > 0 and r[0] == ' ') r = r[1..];
    return r;
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "wrapTake breaks at the last space that fits" {
    try testing.expectEqual(@as(usize, 4), wrapTake("one two three", 6)); // "one " — last space ≤ 6
    try testing.expectEqual(@as(usize, 13), wrapTake("one two three", 99)); // whole string fits
}

test "wrapTake hard-breaks a token with no space in the window" {
    try testing.expectEqual(@as(usize, 5), wrapTake("abcdefgh", 5)); // no space → cut at max
}

test "iter yields successive rows and trims the break space" {
    var it = iter("one two three", 6);
    try testing.expectEqualStrings("one ", it.next().?);
    try testing.expectEqualStrings("two ", it.next().?);
    try testing.expectEqualStrings("three", it.next().?);
    try testing.expect(it.next() == null);
}

test "iter on a degenerate zero width still terminates" {
    var it = iter("ab", 0); // floored to width 1
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expect(it.next() == null);
}
