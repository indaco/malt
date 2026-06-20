//! malt — integration tests for `tui/layout.zig`, the responsive frame engine.
//!
//! Pure-render across many sizes: assert the four regions tile the screen
//! exactly (no overlap, no overflow) from tiny to large, that below-minimum
//! sizes fall back without corrupting, that degenerate sizes (0×0, 1×1) never
//! panic, and that `render` is deterministic and reflows on resize. No PTY —
//! the layer is a pure function of `(cols, rows)`.

const std = @import("std");
const testing = std.testing;
const layout = @import("malt").tui_layout;
const scroll_list = @import("malt").tui_scroll_list;

fn expectTiles(cols: u16, rows: u16) !void {
    const lay = layout.compute(cols, rows);
    try testing.expect(lay == .ok);
    const r = lay.ok;

    // Stacked top-to-bottom, full width, in order.
    const regs = [_]layout.Rect{ r.header, r.tab_bar, r.filter, r.content, r.footer };
    var expected_row: u16 = 1;
    var total_height: u16 = 0;
    for (regs) |reg| {
        try testing.expectEqual(@as(u16, 1), reg.col);
        try testing.expectEqual(cols, reg.width);
        try testing.expectEqual(expected_row, reg.row); // no gap, no overlap
        try testing.expect(reg.height >= 1);
        expected_row += reg.height;
        total_height += reg.height;
    }
    // Exact tiling: the regions cover every row and never exceed `rows`.
    try testing.expectEqual(rows, total_height);
    try testing.expectEqual(rows + 1, expected_row);
}

test "regions tile the screen exactly across a range of sizes" {
    try expectTiles(layout.min_cols, layout.min_rows); // exact minimum
    try expectTiles(80, 24);
    try expectTiles(120, 50);
    try expectTiles(200, 120);
    try expectTiles(52, 7); // a narrow-but-valid size, just above the width floor
}

test "fixed regions keep their heights; content absorbs the remainder" {
    const r = layout.compute(80, 24).ok;
    try testing.expectEqual(layout.tab_bar_rows, r.tab_bar.height);
    try testing.expectEqual(layout.filter_rows, r.filter.height);
    try testing.expectEqual(layout.footer_rows, r.footer.height);
    try testing.expectEqual(@as(u16, 24 - layout.header_rows - layout.tab_bar_rows - layout.filter_rows - layout.footer_rows), r.content.height);
}

test "below the minimum is too_small; at or above is ok" {
    try testing.expect(layout.compute(layout.min_cols - 1, layout.min_rows) == .too_small);
    try testing.expect(layout.compute(layout.min_cols, layout.min_rows - 1) == .too_small);
    try testing.expect(layout.compute(layout.min_cols, layout.min_rows) == .ok);
    try testing.expect(!layout.fits(0, 0));
    try testing.expect(layout.fits(layout.min_cols, layout.min_rows));
}

test "degenerate sizes never panic and yield the fallback" {
    var buf: [4096]u8 = undefined;
    const state: layout.State = .{ .rows = &.{} };
    for ([_][2]u16{ .{ 0, 0 }, .{ 1, 1 }, .{ 0, 24 }, .{ 80, 0 }, .{ layout.min_cols - 1, 2 } }) |wh| {
        try testing.expect(layout.compute(wh[0], wh[1]) == .too_small);
        const out = layout.render(&buf, state, wh[0], wh[1]); // must not trap
        // Fallback never overflows the terminal it claims is too small.
        var lines: usize = if (out.len == 0) 0 else 1;
        for (out) |b| if (b == '\n') {
            lines += 1;
        };
        try testing.expect(lines <= @max(wh[1], 1));
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| try testing.expect(line.len <= wh[0]);
    }
}

test "render at any ok size never overflows the content region" {
    var buf: [16384]u8 = undefined;
    // Rows wider than any tested width, with a multibyte rune, to exercise the
    // width-aware cut at every size.
    const rows = [_][]const u8{
        "alpha-package-with-a-very-long-name-\xe2\x82\xac",
        "bravo-package-with-a-very-long-name-1.2.3",
        "charlie-0.0.1",
        "delta-9.9.9",
        "echo-1.1.1",
        "foxtrot-2.2.2",
    };
    const state: layout.State = .{ .rows = &rows, .view = .{ .offset = 0, .selected = 5 } };
    // exact-min, mid, and large.
    for ([_][2]u16{ .{ layout.min_cols, layout.min_rows }, .{ 80, 24 }, .{ 200, 120 } }) |wh| {
        const content_h = layout.compute(wh[0], wh[1]).ok.content.height;
        const out = layout.render(&buf, state, wh[0], wh[1]); // must not trap
        var it = std.mem.splitScalar(u8, out, '\n');
        var lines: usize = 0;
        while (it.next()) |line| {
            lines += 1;
            // A line that already fits is unchanged by re-truncating to `cols`.
            try testing.expectEqualStrings(line, scroll_list.truncate(line, wh[0]));
        }
        try testing.expect(lines <= content_h); // never more rows than the region holds
    }
}

test "render ok-size with no rows yields an empty content block, not a crash" {
    var buf: [256]u8 = undefined;
    const out = layout.render(&buf, .{ .rows = &.{} }, 80, 24);
    try testing.expectEqualStrings("", out);
}

test "render into an undersized buffer truncates safely, never overruns" {
    var small: [4]u8 = undefined;
    const rows = [_][]const u8{ "hello-world", "second-row" };
    const state: layout.State = .{ .rows = &rows, .view = .{} };
    const out = layout.render(&small, state, 80, 24); // content far exceeds 4 bytes
    try testing.expect(out.len <= small.len); // bounded by the caller buffer
    try testing.expectEqualStrings("hell", out); // a valid prefix, no garbage past the cut
}

test "compute at max u16 dimensions stays in bounds and tiles exactly" {
    const r = layout.compute(65535, 65535).ok;
    try testing.expectEqual(@as(u16, 65535), r.content.width);
    // content takes everything the fixed regions don't; footer still ends at the last row.
    try testing.expectEqual(@as(u16, 65535 - layout.header_rows - layout.tab_bar_rows - layout.filter_rows - layout.footer_rows), r.content.height);
    try testing.expectEqual(@as(u32, 65535), @as(u32, r.footer.row) + r.footer.height - 1);
}

test "the too-small fallback names the required minimum" {
    var buf: [4096]u8 = undefined;
    const out = layout.render(&buf, .{ .rows = &.{} }, 200, 100 - 99); // 200x1, below min_rows
    try testing.expect(std.mem.indexOf(u8, out, "too small") != null);
}

test "render is deterministic: same inputs, byte-identical output" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const rows = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };
    const state: layout.State = .{ .rows = &rows, .view = .{ .offset = 1, .selected = 3 } };
    const out_a = layout.render(&a, state, 80, 24);
    const out_b = layout.render(&b, state, 80, 24);
    try testing.expectEqualStrings(out_a, out_b);
    try testing.expect(out_a.len > 0);
}

test "render reflows: the same state at two sizes differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    // More rows than any single viewport so the visible window changes with height.
    const rows = [_][]const u8{
        "package-one-1.0",   "package-two-2.0",   "package-three-3.0",
        "package-four-4.0",  "package-five-5.0",  "package-six-6.0",
        "package-seven-7.0", "package-eight-8.0", "package-nine-9.0",
    };
    const state: layout.State = .{ .rows = &rows, .view = .{ .offset = 0, .selected = 0 } };
    const wide_tall = layout.render(&a, state, 80, 24);
    const narrow_short = layout.render(&b, state, 24, 8);
    try testing.expect(!std.mem.eql(u8, wide_tall, narrow_short));
}
