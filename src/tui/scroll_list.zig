//! malt — scrollable list widget for `mt tui`.
//!
//! Leaf module: imports only `std`. Pure viewport/selection math plus
//! width-aware row truncation, so the list reflows on resize by re-clamping
//! against the new content height — no PTY, no allocation, no I/O. Truncation
//! follows `ui/term_sanitize`'s stance: UTF-8 is treated as opaque runes (each
//! one display column, grapheme-naive) and ANSI/SGR escapes are zero-width
//! sequences — a cut never lands inside a rune or an escape, so it can never
//! corrupt the frame or disagree with the sanitizer's width model.

const std = @import("std");

/// Scroll position: `offset` is the index of the first visible row, `selected`
/// the highlighted row. Both index into the caller's row slice.
pub const View = struct {
    offset: usize = 0,
    selected: usize = 0,
};

/// Clamp `selected` into the list and scroll `offset` the minimum needed to keep
/// the selection inside a `height`-tall viewport. Pure: a resize is just a
/// re-clamp against the new `height`.
pub fn clamp(view: View, len: usize, height: u16) View {
    if (len == 0) return .{};
    var v = view;
    if (v.selected >= len) v.selected = len - 1;

    const h: usize = height;
    if (h != 0) {
        // Scroll the minimum distance that brings the selection back in view.
        if (v.selected < v.offset) {
            v.offset = v.selected;
        } else if (v.selected >= v.offset + h) {
            v.offset = v.selected - h + 1;
        }
    }
    // Never anchor past the last row (e.g. the list shrank under a stale offset).
    if (v.offset >= len) v.offset = len - 1;
    return v;
}

/// The rows visible in a `height`-tall viewport at `view.offset`. Assumes
/// `view` is already `clamp`ed. Returns a sub-slice — no allocation, and the
/// window is clipped to the row count so it never reads out of bounds.
pub fn visible(items: []const []const u8, view: View, height: u16) []const []const u8 {
    if (items.len == 0 or height == 0) return items[0..0];
    const start = @min(view.offset, items.len);
    const want = @min(@as(usize, height), items.len - start);
    return items[start .. start + want];
}

/// Which list index a click at 1-based screen row `click_row` lands on, given a
/// list occupying `height` rows from `list_top` (1-based) at `view.offset` over
/// `len` rows. `null` when the click is above/below the list or past the last
/// populated row. Pure — the single source of truth for click→index mapping.
pub fn rowAt(view: View, list_top: u16, height: u16, len: usize, click_row: u16) ?usize {
    if (height == 0 or len == 0) return null;
    // Saturating adds keep the leaf panic-free on absurd geometry/offsets: any
    // overflow saturates past the guards and resolves to null, never traps.
    if (click_row < list_top or click_row >= list_top +| height) return null;
    const idx = view.offset +| (click_row - list_top);
    return if (idx < len) idx else null; // clicked a blank row past the populated tail
}

/// The longest prefix of `row` that fits in `max_cols` display columns, cut only
/// on a rune or escape-sequence boundary. Returns a sub-slice of `row`. Runes
/// are one column each (grapheme-naive, matching `ui/term_sanitize`); ANSI
/// escapes are zero width and always ride along whole.
pub fn truncate(row: []const u8, max_cols: u16) []const u8 {
    var cut: usize = 0;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < row.len) {
        if (row[i] == 0x1b) {
            // Zero-width: take the whole escape so a cut can never split it.
            i = escapeEnd(row, i);
            cut = i;
            continue;
        }
        if (cols == max_cols) break; // budget spent — stop before the next rune
        i += runeLen(row, i);
        cols += 1;
        cut = i;
    }
    return row[0..cut];
}

/// Byte index just past the escape sequence starting at `row[i] == ESC`. A CSI
/// (`ESC [ … final`) runs to its final byte; an unterminated sequence consumes
/// to end-of-row rather than splitting; any other `ESC X` is the two-byte form.
fn escapeEnd(row: []const u8, i: usize) usize {
    if (i + 1 >= row.len) return row.len; // lone trailing ESC
    if (row[i + 1] != '[') return @min(i + 2, row.len);
    var j = i + 2;
    while (j < row.len) : (j += 1) {
        if (row[j] >= 0x40 and row[j] <= 0x7e) return j + 1; // include the final byte
    }
    return row.len; // unterminated CSI: keep it whole
}

/// Byte length of the rune at `row[i]`, clamped to what remains. An invalid lead
/// counts as one byte: this measures pre-scrub bytes, so it only has to avoid
/// splitting one — whether the byte survives is `putContent`'s call.
fn runeLen(row: []const u8, i: usize) usize {
    const want = std.unicode.utf8ByteSequenceLength(row[i]) catch return 1;
    return @min(@as(usize, want), row.len - i);
}

test "clamp scrolls down just enough to reveal a low selection" {
    const v = clamp(.{ .offset = 0, .selected = 19 }, 20, 5);
    try std.testing.expectEqual(@as(usize, 15), v.offset);
}

test "clamp with a zero-height viewport pins indices without overflow" {
    const v = clamp(.{ .offset = 7, .selected = 25 }, 10, 0);
    try std.testing.expectEqual(@as(usize, 9), v.selected); // clamped into the list
    try std.testing.expect(v.offset < 10); // never past the last row
}

test "clamp leaves the offset at the top when the viewport is taller than the list" {
    const v = clamp(.{ .offset = 0, .selected = 3 }, 5, 100);
    try std.testing.expectEqual(@as(usize, 0), v.offset);
}

test "clamp does not scroll while the selection is still the last visible row" {
    // height 5, offset 0 → rows 0..4 visible; selecting row 4 must not scroll.
    const v = clamp(.{ .offset = 0, .selected = 4 }, 20, 5);
    try std.testing.expectEqual(@as(usize, 0), v.offset);
    // One past the last visible row scrolls by exactly one.
    const w = clamp(.{ .offset = 0, .selected = 5 }, 20, 5);
    try std.testing.expectEqual(@as(usize, 1), w.offset);
}

test "visible clips an offset past the end and an empty list to nothing" {
    const rows = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectEqual(@as(usize, 0), visible(&rows, .{ .offset = 9, .selected = 9 }, 4).len);
    try std.testing.expectEqual(@as(usize, 0), visible(&.{}, .{}, 4).len);
    // A viewport taller than the list returns every row, no padding.
    try std.testing.expectEqual(@as(usize, 3), visible(&rows, .{}, 100).len);
}

test "truncate handles an empty row and an all-escape row" {
    try std.testing.expectEqualStrings("", truncate("", 5));
    // Zero-width escapes fit even in zero columns, so a pure-SGR row survives whole.
    try std.testing.expectEqualStrings("\x1b[0m", truncate("\x1b[0m", 0));
}

test "truncate counts an invalid UTF-8 byte as one raw column and never splits it" {
    // 0xff is never a valid lead; count it as one column rather than splitting it.
    // Truncation runs before the scrub, so a dropped byte only ever shrinks a row.
    try std.testing.expectEqualStrings("a\xff", truncate("a\xffb", 2));
    try std.testing.expectEqualStrings("a", truncate("a\xffb", 1)); // stops before the bad byte
}

test "truncate keeps a two-byte ESC form and a lone trailing ESC whole" {
    try std.testing.expectEqualStrings("ab\x1bX", truncate("ab\x1bX", 2)); // ESC X, not a CSI
    try std.testing.expectEqualStrings("ab\x1b", truncate("ab\x1b", 2)); // lone trailing ESC
}

test "escapeEnd spans a CSI and stops after the final byte" {
    try std.testing.expectEqual(@as(usize, 5), escapeEnd("\x1b[31mX", 0)); // ESC [ 3 1 m
    try std.testing.expectEqual(@as(usize, 3), escapeEnd("\x1b[3", 0)); // unterminated → end
    try std.testing.expectEqual(@as(usize, 1), escapeEnd("\x1b", 0)); // lone ESC → end
}

test "runeLen clamps a multibyte lead to the bytes that remain" {
    try std.testing.expectEqual(@as(usize, 2), runeLen("\xc3\xa9", 0));
    try std.testing.expectEqual(@as(usize, 1), runeLen("\xc3", 0)); // promised 2, only 1 left
    try std.testing.expectEqual(@as(usize, 1), runeLen("\xff", 0)); // invalid lead
}

test "rowAt maps unscrolled rows to their indices" {
    const v: View = .{ .offset = 0, .selected = 0 };
    try std.testing.expectEqual(@as(?usize, 0), rowAt(v, 1, 5, 20, 1)); // top row → index 0
    try std.testing.expectEqual(@as(?usize, 4), rowAt(v, 1, 5, 20, 5)); // last visible → height-1
}

test "rowAt adds the scroll offset" {
    const v: View = .{ .offset = 5, .selected = 5 };
    try std.testing.expectEqual(@as(?usize, 5), rowAt(v, 1, 5, 20, 1)); // top row → offset
}

test "rowAt rejects clicks outside the list band" {
    const v: View = .{ .offset = 0, .selected = 0 };
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 3, 5, 20, 2)); // above list_top
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 1, 5, 20, 6)); // at list_top+height
}

test "rowAt rejects an empty list and a zero-height viewport" {
    const v: View = .{ .offset = 0, .selected = 0 };
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 1, 5, 0, 1)); // len == 0
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 1, 0, 20, 1)); // height == 0
}

test "rowAt rejects a blank row past the populated tail" {
    const v: View = .{ .offset = 0, .selected = 0 };
    // len 3, viewport 5: rows 4 and 5 are blank tail.
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 1, 5, 3, 4));
}

test "rowAt lands the first and last populated rows exactly" {
    // Heading offset (list_top = 3), scrolled offset 2, partially-filled tail (len 4).
    const v: View = .{ .offset = 2, .selected = 2 };
    try std.testing.expectEqual(@as(?usize, 2), rowAt(v, 3, 5, 4, 3)); // first populated → offset
    try std.testing.expectEqual(@as(?usize, 3), rowAt(v, 3, 5, 4, 4)); // last populated (index 3)
    try std.testing.expectEqual(@as(?usize, null), rowAt(v, 3, 5, 4, 5)); // one past → blank
}

test "rowAt saturates extreme geometry and offset instead of panicking" {
    // list_top + height (u16) and offset + delta (usize) would overflow with plain
    // `+`; saturating adds must resolve past the guards to null, never trap.
    const max_usize = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(?usize, null), rowAt(.{}, 65535, 1, 20, 65535)); // u16 add
    try std.testing.expectEqual(@as(?usize, null), rowAt(.{ .offset = max_usize }, 1, 5, 20, 2)); // usize add
}
