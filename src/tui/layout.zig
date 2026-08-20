//! malt — responsive layout engine for `mt tui`.
//!
//! Leaf module: imports only `std` and `scroll_list`. The frame is a *pure
//! function of `(cols, rows)`* so a terminal resize is just a re-render, not a
//! data refetch, and the whole layer is testable without a PTY. Splits the
//! screen into five stacked, full-width regions — header / tab-bar / filter /
//! content / footer — and, below a minimum size, renders a clean "terminal too
//! small" fallback instead of a corrupt frame.
//! Nothing here touches the terminal, so a degenerate size yields the fallback,
//! never a panic that would bypass the caller's `errdefer` restoration.

const std = @import("std");
const scroll_list = @import("scroll_list.zig");

/// A screen rectangle, 1-based origin to match `term.cursorMove` so the event
/// loop can position the cursor at `region.row`/`region.col` directly.
pub const Rect = struct { row: u16, col: u16, width: u16, height: u16 };

/// The five stacked regions, top to bottom. They tile the screen exactly: no
/// gaps, no overlap, total height == `rows`.
pub const Regions = struct {
    header: Rect,
    tab_bar: Rect,
    filter: Rect,
    content: Rect,
    footer: Rect,
};

// Fixed region heights; `content` takes whatever rows remain. `min_rows` is
// derived so at least one content row always survives.
pub const header_rows: u16 = 1;
pub const tab_bar_rows: u16 = 1;
pub const filter_rows: u16 = 1;
// One separator row + two text rows: the footer help/banner line wraps into the
// two text rows on a narrow terminal instead of truncating its tail (the active
// tab's action keys). Bounded so the layout stays a pure function of (cols, rows).
pub const footer_rows: u16 = 3;
pub const min_content_rows: u16 = 1;
pub const min_rows: u16 = header_rows + tab_bar_rows + filter_rows + footer_rows + min_content_rows;
// The narrowest width that still shows all five tabs; below it the bar can't
// fit them, so the fallback shows rather than a clipped frame. A narrow-but-tall
// window trips this on width alone — `fits` requires both axes.
pub const min_cols: u16 = 50;

/// Result of laying out `(cols, rows)`: the tiled regions, or a signal that the
/// terminal is below the usable minimum and the fallback frame should render.
pub const Layout = union(enum) {
    ok: Regions,
    too_small,
};

pub fn fits(cols: u16, rows: u16) bool {
    return cols >= min_cols and rows >= min_rows;
}

/// Pure: same `(cols, rows)` → same `Layout`. Below the minimum it is
/// `.too_small`; otherwise the four regions tile the screen exactly.
pub fn compute(cols: u16, rows: u16) Layout {
    if (!fits(cols, rows)) return .too_small;
    const content_rows = rows - header_rows - tab_bar_rows - filter_rows - footer_rows;
    const tab_bar_row = 1 + header_rows;
    const filter_row = tab_bar_row + tab_bar_rows;
    const content_row = filter_row + filter_rows;
    const footer_row = content_row + content_rows;
    return .{ .ok = .{
        .header = .{ .row = 1, .col = 1, .width = cols, .height = header_rows },
        .tab_bar = .{ .row = tab_bar_row, .col = 1, .width = cols, .height = tab_bar_rows },
        .filter = .{ .row = filter_row, .col = 1, .width = cols, .height = filter_rows },
        .content = .{ .row = content_row, .col = 1, .width = cols, .height = content_rows },
        .footer = .{ .row = footer_row, .col = 1, .width = cols, .height = footer_rows },
    } };
}

/// What `render` paints: the content rows the layout owns at this layer (the
/// scroll list). Tab-bar / filter / footer *text* belongs to the event loop;
/// here those regions are only sized, not filled.
pub const State = struct {
    rows: []const []const u8,
    view: scroll_list.View = .{},
};

/// Pure render of the content the layout owns into `buf`, newline-joined.
/// `ok` → the scroll list's visible, width-truncated rows; below the minimum →
/// the fallback frame. Same `(state, cols, rows)` → same bytes. Returns the
/// used prefix of `buf`.
pub fn render(buf: []u8, state: State, cols: u16, rows: u16) []const u8 {
    return switch (compute(cols, rows)) {
        .too_small => renderFallback(buf, cols, rows),
        .ok => |r| renderContent(buf, state, r.content),
    };
}

/// The scroll list painted into its content rectangle: clamp the view to the
/// available height, take the visible window, width-truncate each row.
fn renderContent(buf: []u8, state: State, content: Rect) []const u8 {
    const v = scroll_list.clamp(state.view, state.rows.len, content.height);
    const win = scroll_list.visible(state.rows, v, content.height);
    var len: usize = 0;
    for (win, 0..) |row, idx| {
        if (idx != 0) {
            if (len == buf.len) break;
            buf[len] = '\n';
            len += 1;
        }
        const fitted = scroll_list.truncate(row, content.width);
        const n = @min(fitted.len, buf.len - len);
        @memcpy(buf[len..][0..n], fitted[0..n]);
        len += n;
        if (n < fitted.len) break; // caller buffer exhausted
    }
    return buf[0..len];
}

/// The "terminal too small" notice text, naming the minimum. ASCII keeps byte
/// length == column width. The single source of the message; callers add their
/// own icon/colour and wrapping.
pub fn tooSmallMessage(buf: []u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "terminal too small (need >= {d}x{d})",
        .{ min_cols, min_rows },
    ) catch "terminal too small";
}

/// The "terminal too small" frame: the notice line truncated to `cols` so it can
/// never overflow the very terminal it reports as too small. Empty when there is
/// no room to draw at all (`0` cols or rows).
fn renderFallback(buf: []u8, cols: u16, rows: u16) []const u8 {
    if (cols == 0 or rows == 0) return buf[0..0];
    var msg_buf: [64]u8 = undefined;
    const fitted = scroll_list.truncate(tooSmallMessage(&msg_buf), cols);
    const n = @min(fitted.len, buf.len);
    @memcpy(buf[0..n], fitted[0..n]);
    return buf[0..n];
}

test "compute reserves the header row and tiles the screen exactly" {
    const r = compute(80, 24).ok;
    try std.testing.expectEqual(@as(u16, 1), r.header.row);
    try std.testing.expectEqual(@as(u16, 2), r.tab_bar.row);
    try std.testing.expectEqual(@as(u16, 4), r.content.row);
    try std.testing.expectEqual(@as(u16, 18), r.content.height);
    try std.testing.expectEqual(@as(u16, 22), r.footer.row);
    try std.testing.expect(compute(1, 1) == .too_small);
}

test "min_rows reserves a row for the header" {
    try std.testing.expectEqual(
        header_rows + tab_bar_rows + filter_rows + footer_rows + min_content_rows,
        min_rows,
    );
    try std.testing.expectEqual(@as(u16, 7), min_rows);
}

test "compute is too_small when either axis alone is below the minimum" {
    try std.testing.expect(compute(min_cols - 1, 24) == .too_small); // width only
    try std.testing.expect(compute(80, min_rows - 1) == .too_small); // height only
    try std.testing.expect(compute(min_cols, min_rows) == .ok); // exactly the minimum fits
}
