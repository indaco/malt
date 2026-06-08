//! malt — integration tests for `tui/scroll_list.zig`.
//!
//! Pure viewport/selection math and width-aware truncation, table-driven over
//! byte slices. Cover selection-visibility as the viewport shrinks/grows, the
//! visible window, and truncation that never splits a multibyte UTF-8 rune or
//! an ANSI/SGR escape (consistent with `ui/term_sanitize`). No PTY.

const std = @import("std");
const testing = std.testing;
const sl = @import("malt").tui_scroll_list;

test "clamp keeps the selection inside the viewport as it scrolls down" {
    // 20 rows, height 5, select the last row: offset must reveal it.
    const v = sl.clamp(.{ .offset = 0, .selected = 19 }, 20, 5);
    try testing.expect(v.selected == 19);
    try testing.expect(v.selected >= v.offset);
    try testing.expect(v.selected < v.offset + 5);
    try testing.expectEqual(@as(usize, 15), v.offset);
}

test "clamp scrolls up to reveal a selection above the viewport" {
    const v = sl.clamp(.{ .offset = 10, .selected = 3 }, 20, 5);
    try testing.expectEqual(@as(usize, 3), v.offset); // top-aligned to the selection
    try testing.expectEqual(@as(usize, 3), v.selected);
}

test "clamp keeps the selection visible as the height shrinks step by step" {
    // Fixed selection deep in the list; shrink height and assert it stays in view.
    var height: u16 = 20;
    while (height >= 1) : (height -= 1) {
        const v = sl.clamp(.{ .offset = 0, .selected = 14 }, 30, height);
        try testing.expect(v.selected == 14);
        try testing.expect(v.selected >= v.offset);
        try testing.expect(v.selected < v.offset + height);
    }
}

test "clamp pins selection inside the list and offset to a valid first row" {
    const v = sl.clamp(.{ .offset = 99, .selected = 99 }, 4, 10);
    try testing.expect(v.selected < 4);
    try testing.expect(v.offset < 4);
    try testing.expectEqual(@as(usize, 3), v.selected);
}

test "clamp handles an empty list without overflow" {
    const v = sl.clamp(.{ .offset = 5, .selected = 7 }, 0, 10);
    try testing.expectEqual(@as(usize, 0), v.offset);
    try testing.expectEqual(@as(usize, 0), v.selected);
}

test "visible returns the window at the offset, clipped to the row count" {
    const rows = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    const win = sl.visible(&rows, .{ .offset = 2, .selected = 3 }, 3);
    try testing.expectEqual(@as(usize, 3), win.len);
    try testing.expectEqualStrings("c", win[0]);
    try testing.expectEqualStrings("e", win[2]);

    // Window past the end clips to what remains, never reads out of bounds.
    const tail = sl.visible(&rows, .{ .offset = 5, .selected = 5 }, 4);
    try testing.expectEqual(@as(usize, 1), tail.len);
    try testing.expectEqualStrings("f", tail[0]);
}

test "truncate returns the whole row when it already fits" {
    try testing.expectEqualStrings("hello", sl.truncate("hello", 10));
    try testing.expectEqualStrings("hello", sl.truncate("hello", 5));
}

test "truncate cuts ASCII on a column boundary" {
    try testing.expectEqualStrings("hel", sl.truncate("hello", 3));
    try testing.expectEqualStrings("", sl.truncate("hello", 0));
}

test "truncate never splits a multibyte UTF-8 rune" {
    // "héllo": h, é(0xC3 0xA9), l, l, o — width 5. At max 2 the cut sits after é.
    const s = "h\xc3\xa9llo";
    const out = sl.truncate(s, 2);
    try testing.expectEqualStrings("h\xc3\xa9", out);
    // Every retained byte forms a complete rune: the slice is valid UTF-8.
    try testing.expect(std.unicode.utf8ValidateSlice(out));

    // A width that lands mid-rune still cuts before it, never inside it.
    const euro = "\xe2\x82\xac\xe2\x82\xac"; // €€, 3 bytes each, width 2
    try testing.expectEqualStrings("\xe2\x82\xac", sl.truncate(euro, 1));
    try testing.expect(std.unicode.utf8ValidateSlice(sl.truncate(euro, 1)));
}

test "truncate keeps ANSI escapes whole and counts them as zero width" {
    // Red "abc" reset: the SGR escapes contribute no columns, so width 3 keeps all.
    const colored = "\x1b[31mabc\x1b[0m";
    try testing.expectEqualStrings(colored, sl.truncate(colored, 3));

    // Width 2 keeps the opening escape + 2 columns and never splits the escape.
    const out = sl.truncate(colored, 2);
    try testing.expectEqualStrings("\x1b[31mab", out);
}

test "truncate keeps a trailing zero-width escape once the limit is reached" {
    // "ab" then reset: 'a','b' fill width 2; the reset is zero-width so it rides along.
    const s = "ab\x1b[0m";
    try testing.expectEqualStrings("ab\x1b[0m", sl.truncate(s, 2));
}

test "truncate never splits an escape even when the row ends mid-sequence" {
    // A truncated/garbled trailing escape must not be cut further — keep it whole.
    const s = "ab\x1b[3"; // incomplete CSI at end
    try testing.expectEqualStrings("ab\x1b[3", sl.truncate(s, 2));
}
